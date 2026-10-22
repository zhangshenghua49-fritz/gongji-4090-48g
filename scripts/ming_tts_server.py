#!/usr/bin/env python3
"""
ming_tts_server.py -- Ming-3.0-tts HTTP 服务（克隆 / 音色设计 / 情感 / 中文 IP 音色）

为什么单独一个服务而不是并进 qwen3_tts_server.py：
  Ming-3.0-tts 硬锁 transformers==4.46.3 + torch 2.6.0（官方 docker/Dockerfile），
  与 ComfyUI / qwen-tts 的依赖树冲突，必须独立 venv、独立进程。

API 依据官方 ming_tts.py 实测签名（唯一入口，所有任务共用）：
    MingTTS(model_path, device="cuda:0", text_normalization=True, cache_prompts=True)
    .synthesize(task, text, language_id=None, instruction=None, controls=None,
                instruction_schema=None, prompt_wav_path=None, prompt_text=None,
                spk_emb_path=None, use_spk_emb=False, use_zero_spk_emb=False,
                cfg=2.0, sigma=0.25, temperature=0.0, max_length=24,
                max_decode_steps=1000, trim_silence=True, raw_text=False,
                output_path=None) -> (1, samples)

task 取值（tts_tasks._TASK_ALIASES）：
    TTS          通用合成；带 prompt_wav_path 即零样本音色克隆
    BASIC        语速/音高/音量 结构化控制
    EMOTION      情感：高兴/悲伤/愤怒/恐惧/厌恶/惊讶/中性
    DIALECT      方言：chuanyu dialect / cantonese
    IP           内置音色（中文 100+；英文 US_Emma/US_James/UK_George/UK_Charlotte）
    VOICE_DESIGN 自然语言描述造音色（别名 STYLE / FREEFORM）

language_id：zh / en / ja / ko / de / fr / es
    注意 ja/ko/de/fr/es 属于 Ming-3.0 新增五语，**必须显式传**，否则按中文处理。

启动：
    python ming_tts_server.py --port 9881 \
        --models /root/data/models/tts/ming-3.0-tts --repo /root/Ming-3.0-tts
"""
from __future__ import annotations

import argparse
import base64
import io
import logging
import sys
import time
from pathlib import Path
from typing import Any, Union

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mingtts")

APP = FastAPI(title="Ming-3.0-tts", version="1.0")

STATE: dict[str, Any] = {
    "model": None,
    "load_time": 0.0,
    "root": None,
    "repo": None,
    "sr": 44100,          # 官方模型卡标称 44.1 kHz
    "device": "cuda:0",
    "text_norm": True,
}

TASKS = ("TTS", "BASIC", "EMOTION", "DIALECT", "IP", "VOICE_DESIGN")
LANGUAGES = ("zh", "en", "ja", "ko", "de", "fr", "es")
EMOTIONS = ("高兴", "悲伤", "愤怒", "恐惧", "厌恶", "惊讶", "中性")


# ---------------------------------------------------------------------------
# 加载
# ---------------------------------------------------------------------------
def _ensure_repo() -> None:
    """MingTTS 不是 pip 包，必须把仓库根目录塞进 sys.path。"""
    repo = Path(STATE["repo"])
    if not repo.is_dir():
        raise HTTPException(500, f"Ming-3.0-tts 仓库不存在: {repo}")
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))


def _load():
    """懒加载。4090 48G 上视频模型要 39 GB，TTS 必须能随时让位。"""
    if STATE["model"] is not None:
        return STATE["model"]

    _ensure_repo()
    from ming_tts import MingTTS          # noqa: PLC0415  (延迟导入：依赖仓库路径)

    root = Path(STATE["root"])
    if not root.is_dir():
        raise HTTPException(500, f"模型目录不存在: {root}")

    log.info("loading Ming-3.0-tts <- %s", root)
    t0 = time.time()
    model = MingTTS(
        str(root),
        device=STATE["device"],
        text_normalization=STATE["text_norm"],
    )

    # 采样率优先问模型自己，问不到用官方标称值
    sr = getattr(model, "sample_rate", None) or getattr(model, "sr", None)
    if isinstance(sr, (int, float)) and 8000 <= sr <= 192000:
        STATE["sr"] = int(sr)

    STATE["model"] = model
    STATE["load_time"] = time.time() - t0
    log.info("loaded in %.1fs, sr=%d", STATE["load_time"], STATE["sr"])
    return model


