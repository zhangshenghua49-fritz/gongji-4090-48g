#!/usr/bin/env bash
# 本地构建并推送到共绩 Harbor。推完之后，云主机创建页的「我的镜像」里就能选到。
#
#   export IMAGE=harbor.suanleme.cn/<项目名>/gongji-4090-48g
#   bash scripts/build_push.sh
#
# Harbor 的账号密码和平台账号不互通，去 控制台 → 镜像仓库 → 访问凭据 取。
# 项目名（<项目名> 那一段）也在同一个页面能看到，首次使用要先建项目。
#
# 注意：共绩的云主机是容器，禁 DinD，所以 build 只能在你自己机器上做，
# 不能在实例里 docker build。
set -euo pipefail

: "${IMAGE:?用法: IMAGE=harbor.suanleme.cn/<项目名>/gongji-4090-48g bash scripts/build_push.sh}"
TAG="${TAG:-v1}"

cd "$(dirname "$0")/.."

echo "构建 $IMAGE:$TAG"
docker build -t "$IMAGE:$TAG" .
docker push "$IMAGE:$TAG"

cat <<EOF

推完了。

1. 云主机创建页 → 镜像 → 我的镜像 → 填完整地址：
     $IMAGE:$TAG
2. 端口：8188（ComfyUI）、8888（JupyterLab）平台默认给；要 Gradio 7860 得手动加，
   加完必须点页面底部【应用修改】+【确认修改】。
3. 启动命令填：
     bash /root/gongji-4090-48g/scripts/boot.sh
4. 权重不带在镜像里，进实例后先拉一档：
     bash /root/scripts/fetch_models.sh --tier h3
EOF
