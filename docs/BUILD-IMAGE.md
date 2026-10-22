# 自建镜像：从"没有 Docker"到"平台里点一下就能跑"

> 2026-10-22。本机没有 Docker / Podman / Buildah / WSL，也不是管理员；
> 共绩的 GPU 容器里禁 DinD（`docker build` 在云主机里跑不起来）。
> 所以镜像必须在**别处**构建，然后推到某个平台能拉的仓库。

---

## 0. 先选路线

| 路线 | 要什么 | 多久 | 适合 |
|---|---|---|---|
| **D. 不用镜像**（先验证） | 只要平台账号 | 立刻 | 现在就想跑通 H3 出片 |
| **A. ghcr.io**（零 secret） | 只要一个 GitHub 账号 | 首次 25–40 min | 长期用，公开镜像，平台直填 |
| **B. 共绩 Harbor** | GitHub 账号 + 平台镜像仓库凭证 | 首次 25–40 min | 长期用，私有，国内拉取快 |
| **C. 借一台有 Docker 的机器** | 任何 x86 Linux + Docker | 20–40 min | 有朋友/有服务器 |

**建议顺序：先走 D 把片子跑出来，同时后台走 A 建镜像。** D 不阻塞任何事。
A 不需要 Docker Hub、不需要配 secret —— Actions 自带的 token 就能推 ghcr。

---

## 1. 路线 D：不建镜像，直接跑（零成本验证）

平台预制镜像里有 **MiniMax-H3**（端口 8188 ComfyUI + 3000 API），已经含 ComfyUI
和 H3 节点。缺的只是本项目自己的 VoxCPM2 / 脚本 / 工作流。

1. 弹性部署 → 新建 → **预制服务** tab → 选 `MiniMax-H3`
2. 机型 **4090-48G**，启动命令改成：

   ```bash
   bash -lc 'cd /root && (git clone --depth 1 https://ghproxy.net/https://github.com/<你的仓库>.git gongji-4090-48g 2>/dev/null || true) && bash /root/gongji-4090-48g/scripts/boot.sh'
   ```

   没有仓库就把项目打包上传（平台支持挂对象存储）。仓库还没建的话，见 §2.1 —— 建仓库
   本来也是路线 A/B 的前置步骤。

3. 端口填 `8188`
4. 进容器后跑一次（只需一次，容器释放即丢，所以每次新实例都要跑）：

   ```bash
   bash /root/gongji-4090-48g/scripts/setup_env.sh --min    # 装 VoxCPM2 等，约 15–25 min
   bash /root/gongji-4090-48g/scripts/fetch_models.sh --tier h3 --tier vox
   ```

**这条路的问题**：每次新开实例都要重装 15–25 分钟（弹性部署无状态，容器释放即丢）。
跑通一次、确认片子能出来之后，就该走 A/B 把环境固化进镜像。

---

## 2. 路线 A：GitHub Actions → ghcr.io（零 secret，推荐）

> 这是整份文档最短的路径：**不需要 Docker Hub 账号，不需要 Harbor，不需要在
> GitHub 配任何 secret。** Actions 自带的 `GITHUB_TOKEN` 就能推
> `ghcr.io/<你的账号>/gongji-4090-48g:slim`。workflow 里最后一步会把包可见性
> 自动改成 public —— ghcr 默认私有，匿名拉不动，这一步不能省。

### 2.1 一条命令

本地仓库已经 `git init` 并有 commit `082aa02`（45 个文件），只差推到远端：

```powershell
cd C:\Users\zhang\Documents\deepseek-harness\default-workspace\gongji-4090-48g
.\scripts\deploy-image.ps1 -Token ghp_xxxxxxxxxxxx -Flavor slim
```

脚本依次做五件事，中间任何一步失败就停在那一步并打印原因：

1. `GET /user` 验 token，读 `X-OAuth-Scopes` 响应头，缺 `repo` / `workflow` 会直接告诉你
2. 建或复用同名 public 仓库
3. `git push https://x-access-token:$Token@github.com/... HEAD:main`
4. `POST .../actions/workflows/build-image.yml/dispatches` 触发构建
5. 每 30 秒轮询 `actions/runs`，最多等 2 小时，最后打印镜像地址

跑完输出：

```
镜像地址（填到平台）：
  ghcr.io/<owner>/gongji-4090-48g:slim
```

**token 怎么来**：GitHub → 头像 → Settings → Developer settings →
Personal access tokens → **Tokens (classic)** → Generate new token (classic)
→ 勾 `repo` 和 `workflow` → 复制（只显示一次）。

