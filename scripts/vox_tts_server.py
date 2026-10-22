#!/usr/bin/env python3
"""VoxCPM2 HTTP 服务 —— 因幡巡日语配音主力（:9883）

为什么是 VoxCPM2 而不是 Ming-3.0：
  日语零样本音色相似度 0.825 vs 0.765（SIM 越高越像本人），
  且输出 48 kHz 直出（16 kHz 参考音经 AudioVAE V2 非对称编解码放大），
  对「拿一段因幡巡原声克隆、再念小说旁白」这条链路是决定性的。
  Ming 的长处是 MIT + 英文综合分 + 44.1 kHz，留在 :9881 当对照组。

显存策略：懒加载 + /unload 立刻腾空。H3 出片时先 POST /unload，
跑完再让下一次请求自动加载 —— 4090 48G 上 H3 全常驻要 42 GB，两者不能同时挂着。

接口（与 ming_tts_server.py 保持一致，方便上层脚本切换）：
  GET  /health          健康 + 显存 + 是否已加载
  POST /unload          卸载模型、清空显存
  GET  /capabilities    支持的语言/能力/采样率
  POST /clone           参考音克隆（reference_wav_path）
  POST /hifi_clone      续写式高保真克隆（prompt_wav + prompt_text，最像本人）
  POST /design          纯文字描述造音色（无参考音）
  POST /synth           透传原始参数
  统一返回 audio/wav 二进制流。

用法：
  python vox_tts_server.py --models /root/data/models/voxcpm2 --port 9883
"""

from __future__ import annotations

import argparse
import base64
import binascii
import io
import logging
import os
import tempfile
import threading
import time
from typing import Any, Optional

import numpy as np
import soundfile as sf

try:                                    # 服务能起、模型不在也能给 /health 回话
    from fastapi import FastAPI, HTTPException
    from fastapi.responses import Response
    from pydantic import BaseModel, Field
    import uvicorn
except ImportError as exc:              # pragma: no cover
    raise SystemExit(f"缺依赖：{exc}（需要 fastapi uvicorn pydantic soundfile）") from exc

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("voxcpm2")

STATE: dict[str, Any] = {"model": None, "sr": 48000, "lock": threading.Lock(), "loaded_at": None}
APP = FastAPI(title="VoxCPM2 TTS", version="2.0")
ARGS: argparse.Namespace


# ---------------------------------------------------------------------------
# 模型生命周期
# ---------------------------------------------------------------------------
def _load():
    """懒加载。返回 VoxCPM 实例；权重缺失时给出能看懂的报错。"""
    with STATE["lock"]:
        if STATE["model"] is not None:
            return STATE["model"]
        path = ARGS.models
        if not os.path.isdir(path):
            raise HTTPException(500, f"权重目录不存在：{path}（先跑 fetch_models.sh --tier vox）")
        try:
            from voxcpm import VoxCPM
        except ImportError as exc:
            raise HTTPException(500, f"voxcpm 未安装：{exc}") from exc

        t0 = time.time()
        log.info("loading VoxCPM2 from %s (denoiser=%s)", path, ARGS.denoiser)
        model = VoxCPM.from_pretrained(path, load_denoiser=ARGS.denoiser)
        # 官方文档：sample_rate 挂在 tts_model 上（48 kHz）
        try:
            STATE["sr"] = int(model.tts_model.sample_rate)
        except Exception:
            STATE["sr"] = 48000
        STATE["model"] = model
        STATE["loaded_at"] = time.time()
        log.info("loaded in %.1fs, sample_rate=%d", time.time() - t0, STATE["sr"])
        return model


def _unload():
    with STATE["lock"]:
        STATE["model"] = None
        STATE["loaded_at"] = None
    try:
        import torch
        torch.cuda.empty_cache()
    except Exception:
        pass
    log.info("unloaded")


def _gpu() -> dict:
    try:
        import torch
        if not torch.cuda.is_available():
            return {"available": False}
        free, total = torch.cuda.mem_get_info()
        return {
            "available": True,
            "device": torch.cuda.get_device_name(0),
            "free_gb": round(free / 2**30, 2),
            "total_gb": round(total / 2**30, 2),
            "allocated_gb": round(torch.cuda.memory_allocated() / 2**30, 2),
        }
    except Exception as exc:
        return {"available": False, "error": str(exc)}


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
def _materialize_ref(ref: str, tag: str) -> str:
    """把「本地路径」或「base64 wav」统一落成一个临时 wav 路径。"""
    if not ref:
        raise HTTPException(400, f"{tag} 为空")
    if os.path.exists(ref):
        return ref
    raw = ref.split(",", 1)[-1] if ref.startswith("data:") else ref
    try:
        blob = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(400, f"{tag} 既不是存在的路径也不是合法 base64") from exc
    fd, path = tempfile.mkstemp(suffix=".wav", prefix=f"vox_{tag}_")
    with os.fdopen(fd, "wb") as fh:
        fh.write(blob)
    return path


