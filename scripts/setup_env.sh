#!/usr/bin/env bash
# setup_env.sh -- 共绩算力 4090 48G 镜像：环境层装配
#
# 设计前提（重要）：
#   各家语音/视频框架对 torch / numpy / transformers 的版本要求互相冲突。
#   例如 GPT-SoVITS 锁 torch 2.5.x，IndexTTS 要 2.6.x，ComfyUI 自带一套。
#   所以本脚本给每个服务建**独立 venv**（/opt/venvs/<name>），绝不混装。
#   代价是磁盘（每套 torch 约 2.5 GB），收益是可重复、可单独升级。
#
# 用法（云主机内，root）：
#   bash setup_env.sh              # 全量
#   bash setup_env.sh --min        # 只装 ComfyUI + 基础 TTS（省 ~12 GB）
#   bash setup_env.sh --probe      # 只探测，不改系统
#
# 幂等：重复跑安全。已存在的 venv 会跳过。
set -euo pipefail

# 脚本自己所在的目录。必须在这里算好：后面第 3 节会 cd 进 ComfyUI，
# 那时候再解析 ${BASH_SOURCE[0]}（相对路径 "scripts/setup_env.sh"）就指向
# /root/ComfyUI/scripts 了，cd 失败会被 set -e 直接杀掉整个装配。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MIN=0
PROBE=0
for a in "$@"; do
  case "$a" in
    --min)   MIN=1 ;;
    --probe) PROBE=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

ROOT=/root
DATA=$ROOT/data
MODELS=$DATA/models
VENS=$ROOT/venvs
LOGS=$ROOT/logs
SRC=$ROOT/src

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m   ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m   !!\033[0m %s\n' "$*"; }

# ----------------------------------------------------------------------------
say "0. 探测现状"
echo "  kernel     : $(uname -r)"
echo "  os         : $(grep -E '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '\"')"
echo "  python     : $(python3 -V 2>&1 || echo 'none')"
echo "  pip        : $(python3 -m pip -V 2>&1 | cut -d' ' -f1-2 || echo 'none')"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | sed 's/^/  gpu        : /'
else
  warn "nvidia-smi 不存在 -- 当前不在 GPU 容器里？装配可以继续，但无法验证显存"
fi
# $DATA 在全新镜像里还不存在，df 对不存在的路径会返回 1；
# 配上 set -euo pipefail 会让脚本在这里静默退出（build 日志里只有"0. 探测现状"就没有下文）。
mkdir -p "$DATA"
df -h / "$DATA" 2>/dev/null | sed 's/^/  df         : /' || df -h / | sed 's/^/  df         : /'

# ComfyUI 预装位置（社区基础镜像通常已带）
COMFY=""
for c in /root/ComfyUI /workspace/ComfyUI /app/ComfyUI /opt/ComfyUI; do
  [ -d "$c" ] && COMFY=$c && break
done
echo "  comfyui    : ${COMFY:-<not found, will clone>}"

if [ "$PROBE" = "1" ]; then
  say "probe only, exit"
  exit 0
fi

# ----------------------------------------------------------------------------
say "1. 系统依赖"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # ffmpeg: 所有音视频管线的地基; libsndfile: soundfile;
  # build-essential/cmake: 编译 monotonic_align、rwkv、各种 C 扩展;
  # git-lfs: 拉 HF 大权重; espeak-ng: 部分 TTS 的 G2P 兜底; libgl1: opencv
  # python3-dev: pyopenjtalk / monotonic_align 这类要现场编译 C 扩展的包需要 Python.h
  apt-get install -y -qq --no-install-recommends \
    ffmpeg libsndfile1 build-essential cmake git git-lfs curl wget unzip \
    python3-dev python3-venv \
    espeak-ng libgl1 libglib2.0-0 sox unzip zstd aria2 tmux htop jq \
    fonts-noto-cjk fontconfig
  git lfs install --skip-repo >/dev/null 2>&1 || true
  ok "apt 包就绪"
else
  warn "非 apt 系系统，跳过（若是 dnf 系请自行补 ffmpeg）"
fi

mkdir -p "$MODELS" "$VENS" "$LOGS" "$SRC"

# ----------------------------------------------------------------------------
say "2. uv + 国内源（比 pip 快一个量级，且 venv 管理干净）"
# 平台容器不直连外网，pip 默认走 pypi.org 会长时间超时。统一换清华源。
export PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
export PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-pypi.tuna.tsinghua.edu.cn}"
export UV_DEFAULT_INDEX="${UV_DEFAULT_INDEX:-$PIP_INDEX_URL}"
export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-120}"
ok "pip 源 → $PIP_INDEX_URL"

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # 装到 ~/.local/bin
  export PATH="$HOME/.local/bin:$PATH"
  grep -q 'local/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