> `-DryRun` 只打印计划，不碰 GitHub。
> token 只在 push 那一次命令里出现，**不会写进 `.git/config`**，也不会进任何文件。
> 想要 full 版（TTS 全家桶，~22 GB）就 `-Flavor full`，两个都要 `-Flavor both`。

### 2.2 手动版（不想让脚本碰你的账号）

1. GitHub 网页 **New repository** → 名字 `gongji-4090-48g` → **Public** → 不勾任何初始化文件
2. 本地：

```bash
cd C:\Users\zhang\Documents\deepseek-harness\default-workspace\gongji-4090-48g
git remote add origin https://github.com/<你的账号>/gongji-4090-48g.git
git push -u origin main
```

3. 仓库页 **Actions** → 左侧 `build-image` → **Run workflow** → `flavor` 选 `slim` → Run

### 2.3 平台里填

弹性部署 → 新建 → **自定义服务** → 镜像地址填 `ghcr.io/<owner>/gongji-4090-48g:slim`
→ 端口 `8188` → 机型 `4090-48G` → 启动命令 `bash /root/scripts/boot.sh`。

镜像里的脚本在 `/root/scripts/`，项目在 `/root/gongji-4090-48g/`，两个路径都能用。

### 2.4 想换成 Docker Hub / 自己的 registry

workflow 里预留了开关：仓库 **Settings → Variables** 加三个 variable

| Variable | Value |
|---|---|
| `REGISTRY` | `docker.io` |
| `REGISTRY_NAMESPACE` | 你的 Docker Hub 用户名（小写） |
| `REGISTRY_USER` | 同上 |

再加一个 secret `REGISTRY_PASSWORD`（Docker Hub → Account settings →
Personal access tokens，权限 Read & Write）。不设这些变量时默认就是 ghcr，
一个 secret 都不用配。

---

## 3. 路线 B：GitHub Actions → 共绩 Harbor

和 A 只差 secret 的值（workflow 文件完全一样）：

| Name | Value |
|---|---|
| `REGISTRY` | `harbor.suanleme.cn` |
| `REGISTRY_NAMESPACE` | 控制台「镜像仓库」左侧的项目名 |
| `REGISTRY_USER` | 「镜像仓库 → 访问凭证」的用户名 |
| `REGISTRY_PASSWORD` | 同一处的密码 |

> Harbor 的凭证和平台登录账号**不互通** —— 是单独生成的一对。
> 镜像地址变成 `harbor.suanleme.cn/<项目>/gongji-4090-48g:slim`。
> 平台拉 Harbor 用 `harborpull.suanleme.cn` 这个 pull 专用域，填地址时不用改，平台自己转。

---

## 4. 路线 C：借一台有 Docker 的机器

```bash
git clone <你的仓库> && cd gongji-4090-48g

# slim（推荐，~9 GB）
docker build -t <hub-user>/gongji-4090-48g:slim .

# full（TTS 全家桶，~22 GB）
docker build --build-arg SETUP_ARGS= -t <hub-user>/gongji-4090-48g:full .

docker login
docker push <hub-user>/gongji-4090-48g:slim
```

必须是 x86_64 机器（`uname -m` = `x86_64`）。Apple Silicon 上要
`--platform linux/amd64`，会慢 5–10 倍。

---

## 5. 镜像里到底装了什么

**没有模型权重。** 权重几十上百 GB，塞不进 80 GB 系统盘，由 `fetch_models.sh` 在实例里下。

### slim（`SETUP_ARGS=--min`，约 9 GB）

| 组件 | 用途 | 位置 |
|---|---|---|
| ComfyUI + 自定义节点 | 出图/出片主界面 | `:8188` |
| **VoxCPM2** 2B | 因幡巡日语克隆主力，48 kHz | `:9883` |
| Qwen3-TTS 1.7B | 10 语种备胎 | `:9880` |
| faster-whisper large-v3 | 字幕/对轴 | 脚本调用 |

> VoxCPM2 在 `setup_env.sh` 里被放在 `--min` 判断**之外** —— 它是主力，不是可选件。
> Dockerfile 末尾还有一道独立自检 `test -x /root/venvs/vox/bin/python`，装不上就让
> build 失败，不留残废镜像。

### full（`SETUP_ARGS=` 传空，约 22 GB）

slim 的全部 + IndexTTS-2.5（中文情感控制）+ MegaTTS3 + GPT-SoVITS + Ming-3.0-tts
（`:9881`）+ VITS/MoeGoe（`:9882`，因幡巡成品声库）。

**大多数情况 slim 就够。** full 的价值只在"想横向对比几个 TTS 谁配因幡巡更像"。

