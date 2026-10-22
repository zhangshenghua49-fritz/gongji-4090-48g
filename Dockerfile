# 共绩算力 · 4090 48G · 环境层镜像
#
# 这个镜像里【没有模型权重】。权重几十上百 GB，塞不进 80GB 系统盘，
# 平台官方也是让权重放对象存储/共享存储卷、只读挂到 /root/data/models。
# 所以镜像只负责"进去就能跑"，权重由 fetch_models.sh 在实例里下。
#
# ---------------------------------------------------------------------------
# 构建（本机没 Docker 时走 GitHub Actions，见 .github/workflows/docker.yml）
#   docker build -t <hub-user>/gongji-4090-48g:slim .                 # 默认
#   docker build --build-arg SETUP_ARGS= -t <hub-user>/gongji-4090-48g:full .
# 国内拉不动 nvidia/cuda 就给 Docker 配镜像加速，或把下面 FROM 换成能访问的镜像源地址。
#
# 两个 flavor 的差别只在「TTS 备胎装不装」：
#   slim（默认，SETUP_ARGS=--min） ComfyUI + 节点 + VoxCPM2 + Qwen3-TTS + whisper
#   full（SETUP_ARGS=）           再加 IndexTTS-2.5 / MegaTTS3 / GPT-SoVITS / Ming / VITS
# 注意 VoxCPM2 在 setup_env.sh 里被放在 --min 判断**之外**：它因幡巡配音的主力，
# 不是可选件。
#
# 镜像自带能力（2026-10-22 版）：
#   图像  ComfyUI + Qwen-Image-2.1(FP8) + FLUX 3 klein + Z-Image-Turbo
#   视频  ComfyUI + MiniMax-H3(pruned_int8/nvfp4 TE) + LTX-2.5(int8) + Wan2.2
#   声音  VoxCPM2 :9883 / Qwen3-TTS :9880 / Ming :9881 / VITS :9882 / IndexTTS-2.5
# ---------------------------------------------------------------------------

FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04

LABEL org.opencontainers.image.title="gongji-4090-48g" \
      org.opencontainers.image.description="ComfyUI + MiniMax-H3 + Qwen-Image-2.1 + FLUX3 klein + VoxCPM2 for RTX 4090 48G" \
      org.opencontainers.image.version="2026.10.22" \
      org.opencontainers.image.source="https://github.com/ranxianglei/gongji-4090-48g"

ARG SETUP_ARGS="--min"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Shanghai \
    HF_ENDPOINT=https://hf-mirror.com \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
    UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple \
    PATH=/root/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip \
        git curl wget ca-certificates aria2 jq \
        ffmpeg libsndfile1 libgl1 libglib2.0-0 libgomp1 \
        build-essential espeak-ng \
        fonts-noto-cjk fonts-noto-cjk-extra \
        openssh-server supervisor \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

COPY . /root/gongji-4090-48g
WORKDIR /root/gongji-4090-48g

# 全程只走 pip，build 阶段不需要显卡。
# 网络抖动靠 3 次重试兜住；重试完仍缺 ComfyUI 就让 build 直接失败 —— 镜像里带一个残废环境
# 比 build 失败更坑，你会以为装好了。
RUN for i in 1 2 3; do \
        bash scripts/setup_env.sh $SETUP_ARGS && break; \
        echo "[retry $i] setup_env.sh 失败，10 秒后重试"; sleep 10; \
    done; test -x /root/bin/comfyui && test -f /root/ComfyUI/main.py

# VoxCPM2 是因幡巡配音主力，必须装成 —— 单独一道闸，别被上面任何一步的 warn 带过。
RUN test -x /root/venvs/vox/bin/python \
    || (echo "VoxCPM2 venv 缺失，重试一次" && bash scripts/setup_env.sh $SETUP_ARGS); \
    test -x /root/venvs/vox/bin/python

ENV COMFY_DIR=/root/ComfyUI \
    VOX_MODELS=/root/data/models/voxcpm2
EXPOSE 8188 8888 9880 9881 9882 9883
WORKDIR /root
CMD ["bash"]
