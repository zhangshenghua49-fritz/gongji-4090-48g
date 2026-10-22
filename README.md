# 共绩算力 · RTX 4090 48G · AI 视频生产镜像

一套装好就能用的「图 + 声 + 视频」环境。目标：**镜像在 GitHub Actions 上构建好推到 ghcr.io**
（零 secret，Actions 自带 token 就够），开一台 4090 48G（¥3.02/h 按量）时直接填镜像地址，
开机就是装好的环境，不进去装任何东西，关机也不丢。

> **⚠️ 新会话从这里开始：先读 [`docs/START-HERE.md`](docs/START-HERE.md)** —— 一页写清目标、
> 当前状态、平台精确参数、下一步该点哪儿。本 README 是工程细节手册，START-HERE 是交接入口。
>
> 一句话现状：平台「弹性部署」侧栏已有 **40 个官方预制镜像**，图像（Z Image Turbo / Qwen Image /
> Flux.2）、视频（MiniMax-H3 / H3+VSR 合并镜像）、声音（**IndexTTS2** / CosyVoice）**全都有、4090 就能跑**。
> 云主机当前暂停新建，所以**直接用预制镜像出活**；本仓库这套自建镜像作为后续优化项。

```
gongji-4090-48g/
├── README.md                  ← 你在这
├── Dockerfile                 镜像定义（在容器外构建，平台禁 DinD）
├── .github/workflows/
│   └── build-image.yml        路线 A：GitHub Actions 云端构建并推送（不碰你电脑）
├── config/
│   └── extra_model_paths.yaml  ComfyUI 指向共享存储卷（权重不进镜像）
├── scripts/
│   ├── setup_env.sh           环境层：venv / ComfyUI / 节点 / TTS 框架（镜像构建时跑）
│   ├── build_push.sh          路线 B 的推送封装（本机有 docker 时用）
│   ├── wsl_build.sh           路线 B：装 WSL2 → build → push 一键
│   ├── fetch_models.sh        权重层：分档下载，幂等续传（开机后一次性）
│   ├── boot.sh                容器启动命令（ComfyUI:8188 + TTS:9880）
│   ├── doctor.sh              验收：硬件 / 依赖 / 权重 / 工作流 / 冒烟
│   ├── run_wf.sh              提交工作流到 ComfyUI 并等结果
│   ├── novel2storyboard.py    小说正文 → 分镜表 + H3 提示词骨架（不占显卡）
│   ├── ming_tts_server.py     Ming-3.0-tts HTTP 服务（主力配音：克隆/情感/日语）
│   └── qwen3_tts_server.py    Qwen3-TTS HTTP 服务（备用：10 语言 / 声音设计）
├── workflows/
│   ├── h3_t2va.json           文字 → 视频 + 同期声（主力）
│   ├── h3_i2va.json           首帧图 → 视频 + 同期声
│   ├── h3_r2va.json           角色参考图 → 同一角色演新镜头
│   └── z_image_t2i.json       文 → 图（封面 / 分镜草图）
└── docs/
    ├── platform-facts.md      平台机制（计费 / 端口 / 存储 / 保存镜像）
    ├── platform-preset-services.md  官方预制镜像清单（40 项）+ 三件套选用结论 ★
    ├── stack-4090-48g.md      模型选型与 48G 显存预算（含全部实测体积）
    └── voice-inaba-meguru.md  因幡巡声库实查（权重下载源 / license / sid 映射）
```

---

## 1. 为什么这么切：三层存储

4090 48G 的算力足够跑当代最好的开源模型，但**系统盘只有 80 GB**，光 MiniMax-H3
一套就是 39 GB。所以本方案把东西分三层，哪层该进镜像、哪层不该进，划清楚：

