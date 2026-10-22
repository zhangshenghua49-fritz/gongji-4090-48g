#!/usr/bin/env bash
# 本机一键：装 WSL2 + Ubuntu → 在 Ubuntu 里 build → push 到共绩 Harbor。
#
# 前提：Windows 10 2004+ / Windows 11，BIOS 里虚拟化已开。
# 代价：需要重启一次电脑（WSL 内核装完要重启才生效）。
#
# 用法（在本目录用 Git Bash 跑）：
#   bash scripts/wsl_build.sh            # 只装 WSL + Ubuntu，不 build
#   bash scripts/wsl_build.sh --build    # 装完顺手 build + push
#
# Harbor 凭据读环境变量，或在 runtime.env 里写：
#   HARBOR_REGISTRY=harbor.suanleme.cn
#   HARBOR_PROJECT=你的项目名
#   HARBOR_USER=...
#   HARBOR_PASS=...
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO_BUILD=0
[[ "${1:-}" == "--build" ]] && DO_BUILD=1

say() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
die() { printf '\033[31m[err] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 1. 检查 ----------
say "检查 WSL 状态"
if wsl.exe --status >/dev/null 2>&1; then
    echo "WSL 已安装"
    WSL_OK=1
else
    echo "WSL 未安装"
    WSL_OK=0
fi

if [[ $WSL_OK -eq 0 ]]; then
    say "安装 WSL2 + Ubuntu（会弹 UAC，请点「是」）"
    # --no-launch：装完不进 Ubuntu 交互界面，避免脚本卡住
    powershell.exe -NoProfile -Command \
        "Start-Process wsl.exe -ArgumentList '--install','-d','Ubuntu','--no-launch' -Verb RunAs -Wait" \
        || die "WSL 安装失败。手动在管理员 PowerShell 里跑：wsl --install -d Ubuntu --no-launch"
    cat <<'EOF'

[!] WSL 已提交安装，但需要【重启电脑】才生效。

重启后按顺序：
  1. 打开「Ubuntu」应用（或 PowerShell 跑 wsl），设一个用户名密码
  2. 回到 Git Bash，重跑：bash scripts/wsl_build.sh --build

EOF
    exit 0
fi

# ---------- 2. Ubuntu 里装 docker ----------
say "在 Ubuntu 内安装 docker + buildx"
wsl.exe -d Ubuntu -- bash -lc '
set -e
if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker.io docker-buildx >/dev/null
fi
sudo usermod -aG docker "$USER" || true
docker --version
' || die "Ubuntu 内 docker 安装失败"

# ---------- 3. 凭据 ----------
if [[ -f "$HERE/runtime.env" ]]; then
    # shellcheck disable=SC1091
    source "$HERE/runtime.env"
fi
: "${HARBOR_REGISTRY:=harbor.suanleme.cn}"
: "${HARBOR_PROJECT:?请设置 HARBOR_PROJECT（控制台「镜像仓库」里的项目名）}"
: "${HARBOR_USER:?请设置 HARBOR_USER（控制台「镜像仓库 → 访问凭证」）}"
: "${HARBOR_PASS:?请设置 HARBOR_PASS}"
TAG="${TAG:-v1}"
IMAGE="$HARBOR_REGISTRY/$HARBOR_PROJECT/gongji-4090-48g:$TAG"

if [[ $DO_BUILD -eq 0 ]]; then
    say "WSL 就绪。加 --build 才会构建。目标镜像：$IMAGE"
    exit 0
fi

# ---------- 4. build + push ----------
say "构建 $IMAGE（首次 20~40 分钟，取决于网速）"
# Windows 路径转 WSL 路径
WSL_PATH="$(wsl.exe -d Ubuntu -- wslpath -a "$HERE" | tr -d '\r')"
echo "WSL 工作目录: $WSL_PATH"

wsl.exe -d Ubuntu -- bash -lc "
set -e
cd '$WSL_PATH'
echo '$HARBOR_PASS' | sudo docker login '$HARBOR_REGISTRY' -u '$HARBOR_USER' --password-stdin
sudo docker build --platform linux/amd64 -t '$IMAGE' .
sudo docker push '$IMAGE'
"

say "完成"
cat <<EOF

镜像地址（填进云主机创建页的「我的镜像」）：

  $IMAGE

以后开机 1~3 分钟就是装好的环境，不需要再进容器装任何东西。

EOF