def _unload():
    STATE["model"] = None
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
def _materialize_ref(ref: str) -> str:
    """参考音频必须是本地文件路径。

    支持 data:base64 与裸 base64，落盘成临时 wav 再交给模型 ——
    MingTTS.prepare_prompt 走 torchaudio.load，只认路径。
    """
    if ref.startswith(("http://", "https://")):
        raise HTTPException(400, "参考音频请先下载到本地再传路径")
    if ref.startswith("data:") or (len(ref) > 256 and "/" not in ref[:64]):
        raw = ref.split(",", 1)[-1] if ref.startswith("data:") else ref
        data = base64.b64decode(raw)
        out = Path("/tmp") / "ming_ref.wav"
        out.write_bytes(data)
        return str(out)
    if not Path(ref).is_file():
        raise HTTPException(400, f"参考音频不存在: {ref}")
    return ref


def _wav(waveform, sr: int) -> bytes:
    if isinstance(waveform, torch.Tensor):
        arr = waveform.detach().float().cpu().numpy()
    else:
        arr = np.asarray(waveform, dtype=np.float32)
    arr = np.squeeze(arr)
    if arr.ndim > 1:                       # (ch, n) -> (n,)
        arr = arr.mean(axis=0)
    peak = float(np.max(np.abs(arr))) if arr.size else 0.0
    if peak > 1.0:                         # 防削波
        arr = arr / peak
    buf = io.BytesIO()
    sf.write(buf, arr.astype(np.float32), sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def _synth(**kw) -> bytes:
    model = _load()
    t0 = time.time()
    try:
        wav = model.synthesize(**kw)
    except Exception as exc:
        log.exception("synthesize failed")
        raise HTTPException(500, f"synthesize 失败: {exc}") from exc
    log.info("synthesize ok in %.1fs (task=%s)", time.time() - t0, kw.get("task"))
    return _wav(wav, STATE["sr"])


# ---------------------------------------------------------------------------
# 请求模型
# ---------------------------------------------------------------------------
class CloneReq(BaseModel):
    text: str
    language_id: str = Field("ja", description="zh/en/ja/ko/de/fr/es")
    ref_audio: str = Field(..., description="参考音频路径或 base64")
    ref_text: str = Field("", description="参考音频对应文本，留空走 x-vector 模式")
    use_spk_emb: bool = False


class DesignReq(BaseModel):
    text: str
    language_id: str = "ja"
    instruction: str = Field(..., description="自然语言音色描述")


class IPReq(BaseModel):
    text: str
    speaker: str = Field(..., description="内置音色名，如 US_Emma")
    language_id: str = "zh"


class EmotionReq(BaseModel):
    text: str
    emotion: str = "中性"
    language_id: str = "zh"
    speaker: str = ""
    prompt_wav_path: str = ""


class BasicReq(BaseModel):
    text: str
    speed: str = "中速"
    pitch: str = "中"
    volume: str = "中"
    language_id: str = "zh"


class RawReq(BaseModel):
    text: str
    task: str = "TTS"
    language_id: Union[str, None] = None
    instruction: Union[str, None] = None
    controls: Union[dict, None] = None
    prompt_wav_path: Union[str, None] = None
    prompt_text: Union[str, None] = None
    cfg: float = 2.0
    sigma: float = 0.25
    temperature: float = 0.0


# ---------------------------------------------------------------------------
# 端点
# ---------------------------------------------------------------------------
@APP.get("/health")
def health():
    return {
        "ok": True,
        "loaded": STATE["model"] is not None,
        "load_time": round(STATE["load_time"], 1),
        "sample_rate": STATE["sr"],
        "root": STATE["root"],
        "gpu": _gpu(),
    }


@APP.post("/unload")
def unload():
    _unload()
    return {"ok": True, "gpu": _gpu()}


@APP.get("/capabilities")
def capabilities():
    return {
        "tasks": list(TASKS),
        "languages": list(LANGUAGES),
        "emotions": list(EMOTIONS),
        "dialects": ["chuanyu dialect", "cantonese"],
        "en_voices": ["US_Emma", "US_James", "UK_George", "UK_Charlotte"],
        "note": "zh/en 之外的五语必须显式传 language_id",
    }


@APP.post("/clone")
def clone(req: CloneReq):
    """零样本音色克隆：5-10 秒参考音频即可，无需训练。"""
    return _resp(_synth(
        task="TTS",
        text=req.text,
        language_id=req.language_id,
        prompt_wav_path=_materialize_ref(req.ref_audio),
        prompt_text=req.ref_text,
        use_spk_emb=req.use_spk_emb,
    ))


@APP.post("/design")
def design(req: DesignReq):
    """自然语言造音色。没有干净参考音频时，先用它造一版再拿去克隆。"""
    return _resp(_synth(
        task="VOICE_DESIGN",
        text=req.text,
        language_id=req.language_id,
        instruction=req.instruction,
    ))


@APP.post("/ip")
def ip_voice(req: IPReq):
    return _resp(_synth(
        task="IP",
        text=req.text,
        language_id=req.language_id,
        controls={"speaker": req.speaker},
    ))


@APP.post("/emotion")
def emotion(req: EmotionReq):
    controls: dict[str, Any] = {"emotion": req.emotion}
    if req.speaker:
        controls["speaker"] = req.speaker
    kw: dict[str, Any] = dict(task="EMOTION", text=req.text,
                              language_id=req.language_id, controls=controls)
    if req.prompt_wav_path:
        kw["prompt_wav_path"] = _materialize_ref(req.prompt_wav_path)
    return _resp(_synth(**kw))


@APP.post("/basic")
def basic(req: BasicReq):
    return _resp(_synth(
        task="BASIC",
        text=req.text,
        language_id=req.language_id,
        controls={"speed": req.speed, "pitch": req.pitch, "volume": req.volume},
    ))


@APP.post("/synth")
def synth(req: RawReq):
    """逃生口：直接透传 synthesize 参数，模型升级后不必改服务。"""
    kw: dict[str, Any] = dict(
        task=req.task, text=req.text, cfg=req.cfg,
        sigma=req.sigma, temperature=req.temperature,
    )
    if req.language_id:
        kw["language_id"] = req.language_id
    if req.instruction:
        kw["instruction"] = req.instruction
    if req.controls:
        kw["controls"] = req.controls
    if req.prompt_wav_path:
        kw["prompt_wav_path"] = _materialize_ref(req.prompt_wav_path)
    if req.prompt_text:
        kw["prompt_text"] = req.prompt_text
    return _resp(_synth(**kw))


def _resp(data: bytes):
    from fastapi.responses import Response

    return Response(content=data, media_type="audio/wav",
                    headers={"X-Sample-Rate": str(STATE["sr"])})


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=9881)
    ap.add_argument("--models", required=True, help="Ming-3.0-tts 权重目录")
    ap.add_argument("--repo", required=True, help="Ming-3.0-tts 仓库根目录")
    ap.add_argument("--device", default="cuda:0")
    ap.add_argument("--no-text-normalization", action="store_true",
                    help="跳过 pynini 文本规范化（pynini 没装时用）")
    args = ap.parse_args()

    STATE["root"] = args.models
    STATE["repo"] = args.repo
    STATE["device"] = args.device
    STATE["text_norm"] = not args.no_text_normalization

    uvicorn.run(APP, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
