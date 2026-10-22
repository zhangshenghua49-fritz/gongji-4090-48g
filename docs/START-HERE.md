# START HERE — 新会话从这里读起

> 写于 2026-10-22，上一轮会话尾部交接。
> **一句话**：给 YG 搭一套能在共绩算力上做「AI 图像 + AI 声音 + AI 视频」的环境，
> 用来把他的小说《钢板与黑麦》做成动画视频，解说用**因幡巡（美咕噜）**的音色。
> 结论已经收敛：**不用自己造镜像，平台预制镜像够用 + 因幡巡配音走 IndexTTS2**。

---

## 0. 用户是谁、要什么（原话）

- YG 是写长篇架空历史小说的作者（德苏双社会主义世界线，首部《钢板与黑麦》）。
- m00001 原话：「做视频需要用到 AI 的。比如说图的 AI，比如说声音的 AI。视频的。所以说请你先把我这个共绩的算力平台的镜像顺带一提提声音的话，我想你去社区里面找一找有没有因幡巡的声音克隆的。其他的 TTS 也是要有的，毕竟做视频。只是让这个声音解说。显卡为 4090 48G 显存版本。所能负载的最大限度最好性能的模型加装上去。」
- m00011 纠正过一次：「我只是叫你把镜像站装上去而已」——不要擅自开机、下单、充值。
- m00718 问：「因幡巡的语音是要自己采集音频，然后再进行克隆吗，还是已经有权重了。」
- m01734 问：「现在这些有的是不是太老了？」

## 1. 这个项目的三条线，现在各自的状态

| 线 | 状态 | 结论 |
|---|---|---|
| 平台机制 | ✅ 清楚 | 详见 `docs/platform-facts.md` |
| 镜像/选型 | ✅ 已收敛 | **平台 40 个预制镜像够用，不用自建**；详见 `docs/platform-preset-services.md` |
| 因幡巡声音 | ✅ 有解 | IndexTTS2 克隆 + VITS 权重兜底；详见 `docs/voice-inaba-meguru.md` |

---

## 2. 最关键的事实（新会话别再重复查）

### 2.1 共绩算力账号现状（2026-10-22 实测）
- 控制台 `https://console.suanli.cn`，账户 182****1502，团队 `gjsUZ16qIk1T96g2`，团队 ID 24759
- **余额 4.01 元，算力券 3 张**
- 云主机 0 台、弹性部署 0 个、镜像仓库 0 B
- **云主机产品线「正在优化升级，暂时无法新建」**（页面橙色横幅原文），所以 4090 **48G** 走不通
- 弹性部署可用，机型价目（按秒计费）：

| 机型 | 显存 | 内存 | CPU | 价格 |
|---|---|---|---|---|
| 4090 | 24GB | 63GB | 18核 | **1.98 元/h**（0.00055/秒）|
| 5090 | 32GB | 63GB | 16核 | 3.25 元/h |
| 4090-48G | 48GB | 63GB | 16核 | 3.02 元/h |
| 910B3 | 64GB | 126GB | 24核 | 4.2 元/h |

⇒ 4.01 元 ≈ 2 小时 4090 24G。**不要同时开多台。**

### 2.2 平台两种发布方式（官方文档原文）
文档：`https://suanli.cn/docs/flexible-deployment/product-billing/bv4gwriuoiec82kpkjccdbc0nie/`
- **方式一：预制镜像**（推荐）→ 服务配置 → 「预制服务」tab → 搜索选中 → 页面底部【部署服务】
- **方式二：自定义镜像** → 「自定义服务」→ 填镜像 URL + 端口。**支持 Docker Hub、阿里云等第三方公共仓库**，也支持平台 Harbor `harbor.suanleme.cn/<项目>/<镜像>:<tag>`

⚠️ 早期我误判「必须先把镜像推进共绩 Harbor」，这是错的。早就有公网镜像可直填。