command -v uv >/dev/null 2>&1 && ok "uv $(uv --version | awk '{print $2}')" || { warn "uv 安装失败，回退 pip"; UV=0; }
UV=${UV:-1}

mkvenv() {  # mkvenv <name> <python-version>
  local n=$1 py=${2:-3.10}
  if [ -x "$VENS/$n/bin/python" ]; then
    ok "venv/$n 已存在，跳过"
    return 0
  fi
  if [ "$UV" = "1" ]; then
    # --seed 才会装 pip/setuptools；没有 seed 的 uv venv 是空壳
    uv venv --python "$py" --seed "$VENS/$n" >/dev/null 2>&1 \
      || uv venv --seed "$VENS/$n" >/dev/null 2>&1 \
      || uv venv --python "$py" "$VENS/$n" >/dev/null 2>&1 \
      || uv venv "$VENS/$n" >/dev/null
  else
    python3 -m venv "$VENS/$n"
  fi
  # 升级 pip 失败不算错（uv venv 可能本来就没 pip，pipin 会走 uv pip）
  "$VENS/$n/bin/python" -m pip install -q --upgrade pip setuptools wheel 2>/dev/null \
    || VIRTUAL_ENV="$VENS/$n" uv pip install -q pip setuptools wheel 2>/dev/null \
    || true
  ok "venv/$n created"
}

pipin() {  # pipin <venv> <args...>
  local n=$1; shift
  if [ "$UV" = "1" ]; then
    VIRTUAL_ENV="$VENS/$n" uv pip install "$@"
  else
    "$VENS/$n/bin/python" -m pip install -q "$@"
  fi
}

# torch 用 cu124 轮子（4090 = sm_89，cu121/cu124 都覆盖；cu124 生态最新）
TORCH_IDX="https://download.pytorch.org/whl/cu124"

# ----------------------------------------------------------------------------
say "3. ComfyUI（图像 + 视频主引擎）"
if [ -z "$COMFY" ]; then
  # clone 到 $ROOT 而不是 $SRC：Dockerfile 的自检、boot.sh 的 COMFY_DIR、
  # extra_model_paths.yaml 全按 /root/ComfyUI 写死，放 $SRC 下会全线错位。
  # 上一次失败的构建会留下半成品目录，不清掉 git clone 会报
  # "destination path already exists and is not an empty directory"。
  rm -rf "$ROOT/ComfyUI" "$SRC/ComfyUI"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$ROOT/ComfyUI"
  COMFY="$ROOT/ComfyUI"
fi
cd "$COMFY"
if [ -x "$VENS/comfyui/bin/python" ]; then
  ok "comfyui venv 已存在"
else
  mkvenv comfyui 3.11
  pipin comfyui torch torchvision torchaudio --index-url "$TORCH_IDX"
  [ -f requirements.txt ] && pipin comfyui -r requirements.txt || true
fi
ok "ComfyUI: $COMFY"

# 视频生成必需的自定义节点（体积小，直接装）
say "3b. ComfyUI 自定义节点"
CN="$COMFY/custom_nodes"
mkdir -p "$CN"
clone_node() {  # clone_node <repo-url> <dir-name> <requirements?>
  local url=$1 name=$2 req=${3:-1}
  if [ -d "$CN/$name/.git" ]; then ok "node/$name 已存在"; return 0; fi
  git clone --depth 1 "$url" "$CN/$name" >/dev/null 2>&1 || { warn "clone $name 失败"; return 0; }
  if [ "$req" = "1" ] && [ -f "$CN/$name/requirements.txt" ]; then
    pipin comfyui -r "$CN/$name/requirements.txt" >/dev/null 2>&1 || warn "$name deps 部分失败"
  fi
  ok "node/$name"
}
clone_node https://github.com/ltdrdata/ComfyUI-Manager ComfyUI-Manager 0
clone_node https://github.com/cubiq/ComfyUI_essentials ComfyUI_essentials 1
clone_node https://github.com/kijai/ComfyUI-KJNodes ComfyUI-KJNodes 1
clone_node https://github.com/Fannovel16/comfyui_controlnet_aux comfyui_controlnet_aux 1
clone_node https://github.com/cubiq/ComfyUI_IPAdapter_plus ComfyUI_IPAdapter_plus 0
clone_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite ComfyUI-VideoHelperSuite 1
clone_node https://github.com/kijai/ComfyUI-WanVideoWrapper ComfyUI-WanVideoWrapper 1
clone_node https://github.com/rgthree/rgthree-comfy rgthree-comfy 0
clone_node https://github.com/pythongosssss/ComfyUI-Custom-Scripts ComfyUI-Custom-Scripts 0
clone_node https://github.com/city96/ComfyUI-GGUF ComfyUI-GGUF 1
clone_node https://github.com/chrisgoringe/cg-use-everywhere cg-use-everywhere 0
clone_node https://github.com/WASasquatch/was-node-suite-comfyui was-node-suite-comfyui 1

