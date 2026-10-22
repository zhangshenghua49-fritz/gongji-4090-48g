#!/usr/bin/env bash
# fetch_models.sh -- 模型权重拉取（分档、幂等、可续传）
#
# 全部路径与体积均为 2026-10-22 实测（hf-mirror API tree?recursive=true 的 size 字段）。
# 镜像见 docs/stack-4090-48g.md。默认走 hf-mirror.com（HF 直连在国内会超时）。
#
# 用法：
#   bash fetch_models.sh --tier img      # Z-Image-Turbo + Qwen3-TTS + 因幡巡 + ASR   ~16 GB
#   bash fetch_models.sh --tier hq       # Qwen-Image-2.1 FP8（编辑/RGBA）            ~17 GB
#   bash fetch_models.sh --tier flux3k   # FLUX 3 Image klein（int8 档）                ~11 GB
#   bash fetch_models.sh --tier moss     # MOSS-Image（Apache-2.0 / JSON layout 分镜）   ~21 GB
#   bash fetch_models.sh --tier h3       # MiniMax-H3 全套（音视频同期声）             ~39 GB
#   bash fetch_models.sh --tier ltx      # LTX-2.5 全套（多镜头）                       ~39 GB
#   bash fetch_models.sh --tier wan      # Wan2.2 草稿 + S2V 口型对轨                  ~42 GB
#   bash fetch_models.sh --tier vox      # VoxCPM2（2B / 48kHz / 因幡巡克隆主力）        ~5 GB
#   bash fetch_models.sh --tier index25  # IndexTTS-2.5（中文情感控制）                  ~6 GB
#   bash fetch_models.sh --tier gsv      # GPT-SoVITS V5（角色克隆/可微调）+ UVR5     ~2.5 GB
#   bash fetch_models.sh --tier fish     # Fish Audio S2 Pro（日语吐字最准/零样本）     ~11 GB
#   bash fetch_models.sh --tier drama    # Fish Audio Drama 3（35B-A3B/int4/表演感最强） ~24 GB
#   bash fetch_models.sh --tier image    # hq + flux3k + moss（图像三大主力）
#   bash fetch_models.sh --tier video    # h3 + ltx + wan
#   bash fetch_models.sh --tier voice    # vox + tts + index25 + gsv + vits
#   bash fetch_models.sh --tier all      # 全部                                          ~180 GB
#   bash fetch_models.sh --tier h3 --dest /root/data/models    # 指定落盘目录
#
# 环境变量：FLUX3_DIT / FLUX3_TE 换精度档；FLUX3_UPSAMPLER=1 加 9B 提示词扩写器；
#           H3_DIT / H3_TE 同理。默认一律取 int8 / nvfp4 最小档以适配 4090 48G。
#           FLUX3_REPO / LTX_REPO 切回官方仓（gated，需同时给 HF_TOKEN）；
#           默认走 ml-resources / comfyicu 的等价镜像仓，匿名可下。
#
# 幂等：目标文件已存在且非空即跳过；curl -C - 支持断点续传，中断后重跑即可。
set -uo pipefail