### 2.3 三个主力镜像的精确参数

**MiniMax-H3（视频）** — 预制服务，文档 `.../pre-fabricated-services/aibiwd1cqivpm1klc94cswninec/`
- 端口 `8188`（ComfyUI 网页）、`3000`（API）
- 33.1B omni transformer + Qwen3-VL-32B 文本编码器，最长 15s / 24fps / 2K / 原生 32kHz 立体声
- 六个官方工作流（ComfyUI 左侧列表直接选）：
  - `video_minimax_h3_t2v.json`（20 步 res_multistep，最慢最好）
  - `video_minimax_h3_t2v_turbo4step_zh.json` ← **日常用这个，快 5 倍**
  - `video_minimax_h3_i2v.json` / `_i2v_turbo4step_zh.json`（首帧接 `first_frame`，尾帧接 `last_frame`）
  - `video_minimax_h3_r2v.json` / `_r2v_turbo4step_zh.json`（参考图/视频/音频，提示词用 `<Picture 1>` `<Video 1>` `<Audio 1>` 引用）
- **turbo 档铁律：4 步就是 4 步，手动加步数只更慢不会更好**
- 正确权重文件名（我们自建的 `workflows/h3_*.json` 里写成 umt5 了，**是错的，要按这个改**）：
  ```
  minimax_h3_fl2va_pruned_int8_convrot.safetensors
  qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors          → CLIPLoader type="minimax"
  minimax_h3_video_vae_fp16.safetensors                 ← fp16，不是 int8
  minimax_h3_audio_vae_fp32.safetensors
  minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors
  ```
- r2v 模式用 ref2va 模型，**与 t2v/i2v 的 fl2va 不可混用**

**IndexTTS2（因幡巡配音的首选）** — 文档 `.../pre-fabricated-services/rdaaw9nuuizgnjk6gomct5m7nmf/`
- **镜像 URL `harbor.suanleme.cn/laiaqwq/index-tts:0.3.0`，端口 `7860`，推荐 4090**
- 走「自定义服务 → 镜像 URL」填
- bilibili 自回归 TTS；上传参考音频即可克隆；四种情绪控制（同参考音 / 情感参考音频 / 情感向量 / 文字描述）
- Gradio 有自带 API，可远程调
- 单条合成 10 秒~2 分钟（随文本长度）

**Z Image Turbo（出图）** — 预制服务，文档 `.../pre-fabricated-services/hdwgwf9ueiri8vkhum0couxpnlg/`
- 参考配置 4090 单卡；启动后进 ComfyUI，默认工作流 `z_image_turbo_example.json`

**minimax-h3 turbo + RTX VSR 合并镜像** — 文档 `.../pre-fabricated-services/hdvmwc8xnig1nck6pi5c6gjynye/`
- 一个镜像 = ComfyUI(8188) + VSR API(8001)，只需一张 **5090 32G** 或 4090 48G
- 显存：H3 生成峰值 ~27.8 GiB；VSR 每任务 6~10.5 GiB ⇒ **24G 卡吃不下 both 模式**
- `run` 参数：`both`(默认) / `comfyui` / `vsr` / `selftest`
- 超分接口 `POST /api/v1/upscale/file`，**必须 `vcodec=libx264`**（共绩节点 NVENC 不可用）
- `/api/v1/tasks/<id>/result` 返回 mp4 二进制流，不是 JSON

### 2.4 平台硬约束（官方 FAQ）
文档：`.../flexible-deployment/faq/hsxowl4y2i5eogkdsnvcuhv0nae/`
- **弹性部署是无状态的**：容器释放后运行期文件、装的依赖、改的配置**即刻永久丢失**
- **不提供 SSH，不提供持久化终端**；启动命令必须写进镜像 CMD/ENTRYPOINT，调试靠【服务日志】
- 计费精确到秒；**镜像拉取/上传期间不收费**，服务成功部署后才计费
- 单账号任务上限 10 节点
- 这是和云主机**两套东西**：云主机有 SSH、有持久盘、能保存镜像

