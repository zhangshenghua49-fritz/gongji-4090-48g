#!/usr/bin/env python3
"""因幡巡 VITS 声库 HTTP 服务（MoeGoe 引擎）。

用途：手上没有干净参考音频、也不想训练时，用 2022 年代的成品 VITS 权重直接出声。
模型常驻显存，避免每条请求重载 .pth（重载一次约 3 秒，批量旁白时很要命）。

启动：
    VITS_ROOT=/root/data/models/vits python vits_tts_server.py --port 9882
    VITS_MODEL=sanoba  # 默认，可换 moetts / acgtts

路由：
    GET  /health          状态 + 显存 + 已加载模型
    GET  /speakers        当前模型的说话人表（sid ↔ 角色名）
    POST /tts             {text, sid|speaker, speed, model}
    POST /unload          卸载释放显存

与 ming_tts_server.py(:9881) / qwen3_tts_server.py(:9880) 路由风格保持一致，
三个引擎可以同时活着，互不抢端口。
"""

import argparse
import io
import json
import os
import sys
import threading
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

MEGOE_DIR = Path(os.environ.get("MEGOE_DIR", "/root/MoeGoe"))
if str(MEGOE_DIR) not in sys.path:
    sys.path.insert(0, str(MEGOE_DIR))

try:
    from models import SynthesizerTrn
    from text import get_text
    import utils as moe_utils
except Exception as exc:  # pragma: no cover - 环境缺失时的明确报错
    raise SystemExit(
        f"无法从 {MEGOE_DIR} 导入 MoeGoe 模块：{exc}\n"
        "先把 MoeGoe clone 到 /root/MoeGoe，或用 MEGOE_DIR 指向它。"
    )

VITS_ROOT = Path(os.environ.get("VITS_ROOT", "/root/data/models/vits"))
DEFAULT_MODEL = os.environ.get("VITS_MODEL", "sanoba")
OUT_DIR = Path(os.environ.get("VITS_OUT", "/root/data/out/tts"))
OUT_DIR.mkdir(parents=True, exist_ok=True)

APP = FastAPI(title="Inaba Meguru VITS", version="1.0")
_LOCK = threading.Lock()
_STATE = {"model": None, "hps": None, "net": None, "device": None, "loaded_at": 0.0}


def _pick_device() -> str:
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def _speaker_table(hps) -> dict:
    """config.json 里的 speakers 可能是 dict（名字→sid）也可能是 list。统一成 {名字: sid}。"""
    raw = getattr(hps, "speakers", None)
    if isinstance(raw, dict):
        return {str(k): int(v) for k, v in raw.items()}
    if isinstance(raw, list):
        return {str(name): idx for idx, name in enumerate(raw)}
    n = getattr(getattr(hps, "data", None), "n_speakers", 1) or 1
    return {f"sid{i}": i for i in range(int(n))}


def _load(model_name: str):
    with _LOCK:
        if _STATE["model"] == model_name and _STATE["net"] is not None:
            return _STATE

        if _STATE["net"] is not None:
            _STATE.update(model=None, hps=None, net=None)
            torch.cuda.empty_cache()

        mdir = VITS_ROOT / model_name
        ckpts = sorted(mdir.glob("*.pth"))
        cfgs = sorted(mdir.glob("config*.json"))
        if not ckpts:
            raise HTTPException(404, f"{mdir} 下没有 .pth 权重，先跑 fetch_models.sh --tier vits")
        if not cfgs:
            raise HTTPException(404, f"{mdir} 下没有 config.json，这个声库拿不出架构参数")

        device = _pick_device()
        hps = moe_utils.get_hparams_from_file(str(cfgs[0]))
        net = SynthesizerTrn(
            len(hps.symbols),
            hps.data.filter_length // 2 + 1,
            hps.train.segment_size // hps.data.hop_length,
            n_speakers=hps.data.n_speakers,
            **hps.model,
        ).to(device).eval()
        moe_utils.load_checkpoint(str(ckpts[0]), net, None)

        _STATE.update(
            model=model_name, hps=hps, net=net, device=device, loaded_at=time.time()
        )
        return _STATE