# ----------------------------------------------------------------------------
say "4. GPT-SoVITS（因幡巡 克隆主力 / 质量上限）"
if [ ! -d "$SRC/GPT-SoVITS/.git" ]; then
  git clone --depth 1 https://github.com/RVC-Boss/GPT-SoVITS.git "$SRC/GPT-SoVITS"
fi
if [ -x "$VENS/gptsovits/bin/python" ]; then
  ok "gptsovits venv 已存在"
else
  mkvenv gptsovits 3.10
  pipin gptsovits torch torchvision torchaudio --index-url "$TORCH_IDX"
  pipin gptsovits -r "$SRC/GPT-SoVITS/requirements.txt" || warn "GPT-SoVITS requirements 有失败项"
  # 中文需要 g2pw / pyopenjtalk，日文需要 pyopenjtalk
  pipin gptsovits pyopenjtalk g2p_en || true
fi
ok "GPT-SoVITS: $SRC/GPT-SoVITS"

# ----------------------------------------------------------------------------
# VoxCPM2 放在 MIN 判断**之外**：它是因幡巡配音的主力引擎，不是可选项。
# 2026-10-22 换将依据：日语零样本音色相似度 VoxCPM2 0.825 vs Ming-3.0 0.765；
# 输出 48kHz 直出（16k 参考音经 AudioVAE V2 非对称编解码），RTF ~0.3 on 4090。
# 走 PyPI 包 voxcpm；官方要求 Python >=3.10 <3.13、PyTorch >=2.5、CUDA >=12。
# 权重不在镜像里，由 fetch_models.sh --tier vox 在实例上下载（4.96 GB）。
say "5b. VoxCPM2（2B / 48kHz 直出 / 因幡巡日语克隆主力 / Apache-2.0）"
if [ -x "$VENS/vox/bin/python" ]; then
  ok "vox venv 已存在"
else
  mkvenv vox 3.11
  pipin vox torch torchvision torchaudio --index-url "$TORCH_IDX" || warn "vox torch 安装失败"
  pipin vox voxcpm fastapi uvicorn soundfile numpy pydantic \
    || warn "voxcpm 安装失败（检查 $PIP_INDEX_URL 是否可达）"
  if "$VENS/vox/bin/python" -c "from voxcpm import VoxCPM" 2>/dev/null; then
    ok "voxcpm 可导入"
  else
    warn "voxcpm 导入失败 —— 因幡巡配音回落到 IndexTTS-2.5 / Ming"
  fi
fi

# ----------------------------------------------------------------------------
if [ "$MIN" = "0" ]; then
say "5. IndexTTS-2.5（B站开源，中文情感控制最好之一 / 仓库 v2.5.0）"
# 2026-10-22：旧文档写的「index-tts:0.3.0 镜像」在仓库里没有对应 tag —— 实际
# release 只有 v1.5.0 / v2.0.0 / v2.5.0，故锁 v2.5.0。
if [ ! -d "$SRC/index-tts/.git" ]; then
  git clone --depth 1 --branch v2.5.0 https://github.com/index-tts/index-tts.git "$SRC/index-tts" 2>/dev/null \
    || git clone --depth 1 https://github.com/index-tts/index-tts.git "$SRC/index-tts" \
    || warn "index-tts clone 失败"
fi
if [ -d "$SRC/index-tts" ] && [ ! -x "$VENS/index/bin/python" ]; then
  mkvenv index 3.10
  pipin index torch torchvision torchaudio --index-url "$TORCH_IDX" || true
  [ -f "$SRC/index-tts/pyproject.toml" ] && pipin index -e "$SRC/index-tts" || true