| 层 | 位置 | 内容 | 进镜像？ |
|---|---|---|---|
| 环境层 | `/root/venvs/*`、`/root/ComfyUI`、`/root/src` | CUDA 依赖、vevn、ComfyUI 与节点、TTS 框架 | **是**，约 20–25 GB |
| 权重层 | `/root/data/models`（**共享存储卷**） | 全部 safetensors / pth（151 GB 全量档） | 否，挂卷复用 |
| 输出层 | `/root/data/output` | 出图、出片、配音 wav | 否 |

这样做的收益很直接：**换机器、换卡型、重装实例，权重都还在**。镜像只装环境，
保存和拉取都快；权重放卷上，一次下载长期复用。`boot.sh` 通过
`extra_model_paths.yaml` 把 ComfyUI 的模型路径整体重定向到卷上，节点里看到的就是卷里的模型。

> ⚠️ 平台系统盘和数据盘都是**本地 SSD、无冗余**，单点故障可能丢数据。
> 权重能重下无所谓，但自己训的 LoRA、拍的素材请定期导出（平台提供对象存储）。

---

## 2. 造镜像（在云主机**外面**做）

### 2.0 为什么不能"先进去再装"

开机那一秒就开始计费。进容器跑 `setup_env.sh` 要 40 分钟，等于每次开机先烧 2 块钱，
再花 40 分钟等 pip——**这正是镜像要解决的问题**，镜像存在的意义就是把这段安装搬到一次性构建里。

所以顺序必须是：

```
造镜像 → push 到 ghcr.io（零 secret）→ 建实例时直接填镜像地址 → 开机就是装好的环境
```

平台云主机是容器、**禁用 DinD**，`docker build` 不能在实例里跑。构建只能发生在容器外的
Linux 上。三条路，按省事程度排：

| 路线 | 需要什么 | 耗时 | 花钱 |
|---|---|---|---|
| **A. GitHub Actions** | 一个 GitHub 账号 | 15–30 分钟（云端跑） | 免费（私有仓库每月 2000 分钟） |
| **B. 本机 WSL + Docker** | 重启一次电脑、装 WSL2 | 40–60 分钟 | 免费 |
| **C. 共绩 CPU 实例 + buildah** | 平台能开机的时段 | 20–30 分钟 | 约 ¥0.3 |

三条路产物完全一样，都是 `harbor.suanleme.cn/<项目>/gongji-4090-48g:v1`。

> ⚠️ 不管走哪条，镜像里都**不含模型权重**。151 GB 权重塞不进 80 GB 系统盘，
> 权重走共享存储卷，见 §2.5。

### 2.1 路线 A：GitHub Actions → ghcr.io（推荐，零 secret）

不碰你的电脑，不用装 Docker，不用重启，**也不用配任何 secret**。
Actions 自带的 `GITHUB_TOKEN` 就能推 `ghcr.io/<你的账号>/gongji-4090-48g:slim`。
仓库里已经写好 `.github/workflows/build-image.yml`。
**完整操作手册见 [docs/BUILD-IMAGE.md](docs/BUILD-IMAGE.md)**。

一条命令（本地仓库已 `git init` 且有 commit，只差推到远端）：

```powershell
cd C:\Users\zhang\Documents\deepseek-harness\default-workspace\gongji-4090-48g
.\scripts\deploy-image.ps1 -Token ghp_xxxxxxxxxxxx -Flavor slim
```

它会：验 token → 建/复用 public 仓库 → push → 触发 Actions → 每 30 秒轮询日志
→ 把 ghcr 包改成 public → 打印能直接填进平台的镜像地址。全程 25–45 min。

token 在 GitHub → Settings → Developer settings → Personal access tokens →
**Tokens (classic)** → 勾 `repo` + `workflow`。它只在 push 那一次命令里出现，
不写进 `.git/config`，不落任何文件。

手动版（不想让脚本碰账号）：网页建 public 仓库 → `git remote add origin ...` →
`git push -u origin main` → Actions 页 → `build-image` → Run workflow。

**要换仓库**（Docker Hub / 共绩 Harbor）：仓库 Settings → Variables 加
`REGISTRY` / `REGISTRY_NAMESPACE` / `REGISTRY_USER`，再配 secret `REGISTRY_PASSWORD`。
不设就默认 ghcr。

