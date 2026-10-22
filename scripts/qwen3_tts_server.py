#!/usr/bin/env python3
"""
qwen3_tts_server.py -- Qwen3-TTS HTTP 服务（配音/克隆/声音设计）

直连 qwen-tts 官方包，不做二次封装。API 依据官方模型卡实测写法：
    Qwen3TTSModel.from_pretrained(path, device_map, dtype, attn_implementation)
    model.generate_custom_voice(text, language, speaker, instruct)
    model.generate_voice_design(text, language, instruct)
    model.generate_voice_clone(text, language, ref_audio, ref_text,
                               x_vector_only_mode=False, voice_clone_prompt=...)
    model.create_voice_clone_prompt(ref_audio, ref_text, x_vector_only_mode)

设计要点：
  * 懒加载 + 可卸载 —— 4090 48G 上 H3 要 39 GB，TTS 必须能立刻腾地方
  * voice prompt 落盘缓存 —— 同一角色音色跨多句复用，不重复抽特征
  * 输出 48 kHz 重采样交给 ffmpeg，本服务只吐模型原生采样率

启动：
    python qwen3_tts_server.py --port 9880 --models /root/data/models/tts/qwen3-tts
接口：
    POST /clone_with_prompt {text, language, prompt_name}
    GET  /prompt_list       已落盘的音色缓存（含 loaded 标记）
    GET  /health            常驻状态与显存
    POST /unload            卸载全部模型，退还显存
    GET  /speakers          预设音色清单
    POST /tts               {text, language, speaker, instruct}
    POST /design            {text, language, instruct}
    POST /clone             {text, language, ref_audio, ref_text, x_vector_only}
    POST /clone_prompt      {ref_audio, ref_text, name, x_vector_only}  -> 建缓存
    POST /clone_with_prompt {text, language, prompt_name}
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Union

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("qwen3tts")

APP = FastAPI(title="Qwen3-TTS", version="1.0")

# ---------------------------------------------------------------------------
# 全局状态
# ---------------------------------------------------------------------------
STATE: dict[str, Any] = {
    "models": {},        # kind -> (model, load_time)
    "prompts": {},       # name -> prompt items
    "root": None,        # 模型根目录
    "prompt_dir": None,  # prompt 缓存目录
    "attn": "flash_attention_2",
}

KIND_DIR = {
    "custom": "CustomVoice",
    "design": "VoiceDesign",
    "base": "Base",       # 克隆用
}


def _resolve(kind: str) -> str:
    """把 kind 解析成本地目录或 HF repo id。"""
    root = Path(STATE["root"])
    # 本地优先：<root>/<Kind> 或 <root> 自身就是该 kind
    cand = root / KIND_DIR[kind]
    if cand.is_dir():
        return str(cand)
    if root.is_dir() and any(root.glob("*.safetensors")):
        return str(root)
    return f"Qwen/Qwen3-TTS-12Hz-1.7B-{KIND_DIR[kind]}"


def _load(kind: str):
    """懒加载。已加载直接返回。"""
    if kind in STATE["models"]:
        return STATE["models"][kind][0]

    from qwen_tts import Qwen3TTSModel

    path = _resolve(kind)
    log.info("loading %s <- %s", kind, path)
    t0 = time.time()

    kwargs = dict(device_map="cuda:0", dtype=torch.bfloat16)
    attn = STATE["attn"]
    if attn:
        kwargs["attn_implementation"] = attn
    try:
        model = Qwen3TTSModel.from_pretrained(path, **kwargs)
    except Exception as exc:                     # flash-attn 不可用就退回 sdpa
        if attn:
            log.warning("attn=%s 加载失败(%s)，退回 sdpa", attn, exc)
            kwargs.pop("attn_implementation", None)
            model = Qwen3TTSModel.from_pretrained(path, **kwargs)
            STATE["attn"] = None
        else:
            raise

    STATE["models"][kind] = (model, time.time() - t0)
    log.info("%s loaded in %.1fs", kind, time.time() - t0)
    return model


def _unload_all():
    STATE["models"].clear()
    STATE["prompts"].clear()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        torch.cuda.ipc_collect()


def _gpu() -> dict:
    if not torch.cuda.is_available():
        return {"cuda": False}
    free, total = torch.cuda.mem_get_info()
    return {
        "cuda": True,
        "device": torch.cuda.get_device_name(0),
        "allocated_gb": round(torch.cuda.memory_allocated() / 2**30, 2),
        "reserved_gb": round(torch.cuda.memory_reserved() / 2**30, 2),
        "free_gb": round(free / 2**30, 2),
        "total_gb": round(total / 2**30, 2),
    }


# ---------------------------------------------------------------------------
# 音频 I/O
# ---------------------------------------------------------------------------
def _load_ref(ref: str) -> Union[str, tuple[np.ndarray, int]]:
    """ref_audio 支持：本地路径 / http URL / data:base64 / 裸 base64。"""
    if ref.startswith(("http://", "https://")):
        return ref
    if ref.startswith("data:") or (len(ref) > 256 and "/" not in ref[:64]):
        raw = ref.split(",", 1)[-1] if ref.startswith("data:") else ref
        data = base64.b64decode(raw)
        arr, sr = sf.read(io.BytesIO(data), dtype="float32", always_2d=False)
        if arr.ndim > 1:
            arr = arr.mean(axis=1)
        return arr, sr
    if not Path(ref).is_file():
        raise HTTPException(400, f"ref_audio 不存在: {ref}")
    return ref


def _wav_bytes(wav: np.ndarray, sr: int) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, wav, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def _as_list(v):
    return v if isinstance(v, list) else [v]


# ---------------------------------------------------------------------------
# 请求模型
# ---------------------------------------------------------------------------
class TTSReq(BaseModel):
    text: Union[str, list[str]]
    language: Union[str, list[str]] = "Auto"
    speaker: Union[str, list[str]] = "Vivian"
    instruct: Union[str, list[str]] = ""


class DesignReq(BaseModel):
    text: Union[str, list[str]]
    language: Union[str, list[str]] = "Auto"
    instruct: Union[str, list[str]]


class CloneReq(BaseModel):
    text: Union[str, list[str]]
    language: Union[str, list[str]] = "Auto"
    ref_audio: str
    ref_text: str = ""
    x_vector_only: bool = False


class PromptReq(BaseModel):
    ref_audio: str
    ref_text: str = ""
    name: str = Field(..., description="缓存名，后续 /clone_with_prompt 引用")
    x_vector_only: bool = False
    overwrite: bool = False


class PromptGenReq(BaseModel):
    text: Union[str, list[str]]
    language: Union[str, list[str]] = "Auto"
    prompt_name: str


# ---------------------------------------------------------------------------
# 端点
# ---------------------------------------------------------------------------
@APP.get("/health")
def health():
    return {
        "ok": True,
        "loaded": {k: round(v[1], 1) for k, v in STATE["models"].items()},
        "prompts": sorted(STATE["prompts"]),
        "root": STATE["root"],
        "gpu": _gpu(),
    }


@APP.post("/unload")
def unload():
    _unload_all()
    return {"ok": True, "gpu": _gpu()}


@APP.get("/speakers")
def speakers():
    m = _load("custom")
    out: dict[str, Any] = {}
    for fn in ("get_supported_speakers", "get_supported_languages"):
        try:
            out[fn.replace("get_supported_", "")] = getattr(m, fn)()
        except Exception as exc:
            out[fn] = f"unavailable: {exc}"
    return out


@APP.post("/tts")
def tts(req: TTSReq):
    m = _load("custom")
    kw = {"instruct": req.instruct} if req.instruct else {}
    wavs, sr = m.generate_custom_voice(
        text=req.text,
        language=req.language,
        speaker=req.speaker,
        **kw,
    )
    return _pack(wavs, sr)


@APP.post("/design")
def design(req: DesignReq):
    m = _load("design")
    wavs, sr = m.generate_voice_design(
        text=req.text,
        language=req.language,
        instruct=req.instruct,
    )
    return _pack(wavs, sr)


@APP.post("/clone")
def clone(req: CloneReq):
    m = _load("base")
    kw = {"ref_text": req.ref_text} if req.ref_text else {}
    wavs, sr = m.generate_voice_clone(
        text=req.text,
        language=req.language,
        ref_audio=_load_ref(req.ref_audio),
        x_vector_only_mode=req.x_vector_only,
        **kw,
    )
    return _pack(wavs, sr)


@APP.post("/clone_prompt")
def clone_prompt(req: PromptReq):
    m = _load("base")
    dest = Path(STATE["prompt_dir"]) / f"{req.name}.json"
    if dest.exists() and not req.overwrite:
        raise HTTPException(409, f"prompt '{req.name}' 已存在（overwrite=true 可覆盖）")

    kw = {"ref_text": req.ref_text} if req.ref_text else {}
    prompt = m.create_voice_clone_prompt(
        ref_audio=_load_ref(req.ref_audio),
        x_vector_only_mode=req.x_vector_only,
        **kw,
    )
    STATE["prompts"][req.name] = prompt
    # 记录 ref_audio，让服务重启后能凭这份 meta 自动重建音色
    rebuildable = not req.ref_audio.startswith("data:") and len(req.ref_audio) < 512
    meta = {
        "name": req.name,
        "ref_audio": req.ref_audio if rebuildable else "<inline base64, 不可自动重建>",
        "ref_text": req.ref_text,
        "x_vector_only": req.x_vector_only,
        "rebuildable": rebuildable,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "name": req.name, "cache": str(dest), "rebuildable": rebuildable}


@APP.post("/clone_with_prompt")
def clone_with_prompt(req: PromptGenReq):
    m = _load("base")
    if req.prompt_name not in STATE["prompts"]:
        _rebuild_prompt(m, req.prompt_name)
    wavs, sr = m.generate_voice_clone(
        text=req.text,
        language=req.language,
        voice_clone_prompt=STATE["prompts"][req.prompt_name],
    )
    return _pack(wavs, sr)


def _rebuild_prompt(model, name: str) -> None:
    """内存里没有就翻磁盘 meta 重建 —— 服务重启后音色依然可用。"""
    f = Path(STATE["prompt_dir"]) / f"{name}.json"
    if not f.is_file():
        raise HTTPException(404, f"prompt '{name}' 不存在（先调 /clone_prompt）")
    meta = json.loads(f.read_text(encoding="utf-8"))
    if not meta.get("rebuildable"):
        raise HTTPException(409, f"prompt '{name}' 是内联 base64 建立的，无法重建，请重跑 /clone_prompt")
    log.info("rebuilding prompt %s from %s", name, meta["ref_audio"])
    kw = {"ref_text": meta["ref_text"]} if meta.get("ref_text") else {}
    STATE["prompts"][name] = model.create_voice_clone_prompt(
        ref_audio=_load_ref(meta["ref_audio"]),
        x_vector_only_mode=meta.get("x_vector_only", False),
        **kw,
    )


@APP.get("/prompt_list")
def prompt_list():
    d = Path(STATE["prompt_dir"])
    out = []
    for f in sorted(d.glob("*.json")):
        try:
            meta = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        meta["loaded"] = meta.get("name") in STATE["prompts"]
        out.append(meta)
    return {"prompts": out, "loaded": sorted(STATE["prompts"])}


def _pack(wavs, sr: int):
    wavs = _as_list(wavs)
    if len(wavs) == 1:
        return Response(_wav_bytes(np.asarray(wavs[0]), sr), media_type="audio/wav")
    # 多条 → 返回 base64 数组，避免临时文件
    return JSONResponse({
        "sample_rate": sr,
        "count": len(wavs),
        "wavs_b64": [base64.b64encode(_wav_bytes(np.asarray(w), sr)).decode() for w in wavs],
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=9880)
    ap.add_argument("--models", default="/root/data/models/tts/qwen3-tts",
                    help="模型根目录；其下可有 CustomVoice/ VoiceDesign/ Base/ 子目录")
    ap.add_argument("--prompt-dir", default="/root/data/voice-prompts")
    ap.add_argument("--attn", default="flash_attention_2",
                    help="flash_attention_2 | sdpa | '' 关闭")
    ap.add_argument("--preload", default="", help="启动即加载，逗号分隔：custom,design,base")
    args = ap.parse_args()

    STATE["root"] = args.models
    STATE["prompt_dir"] = args.prompt_dir
    STATE["attn"] = args.attn or None
    Path(args.prompt_dir).mkdir(parents=True, exist_ok=True)

    if args.preload:
        for k in [x.strip() for x in args.preload.split(",") if x.strip()]:
            _load(k)

    log.info("Qwen3-TTS 就绪 http://%s:%d  models=%s", args.host, args.port, args.models)
    uvicorn.run(APP, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