fi

say "5c. MegaTTS3（零样本克隆，字节，音色相似度高）"
if [ ! -d "$SRC/MegaTTS3/.git" ]; then
  git clone --depth 1 https://github.com/bytedance/MegaTTS3.git "$SRC/MegaTTS3" || warn "MegaTTS3 clone 失败"
fi
if [ -d "$SRC/MegaTTS3" ] && [ ! -x "$VENS/megatts/bin/python" ]; then
  mkvenv megatts 3.10
  pipin megatts torch torchvision torchaudio --index-url "$TORCH_IDX" || true
  [ -f "$SRC/MegaTTS3/requirements.txt" ] && pipin megatts -r "$SRC/MegaTTS3/requirements.txt" || true
fi

say "7. Qwen3-TTS 1.7B（主力配音 / 零样本克隆 / 声音设计，apache-2.0）"
# 需要 Python 3.12：qwen-tts 官方要求。与 comfyui(3.11) 隔离，互不污染。
if [ -x "$VENS/qwen3tts/bin/python" ]; then
  ok "qwen3tts venv 已存在"
else
  # 官方推荐 3.12；拉不到就退 3.11 / 系统自带 3.10，装完用 import 实测兜底
  TTS_PY=""
  for pyv in 3.12 3.11 3.10; do
    rm -rf "$VENS/qwen3tts"
    if [ "$UV" = "1" ]; then
      uv venv --python "$pyv" "$VENS/qwen3tts" >/dev/null 2>&1 || continue
    else
      python3 -m venv "$VENS/qwen3tts" >/dev/null 2>&1 || continue
    fi
    TTS_PY=$pyv; break
  done
  if [ -z "$TTS_PY" ]; then
    warn "qwen3tts venv 创建失败（uv 拉不到 3.12/3.11，系统 python3 也不可用）"
  else
    ok "venv/qwen3tts on Python $TTS_PY"
    pipin qwen3tts torch torchvision torchaudio --index-url "$TORCH_IDX" || warn "qwen3tts torch 安装失败"
    pipin qwen3tts qwen-tts fastapi uvicorn soundfile numpy pydantic \
      || warn "qwen-tts 安装失败（检查 $PIP_INDEX_URL 是否可达 / Python 版本）"
    # 真实验证，而不是「装完就当成功」
    if "$VENS/qwen3tts/bin/python" -c "import qwen_tts, fastapi, soundfile" 2>/dev/null; then
      ok "qwen_tts 可导入"
    else
      warn "qwen_tts 导入失败 —— 配音功能不可用，其余不受影响"
    fi
    # flash-attn 是可选加速；编译可能十几分钟，失败由服务端自动退回 sdpa
    if pipin qwen3tts flash-attn --no-build-isolation >/dev/null 2>&1; then
      ok "flash-attn 已装"
    else
      warn "flash-attn 未装 → qwen3_tts_server.py 会用 sdpa（慢一些，功能一致）"
    fi
  fi
fi

say "7b. Ming-3.0-tts（AA 克隆榜开源第一 · 中文/日语 · 44.1 kHz · MIT）"
MING_REPO="$SRC/Ming-3.0-tts"
if [ ! -d "$MING_REPO/.git" ]; then
  git clone --depth 1 https://github.com/inclusionAI/Ming-3.0-tts.git "$MING_REPO" \
    || warn "Ming-3.0-tts clone 失败"