**两个 flavor 的差别**（详见 Dockerfile 头注释）：

| flavor | 内容 | 体积 | 首次构建 |
|---|---|---|---|
| `slim` | ComfyUI + 节点 + **VoxCPM2** + Qwen3-TTS + whisper | ~9 GB | 25–40 min |
| `full` | 再加 IndexTTS-2.5 / MegaTTS3 / GPT-SoVITS / Ming / VITS | ~22 GB | 60–90 min |

大多数情况 `slim` 就够。之后有 `cache-from: type=gha` 缓存，改动重构建 3–5 分钟。

### 2.2 路线 B：本机 WSL + Docker

```bash
# 第一次：装 WSL2 + Ubuntu（弹 UAC 点「是」，然后重启电脑）
bash scripts/wsl_build.sh

# 重启后：重跑，会自动装 docker、build、push
export HARBOR_PROJECT=<你的项目名>
export HARBOR_USER=<访问凭证用户名>
export HARBOR_PASS=<访问凭证密码>
bash scripts/wsl_build.sh --build
```

凭据也可以写进 `runtime.env`，脚本会自动读。产物路径同路线 A。

### 2.3 路线 C：共绩实例 + buildah（应急）

平台禁 DinD，但 `buildah` 不需要 daemon，用 `vfs` 存储驱动可以在容器里构建。

```bash
# 开一台最便宜的 CPU 实例（不要开 4090，构建用不上显卡）
apt-get update && apt-get install -y buildah
cd /root/gongji-4090-48g
buildah bud --storage-driver=vfs --platform linux/amd64 -t gongji:v1 .
buildah login --username <user> --password <pass> harbor.suanleme.cn
buildah push --storage-driver=vfs gongji:v1 \
    docker://harbor.suanleme.cn/<项目>/gongji-4090-48g:v1
```

构建完关机，账单约 ¥0.3。只在 A、B 都走不通时用。

### 2.4 建云主机：填镜像

控制台 → 云主机 → 新建：

| 项 | 值 |
|---|---|
| 显卡 | RTX 4090 48G × 1（¥3.02/h 按量） |
| 镜像 | **我的镜像** → 填 `harbor.suanleme.cn/<项目>/gongji-4090-48g:v1` |
| 系统盘 | 80 GB（默认，镜像里约 22 GB） |
| 数据盘 / 共享存储 | ≥ 200 GB（全量权重 151 GB；核心档 `img`+`h3` 55 GB 够） |
| 端口 | `8188`（ComfyUI）、`9880`（TTS） |
| 启动命令 | `bash /root/gongji-4090-48g/scripts/boot.sh` |

开机后 1~3 分钟进 ComfyUI，**不需要再装任何东西**。`boot.sh` 会载入 `env.sh`、
挂 `extra_model_paths.yaml`、后台拉起 Qwen3-TTS(:9880)、前台 exec ComfyUI(:8188)。

### 2.5 拉权重（首次一次性，之后卷上有就不用再拉）

```bash
bash /root/gongji-4090-48g/scripts/fetch_models.sh --tier img    # 16 GB  出图 + 配音 + 因幡巡 + ASR ← 起步
bash /root/gongji-4090-48g/scripts/fetch_models.sh --tier h3     # +39 GB MiniMax-H3（音视频同期声）★ 主力
bash /root/gongji-4090-48g/scripts/fetch_models.sh --tier hq     # +17 GB Qwen-Image-2.1
bash /root/gongji-4090-48g/scripts/fetch_models.sh --tier ltx    # +37 GB LTX-2.5
bash /root/gongji-4090-48g/scripts/fetch_models.sh --tier wan    # +42 GB Wan2.2
bash /root/gongji-4090-48g/scripts/fetch_models.sh --tier all    # 151 GB 全量
```

