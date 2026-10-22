# 共绩预制镜像清单与选用结论

> 结论先行：**用户要的「图像 AI + 声音 AI + 视频 AI」平台已经全有官方预制镜像，不需要我们自己 build。**
> 之前一直卡在「本机无 Docker、镜像仓库 0 B」上，是因为没读官方文档。这份文档是把文档读完之后的正解。

来源：`https://suanli.cn/docs/flexible-deployment/pre-fabricated-services/`（2026-10-22 实抓）

---

## 1. 弹性部署的两种发布方式（官方原文）

`/docs/flexible-deployment/product-billing/bv4gwriuoiec82kpkjccdbc0nie/` 明确写平台支持两种方式：

**方式一：使用平台预制镜像（推荐，新手最快）**
- 服务配置 → 「预制服务」选项卡 → 搜索镜像 → 选中 → 页面底部【部署服务】

**方式二：使用用户自定义镜像**
- 服务配置 → 「自定义服务」→ 填镜像 URL + 端口
- 平台支持两种镜像来源：
  - **第三方公共镜像仓库**：Docker Hub、阿里云镜像仓库等
  - **平台私有镜像仓库**：`harbor.suanleme.cn/<项目>/<镜像>:<tag>`

⇒ 我之前判断「必须先把镜像推进共绩 Harbor」是错的。**公网镜像可以直接填 URL。**

---

## 2. 预制服务全清单（40 项，官方侧栏原文）

### 图像 / 视觉
| 服务 | 说明 |
|---|---|
| **Z Image Turbo** | 秒级出图，4090 单卡最划算 |
| Z Image | 非 turbo 版，质量更高更慢 |
| **Qwen Image** | 开源图生图 Elo 最高档（1042） |
| Qwen-Image-Edit | 指令编辑 |
| Qwen-Image-Layered | 分层出图 |
| Flux.1-dev / Flux.1 Krea[dev] / **Flux.2 [dev]** | BFL 系 |
| Flux.1 Kontext Dev | 图片编辑 |
| LongCat-Image | 美团系 |
| PaddleOCR-VL-0.9B / minerU / PDFMathTranslate | 文档 OCR / 解析 |
| HivisionIDPhotos | 证件照 |
| CodeFormer | 人脸修复 |
| FaceFusion / ComfyUI-ReActor | 换脸 |
| HunyuanPortrait | 人像驱动 |

### 视频
| 服务 | 说明 |
|---|---|
| **MiniMax-H3** | 33.1B omni transformer + Qwen3-VL-32B 文本编码器，最长 15s / 24fps / 2K / 原生 32kHz 立体声 |
| **minimax-h3 turbo + RTX VSR 合并镜像** | H3 生成 + 2K 超分一体机 |
| WAN2.2 5B | 阿里系轻量 |
| FramePack-F1 | 长视频图生视频 |
| FlashVSR / RTX VSR | 视频超分（可单独部署在便宜机器） |
| HunyuanWorld-Mirror Demo | 3D/世界模型 |

### 声音
| 服务 | 端口 | 说明 |
|---|---|---|
| **IndexTTS2** | **7860** | bilibili 自回归 TTS，**参考音频克隆 + 自然语言提示 + 情绪向量** |
| **CosyVoice** | **7865** | 阿里系，零样本克隆，有 Web UI 与 API |
| ACE-Step / acestep1.5-5Hz-lm-1.7B | — | 音乐生成 |
| Whisper / FunASR / Qwen3 ASR | — | 语音识别（做字幕用） |

### 通用
Ollama+Qwen3 / Ollama+Qwen3+Open WebUI / vLLM / JupyterLab / GPT-OSS-20B / Qwen3.6-27B / Qwen3-8B-VL / minicpm4 / DailyHot

---

## 3. 关键镜像的精确参数（从文档正文抄下来的，不是猜的）

### 3.1 MiniMax-H3
文档页：`/docs/flexible-deployment/pre-fabricated-services/aibiwd1cqivpm1klc94cswninec/`