fi
if [ -d "$MING_REPO" ] && [ ! -x "$VENS/mingtts/bin/python" ]; then
  mkvenv mingtts 3.11
  # 版本锁死自官方 docker/Dockerfile：transformers 4.46.3 与 ComfyUI 不兼容，
  # 所以必须是独立 venv，不能和 comfyui 混。
  pipin mingtts torch==2.6.0 torchaudio==2.6.0 torchvision==0.21.0 \
    --index-url "$TORCH_IDX" || warn "mingtts torch 安装失败"
  pipin mingtts transformers==4.46.3 accelerate==1.3.0 soundfile==0.12.1 \
    diffusers==0.33.0 x_transformers onnxruntime inflect einops packaging \
    modelscope fla-core==0.4.1 atorch==1.7.0 fastapi uvicorn pydantic numpy \
    || warn "Ming-3.0-tts 依赖安装失败"
  # pynini 只做数字/单位的文本规范化，非核心；装不上就启动加 --no-text-normalization
  pipin mingtts pynini==2.1.6 >/dev/null 2>&1 \
    && ok "pynini 已装（文本规范化可用）" \
    || warn "pynini 未装 → mingtts 启动加 --no-text-normalization"
  "$VENS/mingtts/bin/python" -c "import torch, transformers" 2>/dev/null \
    && ok "mingtts 依赖可导入" \
    || warn "mingtts 导入失败 —— Ming 服务不可用，Qwen3-TTS / GPT-SoVITS 不受影响"
  # flash-attn 可选：Ming 内部有 SDPA 回退，不装只影响速度
  pipin mingtts flash-attn==2.7.4.post1 --no-build-isolation >/dev/null 2>&1 \
    && ok "flash-attn 已装" \
    || warn "flash-attn 未装 → Ming 走 SDPA（慢一些，功能一致）"
fi

say "8. MoeGoe + 因幡巡成品 VITS 声库（零训练，无需参考音频）"
MEGOE_REPO="$SRC/MoeGoe"
if [ ! -d "$MEGOE_REPO/.git" ]; then
  git clone --depth 1 https://github.com/CjangCjengh/MoeGoe.git "$MEGOE_REPO" \
    || warn "MoeGoe clone 失败"
fi
if [ -d "$MEGOE_REPO" ] && [ ! -x "$VENS/vits/bin/python" ]; then
  mkvenv vits 3.10
  pipin vits torch torchaudio --index-url "$TORCH_IDX" || warn "vits torch 安装失败"
  # MoeGoe 的 zh_ja_mixture_cleaners 依赖这几个：jieba/pypinyin 管中文，
  # jaconv/pyopenjtalk 管日语，g2p_en 兜英文。缺一个 cleaner 就抛 KeyError。
  pipin vits numpy scipy librosa jieba pypinyin jaconv pyopenjtalk g2p_en \
    fastapi uvicorn soundfile pydantic \
    || warn "MoeGoe 依赖安装失败"
  "$VENS/vits/bin/python" -c "import torch, jieba, pyopenjtalk" 2>/dev/null \
    && ok "vits 依赖可导入" \
    || warn "vits 导入失败 —— 只影响成品 VITS 声库，Ming / Qwen3-TTS 不受影响"
fi

say "9. faster-whisper（字幕 / 歌词对齐 / 语料切分）"
mkvenv asr 3.11
pipin asr faster-whisper >/dev/null 2>&1 && ok "faster-whisper" || warn "faster-whisper 安装失败"

say "10. audio-separator（人声分离 UVR，语料清洗 / 视频配乐分离）"
mkvenv sep 3.11
pipin sep audio-separator onnxruntime-gpu >/dev/null 2>&1 && ok "audio-separator" || warn "audio-separator 安装失败"
fi  # MIN

# ----------------------------------------------------------------------------
say "11. 模型目录软链（ComfyUI 指向共享存储卷）"
mkdir -p "$MODELS"/{diffusion_models,text_encoders,vae,loras,checkpoints,clip_vision,upscale_models,audio_encoders,controlnet}
if [ -d "$COMFY/models" ] && [ ! -L "$COMFY/models" ]; then
  # 保留镜像自带的少量文件，其余走软链
  for sub in diffusion_models text_encoders vae loras clip_vision upscale_models audio_encoders controlnet; do
    if [ ! -e "$COMFY/models/$sub" ]; then
      ln -sfn "$MODELS/$sub" "$COMFY/models/$sub"
    elif [ -d "$COMFY/models/$sub" ] && [ -z "$(ls -A "$COMFY/models/$sub" 2>/dev/null)" ]; then
      rmdir "$COMFY/models/$sub" 2>/dev/null && ln -sfn "$MODELS/$sub" "$COMFY/models/$sub"
    fi
  done
  ok "已软链（若已有文件则不覆盖）"
fi

# ----------------------------------------------------------------------------
say "12. 工作流模板"
mkdir -p "$ROOT/workflows"
if [ -d "$PROJECT_DIR/workflows" ]; then
  if cp -f "$PROJECT_DIR/workflows/"*.json "$ROOT/workflows/" 2>/dev/null; then
    ok "已就位 $ROOT/workflows/：$(ls "$ROOT/workflows" | tr '\n' ' ')"
  else
    warn "工作流拷贝失败（源目录 $PROJECT_DIR/workflows）"
  fi