全部走 `hf-mirror.com`（平台容器不直连外网）。幂等 + `curl -C -` 断点续传，中断了重跑同一条命令。

**建议组合**（48G 单卡日常出片）：`img + h3 = 55 GB`。出图用 Z-Image-Turbo
（8 步 4 秒一张，Apache-2.0 可商用），出片用 MiniMax-H3（原生带音轨，口型/环境声一次成）。

⚠️ 权重必须在**共享存储卷**上（`/root/data/models`），不能只放系统盘——系统盘关机即销毁。

### 2.6 验收

```bash
bash /root/gongji-4090-48g/scripts/doctor.sh
```

PASS/WARN/FAIL 三项计数 + 失败明细。核心档全绿再往下走。

### 2.7 改了环境怎么重出镜像

改 `Dockerfile` 或 `scripts/setup_env.sh` 之后：

- 路线 A：push 代码，Actions 自动重跑（`.github/workflows/build-image.yml` 里配了 `paths` 触发）
- 路线 B：重跑 `bash scripts/wsl_build.sh --build`
- 急着改一行：直接在实例里改完 → **关机并保存镜像** 覆盖旧 tag

**保存镜像只打包系统盘**，共享卷不进镜像——这就是 §1 分三层的原因。

### 2.8 日常启动

开机即用，不用重建。要改代码就用 JupyterLab(8888) 或 `scp` 传文件；要固化就重新出镜像（§2.7）。

---

## 3. 模型清单与显存账

完整实测数据（每个文件的字节数、license、显存曲线）在 `docs/stack-4090-48g.md`。
这里是决策摘要：

### 图像

| 模型 | 体积 | 为什么选它 |
|---|---|---|
| **MOSS-Image** SFT int8 | **15.5 GB** | **Apache-2.0，三者里唯一真开源、商用零门槛**。JSON layout prompt（bbox `yxyx` / `abs_centralized`）能指定「谁在哪、占多大」，直接对上分镜排版；文字渲染与文字组块是它的强项（官方示例就是中文字条）。ComfyUI 官方打包仓 + 原生插件。`--tier moss` |
| **Qwen-Image-2.1** FP8 | 17.2 GB | 中文文字渲染最强 + 图片编辑 + 原生 RGBA + ≤10 张参考图，AA 榜开源第一（1042）。Qwen Research License（非商用）。`--tier hq` |
| **FLUX 3 klein** int8 | **11.0 GB** | BFL 2026-10-15 出的 5.6B，10 参考图，48G 上余量极大（可开 batch / 高分辨率）。FLUX 3 Kommunity License（年营收 <$5M 免费商用）。`--tier flux3k` |
| **Z-Image-Turbo** 6B nvfp4 | 7.75 GB | Apache-2.0 可商用、8 步出图、体量最小。**实测 AA 936 分 / 榜第 71**，定位是快速草图，不是主力。`--tier img` |

> MOSS-Image 在 AA 榜上**还没有条目**（2026-10-22 抓的榜里查不到），所以它没有 Elo 分数可对照。
> 它进主力不是靠榜，是靠 ①Apache-2.0 ②JSON layout ③Comfy-Org 官方打包仓 129 万下载。

### 视频

| 模型 | 体积 | 为什么选它 |
|---|---|---|
| **MiniMax-H3** int8+fp4 | 42.0 GB 全常驻 / 768p 实跑 32–36 GB | 音视频同期声（对白 + 环境声一条出）、Ref2VA 多模态参考、ControlNet Union。**T2V v2.1 Elo 1158（总榜第 4，开源第一，领先开源第二 LTX-2.5 Fast 209 分）、I2V v1.1 Elo 1140（总榜第 1）**。48G 上唯一能全精度跑的当代旗舰 |
| **LTX-2.5** 22B int8 | 38.7 GB | 原生 multi-shot 多镜头，叙事连贯性最好。T2V 949 / I2V 984 |
| **Wan2.2** S2V-14B | ~42 GB 档 | 语音驱动口型对轨（拿 TTS 音频直接对口型）；Ti2V-5B 做便宜草稿 |