---

## 3. 因幡巡配音：当前确定的路

1. **VoxCPM2 零样本克隆（首选）** — 2B / **48kHz** / 30 语种 / RTF ~0.3 on 4090。日语音色相似度 SIM **0.825**，明显高于 Ming-3.0-tts 的 0.765。已进镜像：`vox` venv + `scripts/vox_tts_server.py`（:9883），`fetch_models.sh --tier vox`（4.96 GB）。给 5~15 秒参考音即可，零训练；`prompt_wav_path` + 参考音文本是「最像本人」的模式
2. **IndexTTS-2.5（中文旁白 / 情感控制）** — 5.49 GB，22.05kHz。中文旁白够用，采样率偏低。平台预制镜像标的是 `0.3.0`，但上游仓库只有 v2.5.0 这个 tag ⇒ **别指望平台镜像是新版**
3. **VITS 成品权重（兜底，不需要任何参考音）** — `Redmonm/SanobaWitch` 的 `model.pth`（158,902,940 B）+ `config.json`，`speakers={"宁宁":0,"因幡巡":1,...}` ⇒ **sid=1**，apache-2.0，MoeGoe 原生 `zh_ja_mixture_cleaners`。备选 `chinoll/ACGTTS` `jp_1196000.pth`（sid=2，CC-BY-NC-SA，仓库里没有 config.json，配置内嵌）。**`skytnt/moe-tts` 2026-10-22 实测仓库已空（files=0，model.pth 直接 404），从脚本里移除了**
4. **Ming-3.0-tts（英文克隆对照组）** — MIT，AA 英文榜 1066，但日语 SIM 只有 0.765 ⇒ 降为对照组，不再做主力

---

## 4. 已经做完的工件（都在本目录）

```
gongji-4090-48g/
├── README.md                      主手册（含预制镜像的指引）
├── Dockerfile                     自建镜像定义（ARG SETUP_ARGS 切 slim/full）
├── .github/workflows/build-image.yml   云端 build 推 Docker Hub 或 Harbor（4 个 secret）
├── config/extra_model_paths.yaml  ComfyUI 路径重定向
├── scripts/
│   ├── setup_env.sh               环境层：uv + 10 个独立 venv + ComfyUI + 12 节点
│   ├── fetch_models.sh            权重层：--tier img|hq|flux3k|h3|ltx|wan|vox|index25|tts|vits|image|video|voice|all
│   ├── boot.sh                    启动命令（ComfyUI:8188 + VoxCPM2:9883，RUN_MODE/TTS_ENGINE 可选）
│   ├── doctor.sh                  验收脚本（PASS/WARN/FAIL 计数）
│   ├── run_wf.sh                  提交工作流到 ComfyUI 并轮询
│   ├── novel2storyboard.py        小说正文 → 分镜表（本地跑，不占显卡）
│   ├── vox_tts_server.py          ★ VoxCPM2 的 HTTP 服务（:9883，因幡巡主力）
│   ├── ming_tts_server.py         Ming-3.0-tts 的 HTTP 服务（:9881）
│   ├── qwen3_tts_server.py        Qwen3-TTS 的 HTTP 服务（:9880）
│   └── vits_tts_server.py         因幡巡 VITS 常驻服务（:9882）
├── workflows/                     h3_t2va / h3_i2va / h3_r2va / z_image_t2i
├── demo/                          novel2storyboard 的样例输入与输出
└── docs/
    ├── START-HERE.md              ← 你在这
    ├── BUILD-IMAGE.md             ★ 自建镜像的完整操作手册（含不用镜像的应急路线）
    ├── frontier-2026-10-22.md     ★ 三格选型的当日复核（推翻了几处旧结论）
    ├── platform-preset-services.md 40 个预制镜像 + 三件套选用结论
    ├── platform-facts.md          平台机制（计费/端口/存储/保存镜像）
    ├── model-selection-verified.md 三张 AA 榜的实测数据与出处
    ├── stack-4090-48g.md          模型选型与 48G 显存预算
    ├── voice-inaba-meguru.md      因幡巡声库实查
    ├── voice-corpus-sourcing.md   语料源与游戏解包流程（备用）
    └── HANDOVER-2026-10-21.md     上一版交接（历史，已被本文件取代）
```