def _wav(waveform, sr: int) -> bytes:
    arr = np.asarray(waveform, dtype=np.float32)
    arr = np.squeeze(arr)
    if arr.ndim > 1:
        arr = arr.mean(axis=0)
    peak = float(np.max(np.abs(arr))) if arr.size else 0.0
    if peak > 1.0:
        arr = arr / peak
    buf = io.BytesIO()
    sf.write(buf, arr.astype(np.float32), sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def _gen(**kw) -> bytes:
    model = _load()
    t0 = time.time()
    try:
        wav = model.generate(**kw)
    except Exception as exc:
        log.exception("generate failed")
        raise HTTPException(500, f"generate 失败: {exc}") from exc
    log.info("generate ok in %.1fs", time.time() - t0)
    return _wav(wav, STATE["sr"])


def _resp(data: bytes) -> Response:
    return Response(content=data, media_type="audio/wav",
                    headers={"X-Sample-Rate": str(STATE["sr"])})


# ---------------------------------------------------------------------------
# 请求模型
# ---------------------------------------------------------------------------
class CloneReq(BaseModel):
    text: str
    reference_wav_path: str = Field(..., description="参考音频：本地路径或 base64")
    cfg_value: float = 2.0
    inference_timesteps: int = Field(10, ge=1, le=50)
    seed: int = 42
    # 中文里常见的写法兼容：ref_audio / ref_audio_path
    ref_audio: Optional[str] = None


class HifiCloneReq(BaseModel):
    text: str
    prompt_wav_path: str = Field(..., description="参考音频（续写式，最像本人）")
    prompt_text: str = Field(..., description="参考音频的**确切**文本，缺了效果会掉")
    reference_wav_path: Optional[str] = None
    cfg_value: float = 2.0
    inference_timesteps: int = 10
    seed: int = 42


class DesignReq(BaseModel):
    text: str = Field(..., description="含音色描述的文本，如 (A young woman, gentle and sweet voice)…")
    cfg_value: float = 2.0
    inference_timesteps: int = 10
    seed: int = 42


class RawReq(BaseModel):
    text: str
    reference_wav_path: Optional[str] = None
    prompt_wav_path: Optional[str] = None
    prompt_text: Optional[str] = None
    cfg_value: float = 2.0
    inference_timesteps: int = 10
    seed: int = 42


# ---------------------------------------------------------------------------
# 路由
# ---------------------------------------------------------------------------
@APP.get("/health")
def health():
    return {
        "ok": True,
        "engine": "voxcpm2",
        "loaded": STATE["model"] is not None,
        "loaded_at": STATE["loaded_at"],
        "sample_rate": STATE["sr"],
        "models": ARGS.models,
        "denoiser": ARGS.denoiser,
        "gpu": _gpu(),
    }


@APP.post("/unload")
def unload():
    _unload()
    return {"ok": True, "gpu": _gpu()}


@APP.get("/capabilities")
def capabilities():
    return {
        "engine": "voxcpm2",
        "params": "2B",
        "sample_rate": 48000,
        "languages": 30,
        "modes": ["clone", "hifi_clone", "design"],
        "notes": [
            "reference_wav_path 走零样本克隆，不需要参考文本",
            "prompt_wav_path + prompt_text 走续写式克隆，保留全部韵律细节，最像本人",
            "design 模式可纯文字描述音色，无需参考音",
            "RTF ~0.3 on RTX 4090（Nano-vLLM 可到 ~0.13）",
        ],
    }


@APP.post("/clone")
def clone(req: CloneReq):
    ref = req.reference_wav_path or req.ref_audio or ""
    path = _materialize_ref(ref, "reference_wav_path")
    return _resp(_gen(
        text=req.text,
        reference_wav_path=path,
        cfg_value=req.cfg_value,
        inference_timesteps=req.inference_timesteps,
        seed=req.seed,
    ))


@APP.post("/hifi_clone")
def hifi_clone(req: HifiCloneReq):
    prompt = _materialize_ref(req.prompt_wav_path, "prompt_wav_path")
    kw: dict[str, Any] = dict(
        text=req.text,
        prompt_wav_path=prompt,
        prompt_text=req.prompt_text,
        cfg_value=req.cfg_value,
        inference_timesteps=req.inference_timesteps,
        seed=req.seed,
    )
    if req.reference_wav_path:
        kw["reference_wav_path"] = _materialize_ref(req.reference_wav_path, "reference_wav_path")
    return _resp(_gen(**kw))


@APP.post("/design")
def design(req: DesignReq):
    return _resp(_gen(
        text=req.text,
        cfg_value=req.cfg_value,
        inference_timesteps=req.inference_timesteps,
        seed=req.seed,
    ))


@APP.post("/synth")
def synth(req: RawReq):
    kw: dict[str, Any] = dict(
        text=req.text,
        cfg_value=req.cfg_value,
        inference_timesteps=req.inference_timesteps,
        seed=req.seed,
    )
    if req.reference_wav_path:
        kw["reference_wav_path"] = _materialize_ref(req.reference_wav_path, "reference_wav_path")
    if req.prompt_wav_path:
        kw["prompt_wav_path"] = _materialize_ref(req.prompt_wav_path, "prompt_wav_path")
        if req.prompt_text:
            kw["prompt_text"] = req.prompt_text
    return _resp(_gen(**kw))


def main() -> None:
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=9883)
    ap.add_argument("--models", default=os.environ.get("VOX_MODELS", "/root/data/models/voxcpm2"),
                    help="VoxCPM2 权重目录（fetch_models.sh --tier vox 落的那个）")
    ap.add_argument("--denoiser", default=os.environ.get("VOX_DENOISER", "0") == "1",
                    action="store_true", help="加载降噪器（更干净但更慢更吃显存）")
    ARGS = ap.parse_args()
    log.info("VoxCPM2 server on :%d  models=%s", ARGS.port, ARGS.models)
    uvicorn.run(APP, host=ARGS.host, port=ARGS.port, log_level="info")


if __name__ == "__main__":
    main()