H3 的 42.0 GB 拆解（实测字节）：`pruned_int8_convrot 20.97 + qwen3vl_32b nvfp4_awq 15.69 + video_vae_int8 2.81 + audio_vae_fp32 0.61 + turbo_8step LoRA 1.96`。
显存紧时把检查点换 `pruned_w6a8`（15.98 GB），全常驻降到 37.0 GB；或让 TE 走 CPU offload（平台镜像就是这么做到 27.8 GiB 的）。

**别同时跑 H3 和 LTX**。同一个 ComfyUI 里切换模型时，先 `POST :9883/unload` 让 VoxCPM2 退显存，
ComfyUI 自己也会释放上一轮。

### 声音

| 模型 | 用途 |
|---|---|
| **VoxCPM2 2B** | **主力配音（因幡巡）**。Apache-2.0，48 kHz 直出，30 语种，日语零样本 SIM 0.825（开源最高档），RTF ~0.3 on 4090。`:9883` |
| **Ming-3.0-tts 0.5B** | 对照组 / 中文旁白。MIT，44.1 kHz，中文/日/韩德法西。AA 克隆榜 Elo 1066（榜第 13，开源第一），英文克隆综合分强于日语保真。`:9881` |
| **Qwen3-TTS 1.7B**（三件套） | 备用配音。Apache-2.0，10 语言含日语，首包 97 ms。<br>`CustomVoice` 预设音色+情绪 instruct；`VoiceDesign` 文字描述造音色；`Base` **零样本克隆**。`:9880` |
| **faster-whisper large-v3** | 字幕、歌词对齐、语料切分 |
| **因幡巡 VITS ×3** | 详见第 4 节。`:9882` |
| IndexTTS-2.5 / GPT-SoVITS / MegaTTS3 | 进阶：微调、情感控制。注意 IndexTTS-2.5 输出只有 22.05 kHz |

---

## 4. 因幡巡的声音

三条路，按「上手速度 ←→ 质量上限」排。**手上一段她的音频都没有的，直接跳到路 C**——
那条是现成权重，零采集零训练。

### 路 A：零训练克隆（推荐先试，5 分钟）

**VoxCPM2**（`:9883`，2B，48 kHz 直出）。日语零样本音色相似度 0.825，是当前开源
里对「拿一段因幡巡原声克隆、再念小说旁白」这条链路最强的。不用训练，给 5–20 秒参考音就行。

```bash
# 1. 准备参考音频（角色台词，5~20 秒干净人声，存 meguru.wav）
#    从视频抽音轨： ffmpeg -i clip.mp4 -ss 00:12 -t 8 -vn -ar 16000 -ac 1 meguru.wav
#    注意：VoxCPM2 吃 16 kHz 参考音，内部经 AudioVAE V2 放大到 48 kHz 输出

# 2. 零样本克隆（不需要参考文本）
curl -X POST http://127.0.0.1:9883/clone \
  -H 'Content-Type: application/json' \
  -d '{"text":"今日の動画は、わたくしが解説しますわ！",
       "reference_wav_path":"/root/data/ref/meguru.wav"}' \
  -o line001.wav

# 3. 高保真克隆（续写式，最像本人 —— 代价是要给参考音的确切文本）
curl -X POST http://127.0.0.1:9883/hifi_clone \
  -H 'Content-Type: application/json' \
  -d '{"text":"はあ……また失敗しちゃった。",
       "prompt_wav_path":"/root/data/ref/meguru.wav",
       "prompt_text":"（这段参考音频的原话，一字不差）",
       "reference_wav_path":"/root/data/ref/meguru.wav"}' \
  -o line002.wav

# 4. 出片前腾显存（H3 全常驻要 42 GB，两者不能同时挂着）
curl -X POST http://127.0.0.1:9883/unload
```

