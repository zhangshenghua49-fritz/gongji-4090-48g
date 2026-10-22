#!/usr/bin/env bash
# 把 workflows/*.json 提交给 ComfyUI，并等它跑完。
#
#   bash run_wf.sh workflows/h3_t2va.json
#   bash run_wf.sh workflows/z_image_t2i.json 127.0.0.1:8188
#
# 输出文件落在 ComfyUI 的 output/ 下，前缀由工作流里 SaveVideo/SaveImage 的
# filename_prefix 决定（h3/… 与 zimg/…）。
set -euo pipefail

WF="${1:?用法: run_wf.sh <工作流.json> [host:port]}"
HOST="${2:-127.0.0.1:8188}"
[ -f "$WF" ] || { echo "找不到工作流: $WF" >&2; exit 2; }

# 手里没有 jq 也能跑：直接把工作流对象塞进 {"prompt": ...}
PAYLOAD=$(printf '{"prompt": %s}' "$(cat "$WF")")

RESP=$(curl -sS -X POST "http://$HOST/prompt" \
        -H 'Content-Type: application/json' -d "$PAYLOAD")
PID=$(printf '%s' "$RESP" | sed -n 's/.*"prompt_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

if [ -z "$PID" ]; then
  echo "提交失败，ComfyUI 返回：" >&2
  printf '%s\n' "$RESP" >&2
  echo >&2
  echo "常见原因：" >&2
  echo "  - 权重文件名和 fetch_models.sh 下下来的不一致（对照 extra_model_paths.yaml 的路径）" >&2
  echo "  - 自定义节点没装（先跑 doctor.sh 看 bad_nodes）" >&2
  echo "  - r2va 的 ref_image_* 动态输入不被 API 接受 —— 用界面打开该工作流后导出 API 格式" >&2
  exit 1
fi

echo "已提交 prompt_id=$PID，等待完成…"
START=$(date +%s)
while :; do
  sleep 3
  HIST=$(curl -sS "http://$HOST/history/$PID")
  case "$HIST" in
    *'"status_str": "error"'*|*'"status_str":"error"'*)
      echo "执行出错：" >&2
      printf '%s\n' "$HIST" >&2
      exit 1 ;;
    *'"completed": true'*|*'"completed":true'*)
      break ;;
  esac
  # /history 里还没这个 id 说明还在队列里
  ELAPSED=$(( $(date +%s) - START ))
  if [ $(( ELAPSED % 15 )) -lt 3 ]; then
    echo "  … 已等 ${ELAPSED}s"
  fi
done

echo "完成，用时 $(( $(date +%s) - START ))s"
echo "产物："
printf '%s' "$HIST" | grep -o '"filename": *"[^"]*"' | cut -d'"' -f4 | sed 's/^/  /'
