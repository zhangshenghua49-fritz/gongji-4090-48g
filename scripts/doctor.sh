#!/usr/bin/env bash
# doctor.sh -- 镜像自检 / 验收
#
#   bash doctor.sh          # 全量检查
#   bash doctor.sh --fast   # 跳过推理级测试（只查文件与环境）
#
# 退出码：0 = 核心档全绿；1 = 有 FAIL（明细见末尾汇总）
# 设计原则：只读不写（除了临时文件），可以在保存镜像前放心跑。
set -uo pipefail

FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

ROOT=${ROOT:-/root}
COMFY=${COMFY_DIR:-$ROOT/ComfyUI}
MODELS=${MODELS:-/root/data/models}
TTS_MODELS=${TTS_MODELS:-$MODELS/tts/qwen3-tts}
MING_REPO=${MING_REPO:-/root/src/Ming-3.0-tts}
VENS=$ROOT/venvs
PASS=0; FAIL=0; WARN=0
FAILS=()

hdr() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
pass(){ PASS=$((PASS+1)); printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
fail(){ FAIL=$((FAIL+1)); FAILS+=("$*"); printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; }
warn(){ WARN=$((WARN+1)); printf '\033[1;33m  WARN\033[0m %s\n' "$*"; }
# opt <路径> <最小 MB> —— 可选档：装了才校验，没装只打一行提示
opt(){ if [ -f "$1" ]; then chkfile "$1" "$2"; else echo "   -  未装 $(basename "$1")"; fi; }

# chk <描述> <命令...>
chk() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# chkfile <路径> <最小 MB>
chkfile() {
  local p=$1 minmb=${2:-1}
  if [ ! -f "$p" ]; then fail "缺文件 $(basename "$p")  [$p]"; return; fi
  local mb=$(( $(stat -c%s "$p") / 1048576 ))
  if [ "$mb" -ge "$minmb" ]; then pass "$(basename "$p")  ${mb} MB"
  else fail "$(basename "$p") 只有 ${mb} MB（应 ≥ ${minmb} MB，疑似下载不全）"; fi
}

# ---------------------------------------------------------------------------
hdr "1. 硬件与系统"
command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi 不存在"
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
  echo "  GPU: $GPU  ${MEM} MiB"
  # 4090 48G 魔改版实测 49140 MiB；44~50 GB 都算对
  if [ "${MEM:-0}" -ge 44000 ]; then pass "显存 ${MEM} MiB（48G 档）"
  else warn "显存 ${MEM} MiB，不是 48G 魔改卡 —— 大模型档位需下调"; fi
  DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
  echo "  driver: $DRV"
fi
FREE_GB=$(df -BG --output=avail "$ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')
echo "  系统盘可用: ${FREE_GB:-?} GB"
[ "${FREE_GB:-0}" -lt 25 ] && warn "系统盘 < 25 GB 空余，保存镜像可能失败（镜像层不含数据盘）"

hdr "2. Python 环境"
for v in comfyui vox qwen3tts mingtts vits asr; do
  if [ -x "$VENS/$v/bin/python" ]; then
    pass "venv/$v  $("$VENS/$v/bin/python" -V 2>&1)"
  else
    case "$v" in
      comfyui) fail "venv/$v 缺失（ComfyUI 出图/出片全靠它）" ;;
      vox)     fail "venv/$v 缺失（因幡巡配音主力，镜像应自带）" ;;
      *)       warn "venv/$v 缺失（可选档）" ;;
    esac
  fi
done
if [ -x "$VENS/vox/bin/python" ]; then
  # VoxCPM2：因幡巡配音主力，必须能 import
  chk "voxcpm 可导入" "$VENS/vox/bin/python" -c "from voxcpm import VoxCPM"
  chk "vox torch.cuda 可用" "$VENS/vox/bin/python" -c "import torch;assert torch.cuda.is_available()"
fi
if [ -x "$VENS/qwen3tts/bin/python" ]; then
  chk "qwen_tts 可导入" "$VENS/qwen3tts/bin/python" -c "import qwen_tts"
  chk "torch.cuda 可用" "$VENS/qwen3tts/bin/python" -c "import torch;assert torch.cuda.is_available()"
  if "$VENS/qwen3tts/bin/python" -c "import flash_attn" 2>/dev/null; then
    pass "flash_attn 已装"
  else
    warn "flash_attn 未装 → TTS 走 sdpa（可用，速度略低）"
  fi