**代码质量**：所有 `.sh` 过 `bash -n`，所有 `.py` 过 `py_compile`，`workflows/*.json` 可解析。
**但全部没有真机跑过**（余额少 + 云主机停新），这是最大风险点。

---

## 5. 上一轮踩过的坑（别再踩）

1. **不要试图在云主机里 `docker build`** — 平台是容器化环境，Docker 被禁用（禁 DinD）
2. **本机没有 Docker / Podman / Buildah / WSL**，且**非管理员**（用户 `DESKTOP-96EVQ8E\zhang`）⇒ 本地 build 镜像不可行
3. **`console.suanli.cn/serverless` 会渲染成白屏**（重定向到 `/serverless/idc`）→ 直接用 `/serverless/create`
4. **bgdesk 把 Edge 移到屏幕外（offscreen stage）后，Chromium 会停止渲染**，`printwindow` 永远返回同一帧旧截图；要 `stage release` 移回来
5. **`postmessage-keys` 对 Chromium 无效**（页面不滚），`postmessage-click` 有效
6. **UIA `ScrollItemPattern.ScrollIntoView()` 是唯一能真正滚页面的方式**（Document 层 `ScrollPattern` 报 `VerticallyScrollable=False`）
7. **UIA `Invoke()` 对不可见元素静默无效** —— 提交按钮 rect 超出可视区时会「返回成功但页面没动」，必须先滚到可见
8. **不要用名字匹配全局元素去点任务栏按钮** —— 曾把「新增部署任务」点成页面内同名按钮，把填好的表单重置了
9. **番茄小说正文抓不到** — `fanqienovel.com/page/<bookId>` 对这本书 404（未公开）；`/api/reader/directory/detail?bookId=7697640572990786585` 只能拿章节 id 列表（首章 `7697640830021927449`），正文有反爬签名。**正文需要 YG 自己贴过来。**
10. **AA 榜上的 H3 Max 不是 MiniMax 官方版** —— 是第三方拿 H3 权重后训练，分数反而低于原版（1156 < 1158）
11. **Wan 3.0 没有开源权重** —— `AlibabaCloud-Official/Wan3.0` 仓库截至 2026-09 只有 README + Apache-2.0，无模型卡

---

## 6. 下一步该做什么（按优先级）

> **10-22 修订**：A 和 C 已由 [`frontier-2026-10-22.md`](frontier-2026-10-22.md) 的复核结果取代；E 已完成。见下方。

**A. ~~花 3 毛钱验明 Qwen Image 的版本~~ → 不用验了**
AA 榜实测 Qwen-Image-2.1 是**免 gate 直接可下**（`gated=False`，仓库 33.13GB：transformer 14.23 + TE 17.54 + VAE 1.35）。不必再猜平台镜像是 1.0 还是 2.1 —— 要用 2.1 就直接拉 HF。省下这 3 毛。
（注意：48G 上 **别用默认 2048²**，实测需 ~56GiB；锁 1024–1536 或走 GGUF Q8_0 7.64GB。）

**B. 跑通一条 H3 带声视频**（不变，但参数要改）
预制「MiniMax-H3」→ `video_minimax_h3_t2v_turbo4step_zh.json` → 4 步 → 5 秒 768p 带音轨。
显存按 **32–36GB** 预算（平台镜像靠 TE 走 CPU offload 才做到 27.8GiB）；**带语音音色时步数要 ≥12，不是 8**（官方原话 8 步「audio is often the weak link」）。

