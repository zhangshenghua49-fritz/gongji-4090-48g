#!/usr/bin/env bash
# boot.sh -- 容器启动命令（填在共绩控制台「启动命令」里）
#
#   启动命令：  bash /root/scripts/boot.sh
#   端口：      8188        <- ComfyUI 主界面，必须写这个端口才会映射出公网地址
#   显卡：      RTX 4090 48G x1
#
# 两种跑法（用 RUN_MODE 选）：
#   RUN_MODE=all（默认，清楚说：出图/出片 + 配音都要）
#       后台拉起 VoxCPM2 :9883（懒加载，不占显存）+ 前台 ComfyUI :8188
#   RUN_MODE=tts（只配音，不开 ComfyUI）
#       拉起 VoxCPM2 :9883 后常驻，端口那栏填 9883
#
# TTS_ENGINE 选配音引擎（默认 vox）：
#   vox   VoxCPM2 2B / 48kHz / 日语克隆最像本人   :9883   <- 因幡巡主力
#   ming  Ming-3.0-tts 0.5B / 44.1kHz / MIT       :9881   <- 对照组（英文更强）
#   qwen  Qwen3-TTS 1.7B / 10 语种                :9880   <- 备胎
#   一次只起一个：4090 48G 上 H3 全常驻要 42 GB，多份 TTS 会把它挤爆。
#   例外是 vox —— 它懒加载，第一个请求才占显存，所以和 H3 并存没问题；
#   但真同时跑之前建议 curl -XPOST :9883/unload 先腾空。
#
# 自愈：任何一步失败都只 warn 不退出 —— 少一个 TTS 不该让整个实例起不来。
set -uo pipefail

ROOT=${ROOT:-/root}
COMFY=${COMFY_DIR:-$ROOT/ComfyUI}
MODELS=${MODELS:-/root/data/models}
LOGS=${LOGS:-/root/logs}
SCRIPTS=${SCRIPTS:-/root/scripts}
TTS_ENGINE=${TTS_ENGINE:-vox}
RUN_MODE=${RUN_MODE:-all}
PY_COMFY=$ROOT/venvs/comfyui/bin/python

say() { printf '\n\033[1;36m[ boot ] %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m   ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m   !! %s\033[0m\n' "$*"; }

mkdir -p "$LOGS" /root/data/voice-prompts /root/data/output
[ -f "$ROOT/env.sh" ] && . "$ROOT/env.sh" || warn "缺 $ROOT/env.sh，用默认环境变量"

say "1/4 GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | sed 's/^/   /'
else
  warn "nvidia-smi 缺失 —— 实例可能没挂上 GPU"
fi

say "2/4 模型路径"
if [ -f "$SCRIPTS/../config/extra_model_paths.yaml" ]; then
  YAML="$SCRIPTS/../config/extra_model_paths.yaml"
elif [ -f "$ROOT/config/extra_model_paths.yaml" ]; then
  YAML="$ROOT/config/extra_model_paths.yaml"
else
  YAML=""
fi
if [ -n "$YAML" ] && [ -d "$COMFY" ]; then
  cp -f "$YAML" "$COMFY/extra_model_paths.yaml" && ok "extra_model_paths.yaml -> $COMFY"
else
  warn "未找到 extra_model_paths.yaml 或 ComfyUI 目录，回退软链模式"
  for sub in diffusion_models text_encoders vae loras model_patches audio_encoders latent_upscale_models; do
    mkdir -p "$COMFY/models/$sub" 2>/dev/null
    [ -d "$MODELS/$sub" ] && [ ! -L "$COMFY/models/$sub" ] && ln -sfn "$MODELS/$sub" "$COMFY/models/$sub"
  done
fi
du -sh "$MODELS" 2>/dev/null | sed 's/^/   权重总量: /'

# ---------------------------------------------------------------------------
# 3/4 配音
# ---------------------------------------------------------------------------
start_vox() {
  local py=$ROOT/venvs/vox/bin/python
  if [ ! -x "$py" ]; then
    warn "vox venv 未装（镜像应为 slim 及以上），跳过"; return 1
  fi
  if [ ! -f "$SCRIPTS/vox_tts_server.py" ]; then
    warn "缺 $SCRIPTS/vox_tts_server.py"; return 1
  fi
  nohup "$py" "$SCRIPTS/vox_tts_server.py" \
      --host 0.0.0.0 --port "${VOX_PORT:-9883}" \
      --models "${VOX_MODELS:-$MODELS/voxcpm2}" \
      >"$LOGS/voxcpm.log" 2>&1 &
  echo $! > "$LOGS/voxcpm.pid"
  ok "VoxCPM2 :${VOX_PORT:-9883} pid $(cat "$LOGS/voxcpm.pid")，日志 $LOGS/voxcpm.log（懒加载，未占显存）"
}