else
  warn "没找到 workflows/ 目录，跳过（run_wf.sh 需要它）"
fi

# ----------------------------------------------------------------------------
say "13. 写入统一入口"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/comfyui" <<'EOF'
#!/usr/bin/env bash
exec /root/venvs/comfyui/bin/python "${COMFY_DIR:-/root/ComfyUI}/main.py" --listen 0.0.0.0 --port 8188 "$@"
EOF
chmod +x "$ROOT/bin/comfyui"

cat > "$ROOT/bin/qwen3tts" <<'EOF'
#!/usr/bin/env bash
# 启动 Qwen3-TTS HTTP 服务（:9880）。模型按需懒加载，H3 抢显存时调 /unload 立刻腾空。
exec /root/venvs/qwen3tts/bin/python "${TTS_SERVER:-/root/scripts/qwen3_tts_server.py}" \
  --models "${TTS_MODELS:-/root/data/models/tts/qwen3-tts}" \
  --prompt-dir "${VOICE_PROMPTS:-/root/data/voice-prompts}" "$@"
EOF
chmod +x "$ROOT/bin/qwen3tts"

cat > "$ROOT/bin/mingtts" <<'EOF'
#!/usr/bin/env bash
# 启动 Ming-3.0-tts HTTP 服务（:9881）。与 Qwen3-TTS 二选一常驻，别同时挂着抢显存。
# pynini 没装时自动补 --no-text-normalization。
NORM=""
/root/venvs/mingtts/bin/python -c "import pynini" 2>/dev/null || NORM="--no-text-normalization"
exec /root/venvs/mingtts/bin/python "${MING_SERVER:-/root/scripts/ming_tts_server.py}" \
  --models "${MING_MODELS:-/root/data/models/tts/ming-3.0-tts}" \
  --repo "${MING_REPO:-/root/src/Ming-3.0-tts}" $NORM "$@"
EOF
chmod +x "$ROOT/bin/mingtts"

cat > "$ROOT/bin/vits" <<'EOF'
#!/usr/bin/env bash
# 启动因幡巡成品 VITS 声库服务（:9882）。不需要参考音频，权重下完就能出声。
# 换声库：VITS_MODEL=moetts vits
exec /root/venvs/vits/bin/python "${VITS_SERVER:-/root/scripts/vits_tts_server.py}" \
  --port "${VITS_PORT:-9882}" "$@"
EOF
chmod +x "$ROOT/bin/vits"

cat > "$ROOT/bin/voxcpm" <<'EOF'
#!/usr/bin/env bash
# 启动 VoxCPM2 HTTP 服务（:9883）—— 因幡巡日语克隆主力，48kHz 直出。
# 懒加载：第一次 POST 才占显存；H3 出片前 curl -XPOST :9883/unload 立刻腾空。
exec /root/venvs/vox/bin/python "${VOX_SERVER:-/root/scripts/vox_tts_server.py}" \
  --models "${VOX_MODELS:-/root/data/models/voxcpm2}" \
  --port "${VOX_PORT:-9883}" "$@"
EOF
chmod +x "$ROOT/bin/voxcpm"

cat > "$ROOT/env.sh" <<'EOF'
# source /root/env.sh
export PATH="$HOME/.local/bin:/root/bin:$PATH"
export COMFY_DIR="${COMFY_DIR:-/root/ComfyUI}"
export MODELS=/root/data/models
export TTS_MODELS=/root/data/models/tts/qwen3-tts
export VITS_ROOT=/root/data/models/vits
export VOX_MODELS=/root/data/models/voxcpm2
export MEGOE_DIR=/root/src/MoeGoe
export VOICE_PROMPTS=/root/data/voice-prompts
export SRC_DIR=/root/src
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export HF_HOME=/root/data/hf
export TORCH_HOME=/root/data/torch
export TRANSFORMERS_CACHE=/root/data/hf/transformers
export HF_HUB_ENABLE_HF_TRANSFER=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export TOKENIZERS_PARALLELISM=false
EOF

say "完成"
cat <<EOF

下一步：
  1) bash fetch_models.sh --tier core     # 拉模型权重（每档都幂等）
  2) bash doctor.sh                        # 验证
  3) 回控制台「保存镜像」                   # 见 README 第 5 节

venv 清单：$(ls "$VENS" 2>/dev/null | tr '\n' ' ')
模型目录：$MODELS
EOF