- **端口**：`8188`（ComfyUI WebUI）、`3000`（API）、`8001`（VSR，合并镜像才有）
- **推荐机型**：文档写「推荐选用内存较大的 5090 机器」；实测 4090 24G 的量化版 demo 能跑
- **镜像缓存命中时 1~2 分钟启动**

**官方六个工作流（精确文件名，ComfyUI 里直接选）**：
| 文件 | 用途 |
|---|---|
| `video_minimax_h3_t2v.json` | 文生视频，res_multistep 20 步，画质最高最慢 |
| `video_minimax_h3_t2v_turbo4step_zh.json` | 同功能 + 4 步蒸馏 LoRA，**快约 5 倍，日常推荐** |
| `video_minimax_h3_i2v.json` | 图生视频（首帧接 `first_frame`，尾帧接 `last_frame`） |
| `video_minimax_h3_i2v_turbo4step_zh.json` | 同上 turbo 版 |
| `video_minimax_h3_r2v.json` | 参考生视频：≤9 张参考图 + ≤3 段参考视频 + ≤3 段音频，用 `<Picture 1>` `<Video 1>` `<Audio 1>` 引用 |
| `video_minimax_h3_r2v_turbo4step_zh.json` | 同上 + ref2v 专用 4 步 LoRA（v0.1，**不可与 fl2v 版混用**） |

**turbo 档铁律**：蒸馏 LoRA 按 4 步训练，**手动加步数只会更慢不会更好**。

**权重文件名（API 工作流里直接用）**：
```
minimax_h3_fl2va_pruned_int8_convrot.safetensors          # UNETLoader
qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors              # CLIPLoader, type="minimax"
minimax_h3_video_vae_fp16.safetensors                     # VAELoader
minimax_h3_audio_vae_fp32.safetensors                     # VAELoader
minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors   # LoraLoaderModelOnly
```
⇒ 与我们自建的 `workflows/h3_t2va.json` 比对：编码器文件名从旧的 `umt5` 换成 `qwen3vl_32b`，video vae 用 **fp16** 不是 int8，LoRA 文件名带 `768p`。**自建工作流要按这个改。**

### 3.2 IndexTTS2（因幡巡首选）

> **⚠️ 10-22 复核：这一节要改。** ①`0.3.0` 这个 tag 在 `index-tts/index-tts` 仓库里**不存在**（仓库只有 v1.5.0 / v2.0.0 / v2.5.0），该镜像版本存疑，疑似初代。②即便它是最新的 **IndexTTS-2.5**，输出也只有 **22.05 kHz**。③日语克隆正解已改为 **VoxCPM2**（48kHz / Apache-2.0 / 4.62GB / 日语 SIM 0.825）。详见 `model-selection-verified.md` 第 3 节与 `frontier-2026-10-22.md`。

文档页：`/docs/flexible-deployment/pre-fabricated-services/rdaaw9nuuizgnjk6gomct5m7nmf/`

- **镜像 URL：`harbor.suanleme.cn/laiaqwq/index-tts:0.3.0`**
- **端口：`7860`**
- **推荐机型：4090**
- 配置路径：服务配置 → 自定义服务 → 镜像 URL + 端口配置 7860
- 四种情绪控制：与参考音相同 / 情感参考音频 / 情感向量 / 文字描述控制
- Gradio 自带 API 可远程调用
- 单条生成 10 秒~2 分钟（随文本长度）

### 3.3 minimax-h3 turbo + RTX VSR 合并镜像
文档页：`/docs/flexible-deployment/pre-fabricated-services/hdvmwc8xnig1nck6pi5c6gjynye/`

- 一个镜像 = ComfyUI(8188) + VSR API(8001)，单张 **5090 32GB** 跑「768p 生成 → 2K 超分」
- 显存：ComfyUI(H3) 峰值 **~27.8 GiB**（int8 模型 ~20G + 文本编码器 nvfp4 ~15G 走 CPU offload），VSR 每任务 6~10.5 GiB
  ⇒ **24G 卡吃不下 both 模式**，要 32G 或 48G