start_ming() {
  local py=$ROOT/venvs/mingtts/bin/python
  local repo=${MING_REPO:-$ROOT/src/Ming-3.0-tts}
  if [ ! -x "$py" ] || [ ! -f "$SCRIPTS/ming_tts_server.py" ]; then
    warn "mingtts 未装或仓库缺失（$repo），跳过"; return 1
  fi
  # pynini 只做数字/单位规范化，没装就关掉，不影响合成
  local NORM=""
  "$py" -c "import pynini" 2>/dev/null || NORM="--no-text-normalization"
  nohup "$py" "$SCRIPTS/ming_tts_server.py" \
      --host 0.0.0.0 --port 9881 \
      --models "${MING_MODELS:-$MODELS/tts/ming-3.0-tts}" \
      --repo "$repo" $NORM \
      >"$LOGS/mingtts.log" 2>&1 &
  echo $! > "$LOGS/mingtts.pid"
  ok "Ming-3.0-tts :9881 pid $(cat "$LOGS/mingtts.pid")，日志 $LOGS/mingtts.log"
}

start_qwen() {
  local py=$ROOT/venvs/qwen3tts/bin/python
  if [ ! -x "$py" ] || [ ! -f "$SCRIPTS/qwen3_tts_server.py" ]; then
    warn "qwen3tts 未装，跳过"; return 1
  fi
  nohup "$py" "$SCRIPTS/qwen3_tts_server.py" \
      --host 0.0.0.0 --port 9880 \
      --models "${TTS_MODELS:-$MODELS/tts/qwen3-tts}" \
      --prompt-dir "${VOICE_PROMPTS:-/root/data/voice-prompts}" \
      >"$LOGS/qwen3tts.log" 2>&1 &
  echo $! > "$LOGS/qwen3tts.pid"
  ok "Qwen3-TTS :9880 pid $(cat "$LOGS/qwen3tts.pid")，日志 $LOGS/qwen3tts.log"
}

say "3/4 配音（TTS_ENGINE=$TTS_ENGINE）"
case "$TTS_ENGINE" in
  vox)  start_vox  || start_ming || start_qwen || warn "三个引擎都没起来，只有出图/出片可用" ;;
  ming) start_ming || start_vox  || start_qwen || warn "三个引擎都没起来" ;;
  qwen) start_qwen || start_vox  || start_ming || warn "三个引擎都没起来" ;;
  none) ok "TTS_ENGINE=none，全部跳过（把显存全留给 H3）" ;;
  *)    warn "未知 TTS_ENGINE=$TTS_ENGINE，按 vox 处理"; start_vox || true ;;
esac

# ---------------------------------------------------------------------------
# 4/4 前台
# ---------------------------------------------------------------------------
if [ "$RUN_MODE" = "tts" ]; then
  say "4/4 RUN_MODE=tts —— 不起 ComfyUI，容器常驻等配音请求"
  echo "   端口那栏请填 $([ "$TTS_ENGINE" = "qwen" ] && echo 9880 || ([ "$TTS_ENGINE" = "ming" ] && echo 9881 || echo 9883))"
  trap 'echo "[ boot ] 收到停止信号"; kill $(cat "$LOGS"/*.pid 2>/dev/null) 2>/dev/null; exit 0' TERM INT
  while :; do sleep 3600; done
fi

say "4/4 ComfyUI (:8188) 前台"
if [ ! -f "$COMFY/main.py" ]; then
  warn "缺 $COMFY/main.py —— 只跑 TTS，容器常驻"
  while :; do sleep 3600; done
fi

cd "$COMFY" || exit 1
EXTRA=()
[ -f "$COMFY/extra_model_paths.yaml" ] && EXTRA=(--extra-model-paths-config "$COMFY/extra_model_paths.yaml")

exec "$PY_COMFY" main.py \
  --listen 0.0.0.0 --port 8188 \
  --preview-method auto \
  --output-directory /root/data/output \
  "${EXTRA[@]}" "$@"