fi
if [ -x "$VENS/mingtts/bin/python" ]; then
  # Ming 的依赖树独立于其他 venv（transformers 锁 4.46.3），单独验证
  chk "mingtts torch+transformers 可导入" "$VENS/mingtts/bin/python" -c "import torch, transformers"
  chk "mingtts torch.cuda 可用" "$VENS/mingtts/bin/python" -c "import torch;assert torch.cuda.is_available()"
  [ -d "${MING_REPO:-/root/src/Ming-3.0-tts}" ] && pass "Ming-3.0-tts 仓库就位" \
    || warn "缺 ${MING_REPO:-/root/src/Ming-3.0-tts}（setup_env.sh 会 clone）"
  "$VENS/mingtts/bin/python" -c "import pynini" 2>/dev/null \
    && pass "pynini 已装（文本规范化可用）" \
    || warn "pynini 未装 → 启动需 --no-text-normalization"
fi
if [ -x "$VENS/comfyui/bin/python" ]; then
  chk "torch.cuda 可用(comfyui)" "$VENS/comfyui/bin/python" -c "import torch;assert torch.cuda.is_available()"
  "$VENS/comfyui/bin/python" -c "
import torch, sys
v = torch.__version__.split('+')[0]
sys.exit(0 if tuple(map(int, v.split('.')[:2])) >= (2, 7) else 1)" 2>/dev/null \
    && pass "torch ≥ 2.7（H3 / LTX-2.5 需要）" || warn "torch < 2.7，H3 可能报错"
fi

hdr "3. ComfyUI"
if [ -f "$COMFY/main.py" ]; then
  pass "ComfyUI 在 $COMFY"
  [ -f "$COMFY/extra_model_paths.yaml" ] && pass "extra_model_paths.yaml 已就位" \
    || warn "extra_model_paths.yaml 未挂（boot.sh 会自动处理）"
  N=$(ls -1 "$COMFY/custom_nodes" 2>/dev/null | wc -l)
  echo "  custom_nodes: $N 个"
  [ "$N" -lt 1 ] && warn "自定义节点为 0，视频工作流会缺节点"
else
  fail "缺 $COMFY/main.py"
fi

hdr "4. 模型权重（核心档 / img）"
chkfile "$MODELS/diffusion_models/z_image_turbo_nvfp4.safetensors" 3000
chkfile "$MODELS/text_encoders/qwen_3_4b_fp4_mixed.safetensors" 2500
chkfile "$MODELS/vae/ae.safetensors" 200
for k in CustomVoice VoiceDesign Base; do
  chkfile "$TTS_MODELS/$k/model.safetensors" 3000
  chkfile "$TTS_MODELS/$k/speech_tokenizer/model.safetensors" 100
done
chkfile "$MODELS/tts/faster-whisper-large-v3/model.bin" 2000
# 因幡巡成品 VITS 声库（--tier vits，零训练直读）
chkfile "$MODELS/vits/sanoba/model.pth" 140
chkfile "$MODELS/vits/sanoba/config.json" 1
chkfile "$MODELS/vits/moetts/model.pth" 400
# Ming-3.0-tts：权重 + 说话人编码器（campplus 缺了能合成但没法克隆）
chkfile "$MODELS/tts/ming-3.0-tts/model.safetensors" 900
chkfile "$MODELS/tts/ming-3.0-tts/campplus.onnx" 20
chkfile "$MODELS/tts/ming-3.0-tts/config.json" 1
# VoxCPM2（--tier vox）：因幡巡主力，2B 权重 4.58 GB + AudioVAE 0.38 GB
chkfile "$MODELS/voxcpm2/model.safetensors" 4000
chkfile "$MODELS/voxcpm2/audiovae.pth" 300
chkfile "$MODELS/voxcpm2/config.json" 1
chkfile "$MODELS/voxcpm2/tokenization_voxcpm2.py" 1