HF_MIRROR="${HF_MIRROR:-https://hf-mirror.com}"
MODELS="${MODELS:-/root/data/models}"
TIER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    --dest) MODELS="$2"; shift 2 ;;
    --mirror) HF_MIRROR="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -z "$TIER" ] && { echo "需要 --tier（img|hq|flux3k|h3|ltx|wan|vox|index25|image|video|voice|all）" >&2; exit 2; }

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m   ok\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m   !!\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m   ERR\033[0m %s\n' "$*"; }

mkdir -p "$MODELS"/{diffusion_models,text_encoders,vae,loras,model_patches,audio_encoders,latent_upscale_models,clip_vision,checkpoints,tts,voice,gpt_sovits}

FAILED=()

# gated 仓库（black-forest-labs/* 、Lightricks/* 官方仓）要先在网页点同意 + 传 HF_TOKEN。
# 本脚本默认改走等价的非 gated 镜像仓，所以平时用不到；留这个开关是为了能切回官方仓：
#   HF_TOKEN=hf_xxx bash fetch_models.sh --tier flux3k
HF_AUTH=()
[ -n "${HF_TOKEN:-}" ] && HF_AUTH=(-H "Authorization: Bearer $HF_TOKEN")

# dl <repo> <remote-path> <subdir> [output-name]
dl() {
  local repo=$1 path=$2 sub=$3 want=${4:-}
  local fn; fn=$(basename "${want:-$path}")
  local out="$MODELS/$sub/$fn"
  if [ -s "$out" ]; then
    ok "$sub/$fn  ($(du -h "$out" | cut -f1))"
    return 0
  fi
  mkdir -p "$MODELS/$sub"
  printf '   ↓ %-52s ' "$fn"
  if curl -L --fail --retry 5 --retry-delay 3 --connect-timeout 30 -C - "${HF_AUTH[@]}" \
        -o "$out" "$HF_MIRROR/$repo/resolve/main/$path" 2>/dev/null; then
    printf '%s\n' "$(du -h "$out" | cut -f1)"
  else
    printf 'FAILED\n'; err "  $repo/$path"; FAILED+=("$repo/$path"); rm -f "$out"
  fi
}

# dlp <repo> <remote-path> <subdir>
# 与 dl 的区别：保留远程相对路径（用于 speech_tokenizer/ 这类嵌套目录）
dlp() {
  local repo=$1 path=$2 sub=$3
  local out="$MODELS/$sub/$path"
  if [ -s "$out" ]; then
    ok "$sub/$path  ($(du -h "$out" | cut -f1))"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  printf '   ↓ %-52s ' "$path"
  if curl -L --fail --retry 5 --retry-delay 3 --connect-timeout 30 -C - "${HF_AUTH[@]}" \
        -o "$out" "$HF_MIRROR/$repo/resolve/main/$path" 2>/dev/null; then
    printf '%s\n' "$(du -h "$out" | cut -f1)"
  else
    printf 'FAILED\n'; err "  $repo/$path"; FAILED+=("$repo/$path"); rm -f "$out"
  fi
}

# --- 图像：Z-Image-Turbo（6B / Apache-2.0 / 8 步 / 941 Elo） -------------------
# 4090 48G 最优档：nvfp4 4.2 + fp4 text encoder 3.24 + vae 0.31 = 7.75 GB
tier_img() {
  say "Z-Image-Turbo（Apache-2.0，8 步出图）"
  dl Comfy-Org/z_image_turbo split_files/diffusion_models/z_image_turbo_nvfp4.safetensors diffusion_models
  dl Comfy-Org/z_image_turbo split_files/text_encoders/qwen_3_4b_fp4_mixed.safetensors text_encoders
  dl Comfy-Org/z_image_turbo split_files/vae/ae.safetensors vae
  dl Comfy-Org/z_image_turbo split_files/loras/z_image_turbo_distill_patch_lora_bf16.safetensors loras

  say "Qwen3-TTS-1.7B 三件套（apache-2.0 / 10 语言含日语 / 97ms 首包）"
  # 三个 repo 同构（config + model.safetensors + speech_tokenizer/），用 dlp 保留嵌套路径，
  # 否则 from_pretrained 找不到 speech_tokenizer。落盘布局即 qwen3_tts_server.py 的 KIND_DIR。
  local _tts_files="config.json generation_config.json merges.txt model.safetensors
preprocessor_config.json tokenizer_config.json vocab.json
speech_tokenizer/config.json speech_tokenizer/configuration.json
speech_tokenizer/model.safetensors speech_tokenizer/preprocessor_config.json"
  for kind in CustomVoice VoiceDesign Base; do
    if [ "$kind" = "CustomVoice" ]; then say "  └ CustomVoice（预设角色音色 + instruct 情绪控制）"; fi
    if [ "$kind" = "VoiceDesign"  ]; then say "  └ VoiceDesign（文字描述造音色）"; fi
    if [ "$kind" = "Base"         ]; then say "  └ Base（零样本克隆 —— 因幡巡走这条）"; fi
    for f in $_tts_files; do
      dlp "Qwen/Qwen3-TTS-12Hz-1.7B-$kind" "$f" "tts/qwen3-tts/$kind"
    done
  done

  say "faster-whisper large-v3（字幕 / 歌词对齐 / 语料切分）"
  dl Systran/faster-whisper-large-v3 model.bin tts/faster-whisper-large-v3
  for f in config.json tokenizer.json vocabulary.txt preprocessor_config.json; do
    curl -sL --max-time 30 -o "$MODELS/tts/faster-whisper-large-v3/$f" "$HF_MIRROR/Systran/faster-whisper-large-v3/resolve/main/$f" 2>/dev/null || true
  done

  say "因幡巡 声库（详据 docs/voice-inaba-meguru.md）"
  # ① SanobaWitch 单作 6 人，speakers {"宁宁":0,"因幡巡":1} ⇒ sid=1（主力，apache-2.0）
  dl Redmonm/SanobaWitch model.pth voice/sanobawitch
  dl Redmonm/SanobaWitch config.json voice/sanobawitch
  # ② ACGTTS 19 人日语底模（CC-BY-NC-SA-4.0），README 映射 2 = 因幡巡 new。
  #    该仓库只有 .pth，没有 config.json（配置内嵌在权重里），别去拉不存在的文件。
  dl chinoll/ACGTTS new/acg_base/jp_1196000.pth voice/acgtts
  # ③ skytnt/moe-tts 曾是 454MiB 的备选，但 2026-10-22 实测仓库已空（files=0，
  #    saved_model/0/model.pth 直接 404），整段移除，免得多刷一次失败。
}

# --- 图像 HQ：Qwen-Image-2.1（7B / 编辑 / RGBA / ≤10 参考图） -----------------
# 注意 license：Qwen Research License（非商用），见 docs/stack-4090-48g.md §3
# 2026-10-22 修正：官方仓的 VAE 叫 vae/diffusion_pytorch_model.safetensors 只存在于
# 老版本；现仓为 safetensors 分片命名。unsloth 的 FP8 仓带的 0.676 GB bf16 VAE
# 是唯一与实际文件名对得上的（实测 tree 2026-10-22）。FP8 档在 Ada 上原生可用。
tier_hq() {
  say "Qwen-Image-2.1 FP8（7.12 DiT + 9.40 TE + 0.68 VAE = 17.2 GB）"
  dl unsloth/Qwen-Image-2.1-FP8 Qwen-Image-2.1-FP8.safetensors diffusion_models
  dl unsloth/Qwen-Image-2.1-FP8 Qwen-Image-2.1-text_encoder-FP8.safetensors text_encoders
  dl unsloth/Qwen-Image-2.1-FP8 vae/qwen_image_2.1_vae_bf16.safetensors vae qwen_image_2.1_vae.safetensors
}

# --- FLUX 3 Image klein（BFL 2026-10-15 / 5.6B / 10 参考图 / 社区许可） -------
# BFL 官方出的 **ComfyUI 打包版**（目录名就是 comfy），权重命名直接对应
# ComfyUI 的 diffusion_models / text_encoders / vae 三目录，无需改名。
# 体积（实测）：int8 5.83 + qwen3vl_4b int8 4.86 + vae 0.34 = 11.02 GB
#               bf16 11.10 + 8.88 + 0.34 = 20.31 GB
# prompt upsampler（可选，9B，让短提示词变长分镜描述）：int8 9.75 / w4a8 6.72
# license: FLUX 3 Kommunity License —— 年营收 < $5M 可免费商用，超过需向 BFL 买。
#
# 仓库选择：官方 black-forest-labs/flux-3-image-klein-comfy 是 gated=auto（匿名 403），
# 必须登录 + 网页点同意才能下。这里默认走 ml-resources 的镜像仓 —— 36 个文件、
# 文件名、字节数逐项一致，gated=False，实名测 206。想切回官方仓就设
# FLUX3_REPO=black-forest-labs/flux-3-image-klein-comfy 并传 HF_TOKEN。
FLUX3_REPO="${FLUX3_REPO:-ml-resources/flux-3-image-klein-comfy}"
tier_flux3k() {
  FLUX3_DIT="${FLUX3_DIT:-flux3-image-klein-int8-convrot.safetensors}"
  FLUX3_TE="${FLUX3_TE:-qwen3vl_4b_int8_convrot.safetensors}"
  say "FLUX 3 klein（DiT=$FLUX3_DIT / TE=$FLUX3_TE / repo=$FLUX3_REPO）"
  dl "$FLUX3_REPO" "diffusion_models/$FLUX3_DIT" diffusion_models
  dl "$FLUX3_REPO" "text_encoders/$FLUX3_TE" text_encoders
  dl "$FLUX3_REPO" vae/flux2-vae.safetensors vae
  if [ "${FLUX3_UPSAMPLER:-0}" = "1" ]; then
    say "（可选）prompt upsampler 9B int8 9.75 GB —— 短提示词自动扩写"
    dl "$FLUX3_REPO" \
       text_encoders/qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors text_encoders
  fi
}

# --- MOSS-Image：Apache-2.0 的图像主力（2026-10 发布，ComfyUI 官方打包） -------
# 为什么把它排在 Qwen-Image-2.1 / FLUX 3 klein 前面：
#   ① 它是三者里**唯一真开源**的 —— Apache-2.0，商用零门槛；
#      Qwen-Image-2.1 是 Qwen Research License（非商用），FLUX 3 klein 是社区许可（年营收 >$5M 要买）
#   ② **JSON layout prompt**（bbox_format=yxyx / abs_centralized）—— 可以指定「谁在哪、
#      占多大」，正好对上《钢板与黑麦》的分镜排版需求，这是另外两个没有的
#   ③ ComfyUI 有官方打包仓（Comfy-Org/MOSS-Image，下载量 129 万）和原生插件
# 体积（实测）：SFT int8 5.41 + qwen3.5_9b int8 9.75 + vae 0.34 = 15.50 GB
#               TE 换 w4a8 则 5.41 + 7.34 + 0.34 = 13.09 GB
#               SFT bf16 10.17 + TE bf16 19.31 + vae 0.34 = 29.82 GB
# 采样：50 步 / CFG 3 / shift 5 / Flow-match Euler / uncond_skip_layers=[22]
# 变体：sft（指令微调，文字组块更整齐，做分镜用这个）/ base（底模，配 LoRA 用）
# 注意：AA 榜**尚未收录** MOSS-Image，所以它没有 Elo 分数可对照，别拿"榜上没它"当理由。
MOSS_DIT="${MOSS_DIT:-moss_image_sft_int8_convrot.safetensors}"
MOSS_TE="${MOSS_TE:-qwen3.5_9b_int8_convrot.safetensors}"
tier_moss() {
  say "MOSS-Image（Apache-2.0 / DiT=$MOSS_DIT / TE=$MOSS_TE）"
  dl Comfy-Org/MOSS-Image "diffusion_models/$MOSS_DIT" diffusion_models
  # base 底模也一起拉：LoRA 训练与色彩/深度控制都基于它，5.41 GB 不算贵
  dl Comfy-Org/MOSS-Image diffusion_models/moss_image_base_int8_convrot.safetensors diffusion_models
  dl Comfy-Org/MOSS-Image "text_encoders/$MOSS_TE" text_encoders
  # MOSS 自带小号 VAE 解码器，与 FLUX.2 的 flux2-vae 同源，文件名一致可直接复用
  dl Comfy-Org/MOSS-Image vae/flux2-vae.safetensors vae
  dl Comfy-Org/MOSS-Image vae/flux2-vae_small.safetensors vae
  say "（可选）色彩/景深控制 LoRA 0.31 GB"
  dl Comfy-Org/MOSS-Image loras/moss_image_color_depth_control.safetensors loras
}

# --- VoxCPM2：因幡巡日语配音主力（2B / 48kHz / 零样本克隆） -------------------
# 2026-10-22 换将：日语 SIM 0.825（Ming 0.765），CER 4.358（Ming 3.765，稍差）；
# 但采样率 48kHz 对 44.1kHz，且支持 prompt_wav 续写式克隆（保韵律细节）。
# license: Apache-2.0（README 标注），2B 参数，RTF ~0.3 on 4090。
# 注意 HF 仓名是**全小写** openbmb/VoxCPM2。
tier_vox() {
  say "VoxCPM2（2B，48kHz，4.96 GB）"
  dl openbmb/VoxCPM2 model.safetensors voxcpm2
  dl openbmb/VoxCPM2 audiovae.pth voxcpm2
  dl openbmb/VoxCPM2 config.json voxcpm2
  dl openbmb/VoxCPM2 tokenizer.json voxcpm2
  dl openbmb/VoxCPM2 tokenizer_config.json voxcpm2
  dl openbmb/VoxCPM2 special_tokens_map.json voxcpm2
  dl openbmb/VoxCPM2 tokenization_voxcpm2.py voxcpm2
}

# --- IndexTTS-2.5：中文情感控制（bilibili / 5.49 GB） ------------------------
# 2026-08-13 发布，v2.5.0 tag。旧文档写的「0.3.0 镜像」在仓库里查无此 tag。
# license: bilibili-model-license（非商用需看条款），gated=False 可直接下。
tier_index25() {
  say "IndexTTS-2.5（gpt 3.26 + qwen0.6bemo 1.19 + codec 0.61 + s2mel 0.41）"
  dl  IndexTeam/IndexTTS-2.5 gpt.pth   indextts25
  dl  IndexTeam/IndexTTS-2.5 codec.pth indextts25
  dl  IndexTeam/IndexTTS-2.5 s2mel.pth indextts25
  # 情感特征 + 统计量：缺了 emo 模式跑不起来
  dl  IndexTeam/IndexTTS-2.5 feat1.pt indextts25
  dl  IndexTeam/IndexTTS-2.5 feat2.pt indextts25
  dl  IndexTeam/IndexTTS-2.5 wav2vec2bert_stats.pt indextts25
  dl  IndexTeam/IndexTTS-2.5 config.yaml indextts25
  dl  IndexTeam/IndexTTS-2.5 multilingual_zh_ja_yue_char_del.tiktoken indextts25
  # 文本/情感编码器子目录：12 个文件全部要（tokenizer 缺一个 from_pretrained 就报错）
  local _emo="model.safetensors tokenizer.json vocab.json merges.txt
tokenizer_config.json config.json added_tokens.json special_tokens_map.json
chat_template.jinja generation_config.json Modelfile"
  local f
  for f in $_emo; do
    dlp IndexTeam/IndexTTS-2.5 "qwen0.6bemo4-merge/$f" indextts25
  done
}

# --- MiniMax-H3：音视频同期声主力 ---------------------------------------------
# 推荐组合（4090 48G，2026-10-22 实测字节）：
#   pruned_int8 20.97 + nvfp4 TE 15.69 + vae_int8 2.81 + audio_vae 0.61
#   + turbo8step 1.96 = 42.04 GB 全常驻
# TE 走 CPU offload 时降到 ~26 GB（平台预制镜像报的 27.8 GiB 就是这个口径）。
tier_h3() {
  say "MiniMax-H3 — 选择检查点精度档"
  # 默认 pruned_int8_convrot（官方模板默认）；显存紧时改 pruned_w6a8（15.98）
  H3_DIT="${H3_DIT:-minimax_h3_fl2va_pruned_int8_convrot.safetensors}"
  H3_TE="${H3_TE:-qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors}"
  dl Comfy-Org/MiniMax-H3 "diffusion_models/$H3_DIT" diffusion_models
  # Ref2VA（多模态参考：≤9 图 / ≤3 视频 / ≤3 音频）—— 做角色一致性必需
  dl Comfy-Org/MiniMax-H3 "diffusion_models/${H3_DIT/fl2va/ref2va}" diffusion_models
  dl Comfy-Org/MiniMax-H3 "text_encoders/$H3_TE" text_encoders
  dl Comfy-Org/MiniMax-H3 vae/minimax_h3_video_vae_int8_convrot.safetensors vae
  dl Comfy-Org/MiniMax-H3 vae/minimax_h3_audio_vae_fp32.safetensors vae
  dl Comfy-Org/MiniMax-H3 loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors loras
  dl Comfy-Org/MiniMax-H3 loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors loras
  say "H3 Fun ControlNet Union（Canny/Depth/HED/Pose 驱动 + 视频 inpaint）"
  dl Comfy-Org/MiniMax-H3 model_patches/minimax_h3_fun_controlnet_union_2.0_pruned_int8_convrot.safetensors model_patches
}

# --- LTX-2.5：多镜头叙事 ------------------------------------------------------
# 官方 Lightricks/LTX-2.5 是 gated=auto（匿名 403）。这里默认走 comfyicu 镜像仓 ——
# 17 个文件、文件名与字节数逐项一致，gated=False，实测 206。
# 想切回官方仓：LTX_REPO=Lightricks/LTX-2.5 并传 HF_TOKEN。
LTX_REPO="${LTX_REPO:-comfyicu/LTX-2.5}"
tier_ltx() {
  say "LTX-2.5 int8（原生 multi-shot，22B / repo=$LTX_REPO）"
  dl "$LTX_REPO" diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors diffusion_models
  dl "$LTX_REPO" text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors text_encoders
  dl "$LTX_REPO" vae/ltx-2.5-video-vae-bf16.safetensors vae
  dl "$LTX_REPO" vae/ltx-2.5-audio-vae-bf16.safetensors vae
  dl "$LTX_REPO" latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors latent_upscale_models
  dl "$LTX_REPO" latent_upscale_models/ltx-2.5-latent-temporal-upscaler-x2-bf16-1.0.safetensors latent_upscale_models
  say "（可选）distilled LoRA 450 —— 8.90 GB，先不拉可省盘"
  # dl "$LTX_REPO" loras/ltx-2.5-22b-distilled-lora-450-bf16.safetensors loras
}

# --- Wan2.2：便宜草稿 + 口型对轨 ----------------------------------------------
tier_wan() {
  say "Wan2.2 Ti2V-5B（草稿 / 批量试镜）"
  dl Comfy-Org/Wan_2.2_ComfyUI_Repackaged split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors diffusion_models
  dl Comfy-Org/Wan_2.2_ComfyUI_Repackaged split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors text_encoders
  dl Comfy-Org/Wan_2.2_ComfyUI_Repackaged split_files/vae/wan2.2_vae.safetensors vae
  say "Wan2.2 S2V-14B fp8（语音驱动口型对轨）"
  dl Comfy-Org/Wan_2.2_ComfyUI_Repackaged split_files/diffusion_models/wan2.2_s2v_14B_fp8_scaled.safetensors diffusion_models
  dl Comfy-Org/Wan_2.2_ComfyUI_Repackaged split_files/audio_encoders/wav2vec2_large_english_fp16.safetensors audio_encoders
  say "LightX2V 4 步蒸馏 LoRA（把 20 步压到 4 步）"
  dl Comfy-Org/Wan_2.2_ComfyUI_Repackaged split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors loras
  dl Comfy-Org/Wan_2.2_ComfyUI_Repackaged split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors loras
}

# --- Ming-3.0-tts：AA 克隆榜开源第一，中文 + 日语，44.1 kHz，MIT ---------------
# 0.5B 稠密（Qwen2.5-0.5B 骨干 + DiT 头），campplus.onnx 是说话人编码器，缺了没法克隆。
tier_tts() {
  say "Ming-3.0-tts-0.5B（10 个文件，约 1.1 GB）"
  for f in model.safetensors config.json configuration.json \
           tokenizer.json tokenizer_config.json special_tokens_map.json \
           vocab.json merges.txt added_tokens.json campplus.onnx; do
    dlp inclusionAI/Ming-3.0-tts-0.5B "$f" tts/ming-3.0-tts
  done
}

# --- GPT-SoVITS：角色扮演克隆的事实标准（v5，2.0 GB） -------------------------
# 为什么单列它：二次元角色语音这条路上，SoVITS 生态是绝对的 —— HF 上 `search=sovits`
# 有 537 个模型，而且**只有它的模型命名是「角色名」形态**（minato-aqua-sovits /
# Miku-Nakano / Nangong-Nayun…）；f5-tts 的 353 个、chatterbox 的 326 个绝大多数是
# 「语种 finetune」（russian / persian / hun），不是角色。GitHub 上 472 个周边仓库。
# 但**因幡巡没有现成的 SoVITS 模型**（2026-10-22 搜 inaba / meguru / sanoba 均无），
# 所以要用它就得自己微调：3~5 分钟干净音频 → 4090 上训练 5~10 分钟。
#
# 版本真相（易错点）：GitHub 最新 **tag** 是 20250606v2pro，但那只是没给 v5 打 tag，
# main 分支**已经是 V5**（webui.py:1499 的版本下拉含 v5dev/v5turbo，
# inference_webui.py:104 已 import module.models_v5）。v5 = 换 SoVITS 声学模型
# （dev 32 步 / turbo 4 步）+ 新 vocoder，**GPT(s1) 部分没换代，仍是 s1v3.ckpt**。
# 四个版本共用 s1v3，所以这里把 v5turbo / v5dev / v2ProPlus 的 s2G 全下了（2.0 GB），
# 想快就 turbo，想出精品就 dev，想快训就 v2ProPlus。
#
# 权重来源：**两个仓分工**（2026-10-22 实测，别搞混）
#   ① lj1995/GPT-SoVITS —— 权重本身（s1v3 / gsv-v5-pretrained / v2Pro / hubert / roberta / sv）
#      路径**没有** pretrained_models/ 前缀，下到 $MODELS/gpt_sovits/pretrained_models/ 下
#   ② XXXXRT/GPT-SoVITS-Pretrained —— 只有工具附件（open_jtalk 词典、uvr5、G2PW、asr 打包）
#      ⚠️ 这个仓**没有** v5 权重（探 v5turbo 直接 404），别去那儿找
# 注意：v1/v2 的 s1 与 v3/v4/v5 不通用，别混着下。
tier_gsv() {
  local R=lj1995/GPT-SoVITS
  local T=XXXXRT/GPT-SoVITS-Pretrained
  local P=gpt_sovits
  say "GPT-SoVITS V5（s1v3 + s2Gv5turbo/dev + s2Gv2ProPlus，约 2.0 GB）"
  # 共用件：GPT 部分、文本前端、特征提取
  dlp "$R" s1v3.ckpt "$P/pretrained_models"
  dlp "$R" chinese-hubert-base/pytorch_model.bin "$P/pretrained_models"
  dlp "$R" chinese-hubert-base/config.json "$P/pretrained_models"
  dlp "$R" chinese-hubert-base/preprocessor_config.json "$P/pretrained_models"
  dlp "$R" chinese-roberta-wwm-ext-large/pytorch_model.bin "$P/pretrained_models"
  dlp "$R" chinese-roberta-wwm-ext-large/config.json "$P/pretrained_models"
  dlp "$R" chinese-roberta-wwm-ext-large/tokenizer.json "$P/pretrained_models"
  say "v5 声学模型：turbo（4 步，日常）/ dev（32 步，终稿）"
  dlp "$R" gsv-v5-pretrained/s2Gv5turbo.pth "$P/pretrained_models"
  dlp "$R" gsv-v5-pretrained/s2Gv5dev.pth "$P/pretrained_models"
  dlp "$R" gsv-v5-pretrained/vocoder.pth "$P/pretrained_models"
  say "v2ProPlus（200 MB，微调最快，急着出片用这档）"
  dlp "$R" v2Pro/s2Gv2ProPlus.pth "$P/pretrained_models"
  dlp "$R" v2Pro/s2Dv2ProPlus.pth "$P/pretrained_models"
  say "微调辅助：说话人验证 sv"
  dlp "$R" sv/pretrained_eres2netv2w24s4ep4.ckpt "$P/pretrained_models"

  # 日语的文本前端靠 pyopenjtalk（setup_env.sh 已 pip install）+ 这份词典
  local D="$MODELS/$P/open_jtalk_dic_utf_8-1.11"
  if [ -d "$D" ]; then
    ok "open_jtalk_dic_utf_8-1.11/"
  else
    printf '   ↓ %-52s ' "open_jtalk_dic_utf_8-1.11.tar.gz"
    if curl -L --fail --retry 3 --connect-timeout 30 "${HF_AUTH[@]}" \
          -o "$MODELS/$P/jtalk.tgz" \
          "$HF_MIRROR/$T/resolve/main/open_jtalk_dic_utf_8-1.11.tar.gz" 2>/dev/null \
       && tar -xzf "$MODELS/$P/jtalk.tgz" -C "$MODELS/$P" \
       && rm -f "$MODELS/$P/jtalk.tgz"; then
      printf '%s\n' "ok"
    else
      printf 'FAILED\n'; err "  $T/open_jtalk_dic_utf_8-1.11.tar.gz"
      FAILED+=("$T/open_jtalk_dic_utf_8-1.11.tar.gz"); rm -f "$MODELS/$P/jtalk.tgz"
    fi
  fi

  # UVR5 人声分离：从游戏原声里扒因幡巡时必须先去掉 BGM 和音效。
  # 这是「素材从哪来」这条链上唯一的机器活，别省。
  if [ "${GSV_UVR5:-1}" = "1" ]; then
    local U="$MODELS/$P/uvr5_weights"
    if [ -d "$U" ]; then
      ok "uvr5_weights/"
    else
      say "UVR5 人声分离权重（523 MB）"
      printf '   ↓ %-52s ' "uvr5_weights.zip"
      if curl -L --fail --retry 3 --connect-timeout 30 "${HF_AUTH[@]}" \
            -o "$MODELS/$P/uvr5.zip" "$HF_MIRROR/$T/resolve/main/uvr5_weights.zip" 2>/dev/null \
         && (cd "$MODELS/$P" && unzip -q -o uvr5.zip) \
         && rm -f "$MODELS/$P/uvr5.zip"; then
        printf '%s\n' "ok"
      else
        printf 'FAILED\n'; err "  $T/uvr5_weights.zip"
        FAILED+=("$T/uvr5_weights.zip"); rm -f "$MODELS/$P/uvr5.zip"
      fi
    fi
  fi
}

# --- Fish Audio S2 Pro：日语吐字最准的零样本克隆（11 GB，匿名可下） ------------
# 定位：**不想训练、又要日语吐字准**时用它。
# 日语 CER 2.76 是所有候选里最好的（VoxCPM2 4.358 / Ming 3.765 / dots.tts 7.16），
# 83 语种含日语，10~30 秒参考音零样本。license 是 Fish Audio Research License ——
# **个人非商用完全够用**，只有拿去卖 API 或商用发布才需要单独授权。
#
# 为什么不是 OpenAudio S1 Mini（AA 日语 OW 第一 1083）：
#   S1 Mini 是 `gated=auto`，匿名 403，得先登录 HF 在网页点同意再配 token；
#   S2 Pro 是 `gated=False`，匿名直接 206。而且 S2 Pro 是 S1 Mini 的加大版（11 GB vs 3.6 GB）。
#   真要 S1 Mini 就设 FISH_REPO=fishaudio/s1-mini 并传 HF_TOKEN。
#
# 跑法：不进 ComfyUI，走 fish-speech（GitHub 33k stars，2026-10-14 还在推）：
#   git clone https://github.com/fishaudio/fish-speech && pip install -e .
# 体积：model 4.99 + 4.14 + codec 1.87 = 11.00 GB
FISH_REPO="${FISH_REPO:-fishaudio/s2-pro}"
tier_fish() {
  say "Fish Audio S2 Pro（11 GB / 83 语含日语 / 零样本克隆 / repo=$FISH_REPO）"
  if [ "$FISH_REPO" = "fishaudio/s2-pro" ]; then
    dlp "$FISH_REPO" model-00001-of-00002.safetensors tts/fish-s2-pro
    dlp "$FISH_REPO" model-00002-of-00002.safetensors tts/fish-s2-pro
    dlp "$FISH_REPO" model.safetensors.index.json tts/fish-s2-pro
    dlp "$FISH_REPO" chat_template.jinja tts/fish-s2-pro
  else
    dlp "$FISH_REPO" model.pth tts/fish-s2-pro
  fi
  dlp "$FISH_REPO" codec.pth tts/fish-s2-pro
  dlp "$FISH_REPO" tokenizer.json tts/fish-s2-pro
  dlp "$FISH_REPO" tokenizer_config.json tts/fish-s2-pro
  dlp "$FISH_REPO" special_tokens_map.json tts/fish-s2-pro
  dlp "$FISH_REPO" config.json tts/fish-s2-pro
}

# --- Fish Audio Drama 3：35B-A3B 的巨无霸（int4 24 GB / bf16 41.5 GB）--------
# 定位：**要"最像人"的表演感**时用它。35B 总参 / A3B 激活，83 语含日语，
# 带 audio tag 控制（`samples/int4_tags.wav` 就是它的标签演示）。
#
# 48G 显存只装 int4：24.03 GB（12 片 × 2 GB）。bf16 41.50 GB（8 片 × 5 GB）跑不动。
# int4 仓里有大量 eval/ 和 samples/ 的 wav 样例（几十个文件），**只下模型分片和配置**，
# 样例音频不要——所以这里是逐文件枚举，不能用整个仓拉。
# 想换 bf16：`DRAMA_REPO=fishaudio/drama-3 bash fetch_models.sh --tier drama`（需要 48G 以上）
DRAMA_REPO="${DRAMA_REPO:-fishaudio/drama-3-int4}"
tier_drama() {
  say "Fish Audio Drama 3（$DRAMA_REPO / 35B-A3B / 83 语含日语）"
  dlp "$DRAMA_REPO" model.safetensors.index.json tts/drama3
  dlp "$DRAMA_REPO" codec.pth tts/drama3
  dlp "$DRAMA_REPO" tokenizer.json tts/drama3
  dlp "$DRAMA_REPO" tokenizer_config.json tts/drama3
  dlp "$DRAMA_REPO" special_tokens_map.json tts/drama3
  dlp "$DRAMA_REPO" config.json tts/drama3
  dlp "$DRAMA_REPO" chat_template.jinja tts/drama3
  case "$DRAMA_REPO" in
    *-int4)
      say "int4 分片（12 × 2 GB）"
      local i
      for i in $(seq 1 12); do
        dlp "$DRAMA_REPO" "model-$(printf %05d "$i")-of-00012.safetensors" tts/drama3
      done
      ;;
    *)
      say "bf16 分片（8 × 5 GB，48G 装不下，只作留档）"
      local i
      for i in $(seq 1 8); do
        dlp "$DRAMA_REPO" "model-$(printf %05d "$i")-of-00008.safetensors" tts/drama3
      done
      ;;
  esac
}