**为什么 `hifi_clone` 比 `clone` 更像**：`prompt_wav_path` 走的是「音频续写」路径，模型
把参考音当成上文接着往下说，保留全部韵律细节；`reference_wav_path` 只抽音色向量，
细节会丢一层。官方文档明确说后者是「for better similarity」的补充，不是替代。

**对照组：Ming-3.0-tts**（`:9881`，MIT，44.1 kHz）。英文克隆综合分更强（AA controlled
1066 / 榜第 13），但日语 SIM 只有 0.765。当 VoxCPM2 的口音不对味时用它交叉验证。

```bash
TTS_ENGINE=ming bash /root/scripts/boot.sh     # 换引擎重启
curl -X POST http://127.0.0.1:9881/clone \
  -H 'Content-Type: application/json' \
  -d '{"text":"今日の動画は、わたくしが解説しますわ！",
       "language_id":"ja",
       "ref_audio":"/root/data/ref/meguru.wav",
       "ref_text":"（这段参考音频的原话）"}' \
  -o ming_line001.wav
```

**要换回 Qwen3-TTS**（`TTS_ENGINE=qwen` 或直接 curl :9880）：它的 `clone_prompt` 把音色落盘成可复用
prompt，服务重启后自动重建，大批量台词时更省事：

```bash
curl -X POST http://127.0.0.1:9880/clone_prompt \
  -H 'Content-Type: application/json' \
  -d '{"ref_audio":"/root/data/ref/meguru.wav","ref_text":"（原话）","name":"meguru"}'
curl -X POST http://127.0.0.1:9880/clone_with_prompt \
  -H 'Content-Type: application/json' \
  -d '{"text":"今天的视频，就由我来解说吧！","language":"Japanese","prompt_name":"meguru"}' \
  -o line001.wav
```

### 路 B：声音设计 → 克隆（没有干净参考音频时）

先让 VoiceDesign 按描述造一个「因幡巡风格」的音色，再把这个合成音当参考去克隆，
全片音色就锁定了：

```bash
curl -X POST http://127.0.0.1:9880/design \
  -H 'Content-Type: application/json' \
  -d '{"text":"えへへ、今日も元気にいこう！",
       "language":"Japanese",
       "instruct":"明るく元気な少女の声、少し甘えた響き、語尾が上がる"}' \
  -o seed.wav
# 然后拿 seed.wav 当参考去克隆，全片音色就锁定了
curl -X POST http://127.0.0.1:9880/clone_prompt \
  -H 'Content-Type: application/json' \
  -d '{"ref_audio":"/root/data/ref/seed.wav",
       "ref_text":"えへへ、今日も元気にいこう！",
       "name":"meguru"}'
```

### 路 C：成品声库（**不需要采集任何音频**）

手上没有参考音频、也不想训练的，从这条开始：**权重是现成的，下完就能出声。**

```bash
bash scripts/fetch_models.sh --tier vits    # 三份全下，约 780 MB
vits                                         # 起服务，:9882
curl -X POST :9882/tts -H 'Content-Type: application/json' \
  -d '{"text":"今天的视频，就由我来解说吧！","speaker":"因幡巡"}' -o line001.wav
```

三份权重（体积 / license / sid 映射的实查细节在 `docs/voice-inaba-meguru.md`）：

- `Redmonm/SanobaWitch` — **首选**。`config.json` 里 `text_cleaners` 就是 MoeGoe 的
  `zh_ja_mixture_cleaners`，加载不会卡架构；6 人合一，**sid=1 = 因幡巡**，apache-2.0
- `chinoll/ACGTTS` — 19 人日语底模（CC-BY-NC-SA-4.0，**非商用**），sid=2；仓库里没 config.json，配置内嵌
- ~~`skytnt/moe-tts`~~ — 2026-10-22 实测该仓库**已空**（`files=0`，`saved_model/0/model.pth` 直接 404），已从 `fetch_models.sh` 移除