def _synthesize(text: str, sid: int, speed: float, noise: float, noise_w: float) -> tuple[np.ndarray, int]:
    st = _STATE
    if st["net"] is None:
        raise HTTPException(503, "模型未加载")
    hps, net, device = st["hps"], st["net"], st["device"]

    try:
        stn = get_text(text, hps, False)
    except TypeError:
        stn = get_text(text, hps)

    with torch.no_grad():
        x = stn.unsqueeze(0).to(device)
        x_len = torch.LongTensor([stn.size(0)]).to(device)
        audio = net.infer(
            x,
            x_len,
            noise_scale=noise,
            noise_scale_w=noise_w,
            length_scale=1.0 / max(0.1, speed),
            sid=sid,
        )[0][0, 0].data.cpu().float().numpy()

    sr = int(hps.data.sampling_rate)
    peak = float(np.abs(audio).max())
    if peak > 1.0:
        audio = audio / peak
    return audio, sr


class TTSReq(BaseModel):
    text: str
    sid: int | None = None
    speaker: str | None = None
    speed: float = 1.0
    noise_scale: float = 0.667
    noise_scale_w: float = 0.8
    model: str | None = None
    save: bool = False


@APP.get("/health")
def health():
    gpu = None
    if torch.cuda.is_available():
        free, total = torch.cuda.mem_get_info()
        gpu = {"free_gb": round(free / 2**30, 2), "total_gb": round(total / 2**30, 2)}
    out = {
        "ok": True,
        "engine": "moe-goe/VITS",
        "loaded": _STATE["model"],
        "device": _STATE["device"],
        "gpu": gpu,
        "root": str(VITS_ROOT),
        "available": sorted(p.name for p in VITS_ROOT.glob("*") if p.is_dir()),
    }
    if _STATE["hps"] is not None:
        out["sample_rate"] = int(_STATE["hps"].data.sampling_rate)
        out["speakers"] = _speaker_table(_STATE["hps"])
    return out


@APP.get("/speakers")
def speakers(model: str | None = None):
    st = _load(model or DEFAULT_MODEL)
    return {"model": st["model"], "speakers": _speaker_table(st["hps"])}


@APP.post("/tts")
def tts(req: TTSReq):
    if req.model:
        _load(req.model)
    st = _load(req.model or DEFAULT_MODEL)
    table = _speaker_table(st["hps"])

    sid = req.sid
    if sid is None and req.speaker:
        if req.speaker not in table:
            raise HTTPException(400, f"没有这个说话人：{req.speaker}；可选 {list(table)}")
        sid = table[req.speaker]
    if sid is None:
        sid = table.get("因幡巡", 0)
    if sid >= int(st["hps"].data.n_speakers):
        raise HTTPException(400, f"sid {sid} 超出范围（n_speakers={st['hps'].data.n_speakers}）")

    started = time.time()
    audio, sr = _synthesize(req.text, int(sid), req.speed, req.noise_scale, req.noise_scale_w)

    if req.save:
        name = f"vits_{int(started)}_{sid}.wav"
        sf.write(str(OUT_DIR / name), audio, sr)
        return {"file": str(OUT_DIR / name), "sr": sr, "dur": round(len(audio) / sr, 2), "sid": sid}

    import io

    buf = io.BytesIO()
    sf.write(buf, audio, sr, format="WAV")
    return Response(
        content=buf.getvalue(),
        media_type="audio/wav",
        headers={"X-Sr": str(sr), "X-Sid": str(sid), "X-Dur": f"{len(audio) / sr:.2f}"},
    )


@APP.post("/unload")
def unload():
    with _LOCK:
        _STATE.update(model=None, hps=None, net=None, device=None, loaded_at=0.0)
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    return {"ok": True, "unloaded": True}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=9882)
    ap.add_argument("--preload", default=os.environ.get("VITS_PRELOAD", DEFAULT_MODEL))
    args = ap.parse_args()

    if args.preload and (VITS_ROOT / args.preload).is_dir():
        try:
            st = _load(args.preload)
            print(f"[vits] 预载 {args.preload} 完成，说话人 {_speaker_table(st['hps'])}", flush=True)
        except Exception as exc:
            print(f"[vits] 预载失败（服务照常起，首次请求再试）：{exc}", flush=True)

    import uvicorn

    uvicorn.run(APP, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