hdr "5. 模型权重（可选档，存在才校验）"
# Fish Audio S2 Pro（--tier fish）：11 GB，日语 CER 2.76 最好，匿名可下
opt "$MODELS/tts/fish-s2-pro/model-00001-of-00002.safetensors" 4000
opt "$MODELS/tts/fish-s2-pro/codec.pth" 1500
# GPT-SoVITS V5（--tier gsv）：s1 155 + s2Gv5turbo 766 + vocoder 58 + hubert 189 + roberta 651
opt "$MODELS/gpt_sovits/pretrained_models/s1v3.ckpt" 140
opt "$MODELS/gpt_sovits/pretrained_models/gsv-v5-pretrained/s2Gv5turbo.pth" 700
opt "$MODELS/gpt_sovits/pretrained_models/gsv-v5-pretrained/vocoder.pth" 50
opt "$MODELS/gpt_sovits/pretrained_models/chinese-roberta-wwm-ext-large/pytorch_model.bin" 600
# MOSS-Image（--tier moss）：Apache-2.0 图像主力，int8 5.41 + TE 9.75 + vae 0.34
opt "$MODELS/diffusion_models/moss_image_sft_int8_convrot.safetensors" 5000
opt "$MODELS/text_encoders/qwen3.5_9b_int8_convrot.safetensors" 9000
# FLUX 3 klein（--tier flux3k）：int8 档 5.83 + 4.86 + 0.34
opt "$MODELS/diffusion_models/flux3-image-klein-int8-convrot.safetensors" 5000
opt "$MODELS/text_encoders/qwen3vl_4b_int8_convrot.safetensors" 4000
opt "$MODELS/diffusion_models/Qwen-Image-2.1-FP8.safetensors" 15000
opt "$MODELS/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" 15000
opt "$MODELS/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors" 12000
opt "$MODELS/diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors" 15000
opt "$MODELS/diffusion_models/wan2.2_s2v_14B_fp8_scaled.safetensors" 12000

hdr "6. 服务与端口"
if command -v curl >/dev/null 2>&1; then
  # TTS 引擎只会有一个常驻（boot.sh 的 TTS_ENGINE 决定），9883 是默认的 VoxCPM2
  for p in 9883:VoxCPM2 9881:Ming-3.0-tts 9880:Qwen3-TTS 9882:Inaba-VITS; do
    port=${p%%:*}; tname=${p#*:}
    H=$(curl -s --max-time 3 "http://127.0.0.1:$port/health" 2>/dev/null)
    if [ -n "$H" ]; then
      pass "$tname :$port 存活"
      echo "$H" | head -c 320 | sed 's/^/   /'; echo
    else
      warn "$tname :$port 未响应（未启动属正常，boot.sh 只拉 TTS_ENGINE 指定的那个）"
    fi
  done
  curl -s --max-time 3 -o /dev/null http://127.0.0.1:8188/ \
    && pass "ComfyUI :8188 存活" || warn "ComfyUI :8188 未响应（未启动属正常）"
fi

if [ "$FAST" = "0" ]; then
  hdr "7. 最小推理冒烟（Z-Image-Turbo，单张 512×512）"
  if [ -x "$VENS/comfyui/bin/python" ] && [ -f "$MODELS/diffusion_models/z_image_turbo_nvfp4.safetensors" ]; then
    OUT=$(mktemp -u /tmp/doctor_XXXX.png)
    if "$VENS/comfyui/bin/python" - "$MODELS" "$OUT" <<'PY' 2>/tmp/doctor_smoke.err
import sys, torch
models, out = sys.argv[1], sys.argv[2]
from safetensors.torch import load_file
sd = load_file(f"{models}/diffusion_models/z_image_turbo_nvfp4.safetensors", device="cuda")
assert len(sd) > 10, "权重为空"
del sd; torch.cuda.empty_cache()
open("/tmp/.doctor_smoke_ok","w").write("1")
PY
    then pass "扩散权重可上卡解包（未做完整采样，省时）"
    else fail "扩散权重加载失败，见 /tmp/doctor_smoke.err"; fi
  else
    warn "跳过冒烟测试（缺 comfyui venv 或 Z-Image 权重）"
  fi
fi

hdr "8. 工作流模板"
if [ -d "$ROOT/workflows" ]; then
  WF_N=$(ls "$ROOT/workflows"/*.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "$WF_N" -gt 0 ]; then
    pass "工作流 $WF_N 个（$(ls "$ROOT/workflows" | tr '\n' ' ')）"
    if command -v python3 >/dev/null 2>&1; then
      for f in "$ROOT/workflows"/*.json; do
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null \
          || fail "$(basename "$f") JSON 解析失败"
      done
    fi
  else
    warn "目录在但是空的，工作流没上传"
  fi
else
  warn "没有 $ROOT/workflows（setup_env.sh 的 10.5 步没跑或没有 workflows/ 源目录）"
fi

hdr "9. 磁盘占用"
du -sh "$MODELS" 2>/dev/null | sed 's/^/   models  /'
du -sh "$ROOT/venvs" 2>/dev/null | sed 's/^/   venvs   /'
du -sh "$COMFY" 2>/dev/null | sed 's/^/   comfy   /'

# ---------------------------------------------------------------------------
hdr "汇总"
printf '  PASS %d   WARN %d   FAIL %d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "  失败项（修完重跑本脚本）："
  printf '    - %s\n' "${FAILS[@]}"
  exit 1
fi
echo "  核心档全绿，可以保存镜像。"