### 权重拉取对照

| 做什么 | 命令 | 体积 |
|---|---|---|
| 图像两代主力 | `fetch_models.sh --tier image` | ~28 GB |
| 视频（H3 + LTX + Wan） | `--tier video` | ~120 GB |
| 配音全套 | `--tier voice` | ~31 GB |
| 只 H3 | `--tier h3` | ~39 GB |
| 只 VoxCPM2 | `--tier vox` | ~5 GB |

---

## 6. 建成之后验什么

```bash
bash /root/scripts/doctor.sh          # 环境自检

# VoxCPM2 活着？（未加载模型时 loaded=false 是正常的，懒加载）
curl -s localhost:9883/health | jq .

# 真出一句日语，确认 48 kHz
curl -s -X POST localhost:9883/clone \
  -H 'Content-Type: application/json' \
  -d '{"text":"こんにちは、因幡めぐるです。","reference_wav_path":"/root/data/voice-prompts/meguru_ref.wav"}' \
  -o /root/data/output/test_vox.wav
ffprobe -v error -show_entries stream=sample_rate,channels -of csv=p=0 /root/data/output/test_vox.wav
# 期望：48000,1
```

ComfyUI 那边：打开 `http://<公网地址>/` → 拖入 `workflows/h3_t2va.json` → 检查
`Load Diffusion Model` 指向的 `minimax_h3_fl2va_pruned_int8_convrot.safetensors`
和 `CLIPLoader` 指向的 `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` 都能在下拉里选到
（选不到说明 `extra_model_paths.yaml` 没生效，看 boot.sh 第 2 步的日志）。

---

## 7. 已经踩过的坑

**`hf.co` 直连不通。** 镜像里 `HF_ENDPOINT=https://hf-mirror.com` 已设死，
`fetch_models.sh` 也只走 hf-mirror。不要改成官方域名，会 21 秒超时后失败。

**两个官方权重仓是 gated，匿名下会 403。** 2026-10-22 逐个 URL 实测：
`black-forest-labs/flux-3-image-klein-comfy` 与 `Lightricks/LTX-2.5` 都是 `gated=auto`，
不带 token 一律 403。脚本已默认改走等价的非 gated 镜像仓 ——
`ml-resources/flux-3-image-klein-comfy`（36 文件，逐项字节一致）与
`comfyicu/LTX-2.5`（17 文件，逐项字节一致），两者 `gated=False`、匿名 206。
要切回官方仓就 `FLUX3_REPO=... HF_TOKEN=hf_xxx bash fetch_models.sh --tier flux3k`
（LTX 用 `LTX_REPO=...`）。**别在实例里现查现改**，这些路径是逐字节核过的。

**H3 权重版本名不能靠猜。** 实际文件名是
`minimax_h3_fl2va_pruned_int8_convrot.safetensors`（20.97 GB），
文本编码器是 `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`（15.69 GB）。
文档里凡是写 `umt5` 的都是旧稿，已经改掉了。

**`SETUP_ARGS` 必须参与 cache key。** workflow 里 `cache-from: type=gha,scope=<flavor>`
的 scope 就是这么来的 —— 不加的话 slim 的 layer 会被 full 复用，装出个半截环境。

**GitHub Actions 的 runner 只有 ~14 GB 空闲盘。** workflow 里那段 `Free disk space`
删掉 dotnet/android/ghc 能腾出 ~30 GB。删掉它，full 会在装到第六套 torch 时
`No space left on device`。

**别在云主机里 build。** 共绩容器禁 DinD，`docker` 命令根本不存在。

**Windows 上不锁换行符，镜像会 build 失败。** 本机 `core.autocrlf=true`，脚本
checkout 成 CRLF 之后 `bash scripts/setup_env.sh` 报 `\r: command not found`。
`.gitattributes` 里已经把 `*.sh` / `Dockerfile` 全部钉成 `eol=lf` 了，别删它。
自查用 `git ls-files --eol`，看 index 列是不是 `i/lf`。

**ghcr 的包默认是 private。** 平台匿名拉不动，会报 `unauthorized`。
workflow 最后一步 `Make ghcr package public` 就是用 API 把它改成 public，
`continue-on-error: true` 是怕组织账号的权限策略拦下来 —— 真被拦了就去
GitHub 包页面手动点一次 **Package settings → Change visibility → Public**。

---

## 8. 一句话

先用 §1 跑通片子，再用 §2 把环境固化。镜像只解决"每次新实例省 20 分钟"，
不解决"模型选对没选对" —— 后者看 `docs/frontier-2026-10-22.md`。