**C. 因幡巡配音 → 已改用 VoxCPM2（并已进镜像）**
~~`index-tts:0.3.0`~~ 换成 **`OpenBMB/VoxCPM2`**（实测 4.96GB / Apache-2.0 / **48kHz 直出** / 日语 SIM 0.825）。
已经落地的部分：`scripts/vox_tts_server.py`（`:9883`，`/clone` `/hifi_clone` `/design` `/unload`）、
`setup_env.sh` 第 5b 节建 `vox` venv（放在 `--min` 之外，是主力不是可选项）、
`fetch_models.sh --tier vox`、`boot.sh` 里 `TTS_ENGINE=vox` 为默认值。
参考音准备：找一段干净日文少女音 10–20s，同一段同时喂 `reference_wav_path` 和 `prompt_wav_path`（后者要附确切文本，最像本人）。
中文旁白仍走 **Ming-3.0-tts-0.5B**（MIT / 44.1kHz / 3.00GB，`:9881`，`TTS_ENGINE=ming`）。
`index-tts:0.3.0` 那个镜像版本存疑（仓库没有 0.3.0 这个 tag），且 IndexTTS-2.5 输出只有 22.05kHz。

**D. 分镜**
《钢板与黑麦》前三章约 3 万字。`scripts/novel2storyboard.py` 已写好并能跑（`demo/` 里有样例），**等 YG 把正文贴过来**就能出分镜表。

**E. ~~修正自建工作流~~ → 已完成**
`workflows/h3_t2va.json`、`h3_i2va.json`、`h3_r2va.json` 里的权重名已是正确的 `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`，不再是 umt5。`scripts/doctor.sh:130` 与 `scripts/fetch_models.sh:141` 也已对齐。这条可以划掉了。

**F. FLUX 3 klein → 已进镜像与拉取脚本**
BFL 官方仓 `black-forest-labs/flux-3-image-klein-comfy` 是 gated（`gated=auto`，匿名 403），必须登录 + 网页点同意才能下。
脚本默认改走 **`ml-resources/flux-3-image-klein-comfy`** —— 36 个文件、文件名、字节数逐项一致，`gated=False`，匿名 206。
实测 int8 档 **5.83 DiT + 4.86 TE + 0.34 VAE = 11.02 GB**（48G 上余量极大，可开 batch 或高分辨率）；
bf16 档 20.31GB；可选 prompt upsampler（9B）int8 9.75GB。`fetch_models.sh --tier flux3k`。想切回官方仓：`FLUX3_REPO=... HF_TOKEN=hf_xxx`。
注：Fibo 2.0 要 ComfyUI ≥ v0.43（支持 PR #17240 于 2026-10-21 才 merge，v0.42.1 不含）。

**G. 自建镜像（新增，YG 10-22 指定要做的事）**
本机没有 Docker / Podman / Buildah / WSL，平台容器禁 DinD ⇒ 必须云端构建。
完整操作手册见 [`BUILD-IMAGE.md`](BUILD-IMAGE.md)。三条路线：
- **D 路线（先做，零成本）**：用平台预制 `MiniMax-H3` 镜像，进容器 `git clone` 项目后跑 `setup_env.sh --min` + `fetch_models.sh --tier h3 --tier vox`。缺点是新实例每次重装 15–25 min。
- **A 路线（推荐固化，零 secret）**：`.github/workflows/build-image.yml` → GitHub Actions → **ghcr.io**（Actions 自带的 `GITHUB_TOKEN` 就够推，不需要 Docker Hub、不需要配 secret）→ 平台「自定义服务」直填地址。一条命令：`.\scripts\deploy-image.ps1 -Token ghp_xxx -Flavor slim`（建仓库 + push + 触发 + 轮询 + 把包改 public + 打印地址）。
- **B 路线（可选）**：仓库 Settings → Variables 加 `REGISTRY`/`REGISTRY_NAMESPACE`/`REGISTRY_USER` + secret `REGISTRY_PASSWORD` 指向 `harbor.suanleme.cn`，私有、国内拉取更快。workflow 不用改。
镜像分 `slim`（~9GB：ComfyUI + VoxCPM2 + Qwen3-TTS + whisper）与 `full`（~22GB：再加 IndexTTS-2.5 / MegaTTS3 / GPT-SoVITS / Ming / VITS）。**模型不在镜像里**，仍由 `fetch_models.sh` 拉。

