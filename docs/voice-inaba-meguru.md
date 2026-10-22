# 因幡巡 声库实查（2026-10-21 实测）

> 全部经过 HEAD 请求核验：`HTTP 200 + Content-Length` 对得上才写进来。
> 本机 `huggingface.co` 直连超时，所有校验走镜像 `hf-mirror.com`。
> 未抓到的，明确标「未能实测」，不猜。

## 结论先放

**权重拿得到，不用从零训。** 三份原生 VITS 权重实测可下，最大 454 MiB，含因幡巡说话人。
但它们的天花板是 2022 年的 VITS——语调平、情感弱，做短句玩梗够用，做 10 分钟长旁白机器味明显。

真正决定成片质感的分水岭只有一条：**要不要花几小时训一个 GPT-SoVITS**。语料不难拿。

## 一、可直接下载的权重（按推荐度排）

### ① Moe TTS Space — 推荐首选

七人合一 VITS（サノバウィッチ & 千恋＊万花 & RIDDLE JOKER），CjangCjengh 训练。

| 项 | 值 |
|---|---|
| 文件 | `model.pth` **476,620,221 B**（454 MiB）+ `config.json` 1,260 B |
| 主链 | `https://huggingface.co/spaces/skytnt/moe-tts/resolve/main/saved_model/0/model.pth` |
| 镜像 | `https://hf-mirror.com/spaces/skytnt/moe-tts/resolve/main/saved_model/0/model.pth` |
| speakers | `["綾地寧々","因幡めぐる","朝武芳乃","常陸茉子","ムラサメ","鞍馬小春","在原七海"]` |
| **因幡巡 sid** | **1** |
| license | Space 未挂 license 字段；作者在 TTSModels 页声明**禁商用** |
| 需自训 | 否 |

> **2026-10-22 实测：这条链已失效。** `hf-mirror.com/api/models/skytnt/moe-tts` 返回 `siblings: []`（`files=0`），
> `resolve/main/saved_model/0/model.pth` 直接 **404**。仓库是空的，不是 gated。
> `scripts/fetch_models.sh` 已把这两行删掉；因幡巡兜底改走 `Redmonm/SanobaWitch`（sid=1，apache-2.0）。
> 下表参数仅作历史记录保留。

`config.json` 实测原文参数：`japanese_cleaners` / `sampling_rate 22050` / `n_speakers 7` /
`inter_channels 192` / `filter_channels 768` / `n_heads 2` / `n_layers 6` /
`upsample_rates [8,8,2,2]` / `gin_channels 256`。

**这套参数和下面 ②③ 完全一致 → 三份权重共用同一个推理器，换文件即可 A/B。**

### ② chinoll/ACGTTS — 19 说话人日语底模

| 项 | 值 |
|---|---|
| 文件 | `new/acg_base/jp_1196000.pth` **159,103,181 B**（151.7 MiB） |
| URL | `https://hf-mirror.com/chinoll/ACGTTS/resolve/main/new/acg_base/jp_1196000.pth` |
| config | `https://hf-mirror.com/chinoll/ACGTTS/resolve/main/new/acg_base/config.json` |
| 映射 | README：**2 = 因幡巡（new）/ 1 = 因幡巡（old）** |
| license | 权重 **CC-BY-NC-SA-4.0**；代码 GPL-2.0 |
| 备选 | `old/acg_base/38000.pth`（3 人小模型，宁宁/巡/憧子），sid = 1 |

坑：ACGTTS 自带 `gen_audio.py` 要装 espeak、编 `monotonic_align`，而且对中文是
「先合成再 voice_conversion」的二次劣化路径。**别碰它的脚本**，只用它的 `.pth`。

### ③ Redmonm/SanobaWitch — 单作专用 6 人

| 项 | 值 |
|---|---|
| 文件 | `model.pth` **158,902,940 B** + `config.json` 2,248 B |
| URL | `https://hf-mirror.com/Redmonm/SanobaWitch/resolve/main/model.pth` |
| speakers | `{"宁宁":0,"因幡巡":1,"紬":2,"憧子":3,"和奏":4,"七绪":5}` |
| **因幡巡 sid** | **1** |
| 需自训 | 否 |

### ④ 原始分发页 CJangCjengh/TTSModels

README 第 1 条正是这七人合集，365-epoch 版 + 去 H 版，OneDrive 分发。
**README 顶部硬声明「严禁商用」。**

## 二、遥そら 同声带（不是巡本人，但音色同源）

| 来源 | 架构 | 说明 |
|---|---|---|
| **spow12/sbv_yoshino** | Style-Bert-VITS2 JP-Extra | 朝武芳乃（千恋＊万花），**与巡同一 CV 遥そら**。`芳乃/芳乃.safetensors` + `style_vectors.npy`，repo 合计 251,152,132 B，**cc-by-nc-nd-4.0**，README 标 research only |
| spow12/visual_novel_tts | Style-Bert-VITS2 | 16 角色合集，合计 254,335,876 B，cc-by-nc-4.0。**角色表不含サノバウィッチ** |

`sbv_yoshino` 的价值：Style-Bert-VITS2 是少数**同时给音色 + 情感/风格向量**的方案
（`style_vectors.npy` 就是情感簇），最新 release `2.7.0`（2025-08-24），有 Windows 一键包和 API server。
芳乃和巡同一个声带，音色底子一致，差别在演技——副声道、软妹语气、句尾拖音都对得上。