这些是 2022 年代的 22 kHz VITS：**音色认得出来，但长句韵律平、几乎没有气声细节**。
做旁白解说够用，做角色台词就露怯——要更好就走上面的路 A（8 秒参考音频）或拿语料微调。

语料从哪来（公开数据集 / 自己从游戏解包）写在 `docs/voice-corpus-sourcing.md`，
包括 `NandemoGHS/Japanese-Eroge-Voice-V2`（2657 小时、MIT、但角色匿名化）的反查方法。

> **声优权利提示**：因幡巡的音色属于其声优。自己做的视频用于个人/同人没问题，
> 商用或公开发布请自行判断边界——这条线每个 UP 主都得自己划。

---

## 5. 踩过的坑

| 坑 | 表现 | 处理 |
|---|---|---|
| 容器不直连外网 | `pip install` / `huggingface.co` 超时 | 全部走镜像源：pip 用清华源，模型用 `hf-mirror.com`（脚本已内置） |
| 系统盘只有 80 GB | 权重放系统盘，装到一半 No space | 权重一律 `/root/data/models`，`extra_model_paths.yaml` 重定向 |
| 保存镜像不含数据盘 | 换实例后模型全没了 | 挂同一个共享卷；或重新 `fetch_models.sh` |
| harbor 凭据与平台账号不互通 | `docker login harbor.suanleme.cn` 失败 | 控制台「镜像仓库 → 访问凭据」单独取 |
| 平台拉不到 docker.io | 自己 build 的镜像推不上去 | 走「云主机内装 → 关机保存镜像」，别绕 harbor |
| 多个 TTS 框架版本打架 | 装 GPT-SoVITS 后 ComfyUI 起不来 | 每服务独立 venv（`setup_env.sh` 已隔离） |
| 显存被 TTS 占住 | H3 推理 OOM | `curl -X POST :9880/unload` |
| 4090 48G 是魔改卡 | 某些 kernel/驱动组合不稳定 | 别超频；torch ≥ 2.7 对新架构支持更稳 |

---

## 6. 常用命令

```bash
source /root/env.sh                    # 环境变量（MODELS / HF_ENDPOINT / TTS_MODELS）

bash /root/scripts/doctor.sh           # 全量自检
bash /root/scripts/doctor.sh --fast    # 跳过冒烟测试

bash /root/scripts/fetch_models.sh --tier h3     # 补下载某一档
bash /root/scripts/fetch_models.sh --dest /root/data/models --tier img

curl :9882/health                      # 因幡巡成品 VITS 状态 + 说话人表
curl :9882/speakers                    # sid ↔ 角色名（VITS_MODEL 可切声库）
curl -X POST :9882/unload              # 卸载 VITS

curl :9881/health                      # Ming TTS 状态 + 显存
curl :9881/capabilities                # 支持的 task / 语言 / 情感 / 内置音色
curl -X POST :9881/unload              # 卸载 Ming，释放显存

curl :9880/health                      # Qwen3-TTS 状态（切 TTS_ENGINE=qwen 才有）
curl :9880/speakers                    # 预设音色清单
curl :9880/prompt_list                 # 已建的克隆音色（服务重启后自动重建）
curl -X POST :9880/unload              # 卸载 Qwen3-TTS 释放显存

nvidia-smi                             # 显存实况
du -sh /root/data/models/*             # 各档占用
tail -f /root/logs/mingtts.log         # Ming TTS 日志
tail -f /root/logs/qwen3tts.log        # Qwen3-TTS 日志

bash /root/scripts/run_wf.sh /root/workflows/h3_t2va.json   # 跑工作流
```

### 换音轨：H3 出画面，因幡巡出声

H3 自带的同期声是现编的，跨镜头音色不固定。要角色音固定，就把它当无声画面源：