# --- 因幡巡现成声库（2022 年代 VITS，零训练直接出声）--------------------------
# 三份权重都已核实可下（HTTP 200 + Content-Length 对得上），sid 映射写在 docs/voice-inaba-meguru.md。
# 注意：这些是 22 kHz VITS，音质不如 Ming 克隆；价值在「不需要任何参考音频」。
tier_vits() {
  say "因幡巡 VITS 声库（MoeGoe 直读，零训练）"
  # 首选：魔女的夜宴六人合一，config.json 是 MoeGoe 的 zh_ja_mixture_cleaners，因幡巡 = sid 1
  dl Redmonm/SanobaWitch model.pth vits/sanoba
  dl Redmonm/SanobaWitch config.json vits/sanoba
  # 备选：ACGTTS 19 人日语底模，因幡巡 = sid 2；仓库内无 config.json，用 MoeGoe/configs 里的对应文件
  dl chinoll/ACGTTS new/acg_base/jp_1196000.pth vits/acgtts
  # 原 MoeTTS（skytnt/moe-tts）2026-10-22 实测仓库已空，不再下载
}

case "$TIER" in
  img)  tier_img ;;
  hq)   tier_hq ;;
  h3)   tier_h3 ;;
  ltx)  tier_ltx ;;
  wan)  tier_wan ;;
  tts)  tier_tts ;;
  vits) tier_vits ;;
  flux3k)  tier_flux3k ;;
  moss)    tier_moss ;;
  vox)     tier_vox ;;
  index25) tier_index25 ;;
  gsv)     tier_gsv ;;
  fish)    tier_fish ;;
  drama)   tier_drama ;;
  # 三个「新一代」快捷组合：按你要做的活选一组，不用下全套
  image)   tier_hq; tier_flux3k; tier_moss ;;
  video)   tier_h3; tier_ltx; tier_wan ;;
  voice)   tier_vox; tier_tts; tier_index25; tier_gsv; tier_fish; tier_drama; tier_vits ;;
  all)
    tier_img; tier_hq; tier_h3; tier_ltx; tier_wan; tier_tts; tier_vits
    tier_flux3k; tier_moss; tier_vox; tier_index25; tier_gsv; tier_fish; tier_drama
    ;;
  *) echo "未知 tier: $TIER（img|hq|h3|ltx|wan|tts|vits|flux3k|moss|vox|index25|gsv|fish|drama|image|video|voice|all）" >&2; exit 2 ;;
esac

say "完成"
echo "  落盘目录：$MODELS"
du -sh "$MODELS"/* 2>/dev/null | sort -h | sed 's/^/    /'
if [ ${#FAILED[@]} -gt 0 ]; then
  echo
  warn "以下 ${#FAILED[@]} 项失败，重跑本脚本即可续传："
  printf '    %s\n' "${FAILED[@]}"
  exit 1
fi