**如果脚本本身不需要「巡的口癖」，这条路的听感会明显优于 ①。**

## 三、确定拿不到的（省得你再找）

| 来源 | 结果 |
|---|---|
| RVC / So-VITS-SVC | HF `?search=inaba` / `?search=meguru` / `?search=sanoba` 全量翻过，**零因幡巡权重**（只有图像 LoRA、东方因幡帝、`springroll4/inaba`＝月夜见宵 LoRA）；`voice-models.com/search?q=inaba` 返回 `[]` |
| BOOTH「Sora／ソラ」RVC | 是 ひるね_RVC 自研原创音色（同店还有 RuRu/Karin/Sena），与本 CV 无关 |
| luoyily/MoeTTS | 13 人合集已逐条核对，**不含因幡巡**；仓库明令禁商用 |
| Fish Audio「美咕噜」 | 云端 S2.1 Pro 托管音色，**权重不落地**，只能走 API |
| ayousanz/Galgame_Dataset_SBV2_* | 是**语料**不是成品，且 gated（`esd.list` 实测 403） |

## 四、推理器

| 工具 | 说明 |
|---|---|
| **MoeGoe** `CjangCjengh/MoeGoe` | MIT，2.4k stars，最新 `v3.0.1`，资产 `MoeGoe.7z` |
| **MoeGoe_GUI** | 最新 `v3.0.2`，资产 `MoeGoe_GUI.exe`。双击 → 选 `.pth` + `config.json` → 下拉选 `因幡めぐる` → 输文本。**全流程唯一零命令行通路** |
| Style-Bert-VITS2 | `2.7.0`，带 API server |
| GPT-SoVITS | `v2Pro` / `v5` |

**日语输入直接写假名最稳**——`japanese_cleaners` 靠 pykakasi 转写，汉字多音会歪。

## 五、路径排序（按投入产出）

### 第一条：今晚就能出声，零训练

Moe TTS 的 `model.pth` + `config.json`，MoeGoe 加载，speaker 选 `因幡めぐる`。
454 MiB 单文件，22.05 kHz 原生 VITS。

同时把 ACGTTS `jp_1196000.pth` 和 `Redmonm/SanobaWitch` 一起下了做 A/B——三份同架构，
MoeGoe 里换文件即可对比，成本几乎为零。

**上限**：2022 年 VITS。短句够用，长旁白机器味明显。

### 第二条：要「像遥そら」而不是「像巡」

`spow12/sbv_yoshino`，Style-Bert-VITS2，带情感向量。

### 第三条：质量上限，必须自训 GPT-SoVITS

官方 README 硬指标：

> Zero-shot TTS: Input a **5-second** vocal sample
> Few-shot TTS: Fine-tune the model with just **1 minute** of training data

质量甜点在 **20–30 分钟**语料。可参照已验证配比
`MomoyamaSawa/GPT-SoVITS_KusanagiNene`（30 min 数据集 / 8 epoch → `nene30_e8_s328.pth`）。

版本选 **v2Pro 或 v5**：v5 官方说明 `Significantly improved voice similarity without SoVITS fine-tuning`，
对只有几十分钟数据的场景最划算；v3/v4 反而吃语料质量。

**语料获取**：

- 柚子社是 Kirikiri 引擎 → `voice.xp3` 用 **KrkrExtract** 解包 → 再上
  [`pjh456/KrkrDataLoader`](https://github.com/pjh456/KrkrDataLoader)（柚子社专用，按台词导 WAV/OGG 并按角色拼接），
  比手工切片省一个量级时间
- 更省事的路：直接买遥そら 的 DLsite ASMR 作品当干声语料——**纯单人、无 BGM、无音效、44.1/48 kHz**，
  省掉 UVR5 分离这一步。她 DLsite 侧销量几乎 100% 集中在ボイス/ASMR 类（[Dojilyzer 声优页](https://dojilyzer.com/voice_details/%E9%81%A5%E3%81%9D%E3%82%89/)）

训练耗时：官方没给数字。按 30 min / 8 epoch / 单卡 8–12 GB 显存的同类配置估算是**小时级**（估算，非文档口径）。

### 第四条：RVC 变声兜底

目前**没有**因幡巡 RVC 权重，要自己训（10 分钟干声起）。而且 RVC 是 SVC 不是 TTS——
需要一个「先出声」的源，等于把第一条/第三条再叠一层，误差累积。
做法：GPT-SoVITS 零样本克隆出粗糙的巡 → RVC 把音色掰正。前三条都不满意才值得投入。

## 六、遥そら 的角色面（自训取材）

纯成人向游戏 + DLsite ASMR 声优。代表作：**因幡巡**（サノバウィッチ）、朝武芳乃（千恋＊万花）、
二条院羽月（RIDDLE JOKER）、星河かぐ耶（天使☆騒々 RE-BOOT!）、宮国朱璃（千の刃濤、桃花染の皇姫）、
妃玲奈（金色ラブリッチェ）、鈴木佳奈（大図書館の羊飼い）、鷺澤有里栖（D.C.4 / D.C.5）。