```bash
# 1) 丢掉 H3 现编的声，只留画面（不重编码，秒出）
ffmpeg -i h3_out.mp4 -an -c:v copy silent.mp4

# 2) 接 TTS 音轨。声音比画面长时画面冻在末帧补够（stop_duration 按需改）
ffmpeg -i silent.mp4 -i tts.wav -filter_complex \
  "[0:v]tpad=stop_mode=clone:stop_duration=3[v]" \
  -map "[v]" -map 1:a -c:v libx264 -crf 18 -c:a aac -b:a 192k -shortest dub.mp4

# 3) 只想让声音被截断到画面长度，去掉 tpad，直接 -shortest
```

一次要出多句就从 TTS 批量拿 wav，再拼成一条音轨：
`ffmpeg -f concat -safe 0 -i list.txt -c copy voice_full.wav`，`list.txt` 里写 `file 'line01.wav'` 这种。

---

## 7. 工作流怎么用

`workflows/` 四个 JSON 是 **API 格式**（`/prompt` 直接吃的那种），不是界面拖拽保存的格式。提交：

```bash
bash scripts/run_wf.sh workflows/h3_t2va.json
```

脚本会提交、轮询 `/history`、跑完把产物文件名打出来。想调参就在界面里打开同名工作流改完再跑，也行。

| 文件 | 做什么 | 步数 | 显存峰值 |
|---|---|---|---|
| `h3_t2va.json` | 文字 → 视频 + 同期声（主力） | 8 | ~42 GB |
| `h3_i2va.json` | 首帧图 → 视频 + 同期声（接上 last_frame 就是首尾帧） | 8 | ~42 GB |
| `h3_r2va.json` | 角色参考图 → 同一角色演新镜头 | 4 | ~40 GB |
| `z_image_t2i.json` | 文生图（封面 / 分镜草图，可批量） | 8 | ~9 GB |

三个 H3 都是 **1344×768 / 124 帧 / 24fps ≈ 5.17 秒**。要更长就改 `length`，必须落在 `17k+5` 网格上：124（5.2s）/ 158（6.6s）/ 192（8s）/ 362（15s）。**越长单价越贵**（5→10→15 秒的成本比约 1:2.8:5.5），按镜头切比一条拉到底划算。

日常改三处就够：`prompt`、`seed`、`length`。参考图丢进 ComfyUI 的 `input/`，文件名对上 `h3_i2va.json` 的 `first_frame.png`、`h3_r2va.json` 的 `ref_character.png`。

有件事得先讲明白：**H3 的同期声是"按提示词现编"的，同一角色跨镜头音色会飘。**要固定成因幡巡的声音，走 §4 那条 Ming-3.0-tts 路——H3 只出画面，音轨由 TTS 生成，最后 ffmpeg 合。工作流里没把 TTS 焊进去，是因为两条链的时长控制逻辑不一样（H3 锁 17k+5 帧，TTS 按文本长度自由伸缩），硬接会互相拖。合轨命令见 §6。

## 8. 还没做的（后续可加）

- 批量任务队列（一次提交多条提示词，跑完自动关机省钱）
- 因幡巡 GPT-SoVITS 微调数据集（需要 1 分钟以上干净语料，从游戏里抽）
- LTX-2.5 工作流没预置。ComfyUI 已内置 LTXV 节点（含 `LTXVAudioVAELoader` 那套音频链路），tier_ltx 的权重下下来能跑，但那套节点多、参数我没逐个核过源码，不想给你一份"看着像但跑不通"的 JSON。要用的时候在界面里加载官方模板再改。

## 9. 选型依据

「这些是不是最强」的答案不在文档里靠嘴说，在榜单上。逐条核验过程与原始分数见
[`docs/model-selection-verified.md`](docs/model-selection-verified.md)：视频 H3 开源第一（Elo 1158，领先
第二名 207 分）、图像 Qwen-Image-2.1 开源第一（Elo 1042）、TTS 原方案未进榜已换 Ming-3.0-tts（开源第一，Elo 1066）。
Wan 3.0 至今没有开源权重、H3 Max 是第三方后训练且分数更低，这两条也写在里面，省得下次再绕一遍。