**当前唯一卡点**：建仓库和 push 需要一次 GitHub 授权。本地仓库已 `git init` + commit `082aa02`（45 文件 / .git 5.5MB），`.gitattributes` 已锁 `eol=lf`（否则 CRLF 会让 Dockerfile 里的 `bash setup_env.sh` 报 `\r: command not found`），`.gitignore` 已挡掉 `.cache/` `local/` `shots/`。**只差一个 `repo`+`workflow` 权限的 classic token。**

---

## 7. 跟 YG 沟通时的注意

- 他要**阶段性进度**，不要闷头做完才说。
- 他会质疑「这是不是最强」「是不是太老了」—— 回答要带**可验证的数据和出处**，不要营销口径。
- 他高度在意性价比，要比价。
- 他明确说过：验收标准是**真机验过才算完**，别把"服务端自测通过"说成"已交付"。
- 旧版本文件/记忆**一律不删**，只移出主文件、标注淘汰、另存 ARCHIVE。

---

## 附录 A：被本文件取代的旧热记忆原文（存档，勿据此施工）

### A.1 共绩算力弹性部署（写于 2026-10-21，已被 §2 取代）

> 共绩算力弹性部署：MiniMax H3 Studio 已在云上跑通（任务 `d202610212304-h3-studio-demo20` / ID `TASK-3516002-24759`，4090 24G，1.98 元/h 按秒计费，端口 8001，`https://deployment-24759-5jiep83o-8001.550w.link`，`/health` 与 `/ready` 已验证）。**账户余额仅 4.01 元，此任务不主动停会持续烧钱**。云主机产品线「正在优化升级，暂时无法新建」，要 4090 48G（3.02 元/h）只能走弹性部署的 48G 机型。控制台 `/serverless` 白屏，直接用 `/serverless/create`。

**淘汰原因**：该部署任务已于 2026-10-22 实测 404（链接返回共绩自己的错误页，文案「链接地址错误、页面已被删除、任务被暂停或删除」），已不存在、不再计费。其余事实（余额、云主机停新、`/serverless` 白屏）仍然有效。

### A.2 因幡巡 TTS 权重（写于 2026-10-21，内容仍全部有效，已并入 §2.3 / §3）

> 因幡巡 TTS 不需要采集音频，已有现成 VITS 权重：`Redmonm/SanobaWitch` `model.pth` 158,902,940 B + `config.json`，`speakers={"宁宁":0,"因幡巡":1,...}` ⇒ **sid=1**，apache-2.0，MoeGoe 原生 `zh_ja_mixture_cleaners`（首选）；~~`skytnt/moe-tts` sid=1（454 MiB）~~ **该仓库 2026-10-22 实测已空（files=0），不可用**；`chinoll/ACGTTS` `jp_1196000.pth` sid=2（CC-BY-NC-SA）。推理器 MoeGoe（MIT）。云上直接 `fetch_models.sh --tier vits` 下。因幡巡自建镜像路线被堵：共绩镜像仓库仍 0 B，本机无 docker/podman/buildah、无 WSL、非管理员 ⇒ 只能走 GitHub Actions 云端 build（`.github/workflows/build-image.yml` 已写好）或别的机器。

**状态**：未淘汰，只是不完整——新增了「IndexTTS2 平台预制镜像可直接克隆」这条更省事的路径，见 §2.3。