- 启动参数 `run`：`both`(默认) / `comfyui`(纯生成) / `vsr`(纯超分) / `selftest`
- 超分调用：
  ```bash
  curl -X POST $VSR/api/v1/upscale/file -F "file=@h3_raw.mp4" \
    -F "scale=2.0" -F "quality=HIGH" -F "vcodec=libx264"
  ```
  **共绩节点 NVENC 不可用，必须 `vcodec=libx264`**
- 结果下载 `/api/v1/tasks/<id>/result` 返回的是 mp4 二进制流，不是 JSON

---

## 4. 本项目该怎么选（图 / 视频 / 声音三件套）

| 需求 | 选什么 | 机型 | 端口 | 备注 |
|---|---|---|---|---|
| 日常出图 | **Z Image Turbo** 预制 | 4090 24G | 8188 | 最便宜，秒级 |
| 高质量出图/改图 | **Qwen Image** 或 Qwen-Image-Edit 预制 | 4090 24G | 8188 | 开源最强档 |
| 视频（性价比） | **MiniMax-H3** 预制 + turbo4step 工作流 | 4090 24G | 8188/3000 | 先跑通再说 |
| 视频（要 2K） | **h3 turbo + VSR 合并镜像** | 5090 32G 或 4090 48G | 8188/8001 | both 模式显存 ~38G |
| 因幡巡配音 | **IndexTTS2** 自定义服务 | 4090 24G | 7860 | 上传参考音克隆 |
| 备用 TTS | **CosyVoice** 预制 | 4090 24G | 7865 | 零样本克隆 |
| 字幕/听写 | **Whisper / FunASR** 预制 | 便宜卡 | — | 做视频字幕 |

**顺序建议**：先开一台 4090 24G 跑 Z Image Turbo 验证出图 → 同一台换 H3 跑视频 → 再开 IndexTTS2 配音。
**不要同时开三台**（余额 4.01 元，三台 1.98 元/h 并行只够 40 分钟）。

---

## 5. 平台侧硬约束（官方 FAQ 原文）

`/docs/flexible-deployment/faq/hsxowl4y2i5eogkdsnvcuhv0nae/`

- **Serverless 无状态**：容器释放后，运行期产生的文件、手动装的依赖、命令改的配置**即刻永久丢失**
- **不提供 SSH，不提供持久化页面终端**；启动命令要写进镜像的 CMD/ENTRYPOINT，调试靠【服务日志】看 stdout
- 计费精确到秒，**镜像上传拉取过程不收费**，服务成功部署后才计费
- 单账号任务上限 **10 个节点**
- 弹性扩缩容：服务页左侧【设置】改节点数
- 拉镜像慢：看节点详情的事件记录
- HF 下载慢：配 `HF_ENDPOINT=https://hf-mirror.com`

⇒ **这和云主机是两套东西**：云主机有 SSH、有持久盘、能保存镜像；弹性部署无状态、无 SSH。
要做「装一堆模型长期用」的环境，云主机才对路——但云主机现在「正在优化升级，暂时无法新建」。
所以当前只能走弹性部署的预制镜像，这恰恰也是最省事的路。

---

## 6. 与自建镜像（`harbor.suanleme.cn` 那份）的关系

自建镜像的价值在于：
- 把 **因幡巡 VITS 权重 + Ming-3.0-tts + 我们的 4 个自造工作流** 打包固定下来
- 环境一次装好，以后每次开机不用等 pip

但当下：
- 本机无 Docker / Podman / Buildah / WSL，非管理员 ⇒ 本地 build 不可行
- `.github/workflows/build-image.yml` 已写好（GitHub Actions 云端 build 推 Harbor），需要用户先在 GitHub 仓库配 4 个 secret
- 镜像仓库按 0.25 元/GB/月计费，每月首登送 7.5 元券

⇒ **短期用预制镜像出活，自建镜像作为后续优化项**，不要卡在这上面。
