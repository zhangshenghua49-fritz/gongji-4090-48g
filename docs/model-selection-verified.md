# 选型核验：这套东西到底是不是开源最强（2026-10-21 实测）

> **⚠️ 2026-10-22 复核**：本文有三处需要更正，详见 [`frontier-2026-10-22.md`](frontier-2026-10-22.md)。
> 一句话：**视频（H3）成立且更强**（I2V 榜 1140 是总榜第一）；**图像 Z-Image-Turbo 那段的说法是错的**（它在榜，936 分排 71/105，不是"不在榜上"）；**声音这格要再换一次** —— 因幡巡日语克隆的正解是 **VoxCPM2**（48kHz / Apache-2.0 / 日语 SIM 0.825），不是 IndexTTS2；Ming 保留为中文旁白。
> 下文保留 10-21 原貌作为记录，被更正处以 `【10-22 更正】` 标注。

你问「我找的模型是最强的吗」。这篇是拿第三方盲测榜单逐类核对的结论，不是我说了算。

榜单来源全部是 Artificial Analysis（AA）的 pairwise 人类盲投 Elo，不是厂商自评。
三条榜的更新时间都在 2026-10，与本文同日。

---

## 一句话结论

| 类别 | 我装的 | 榜单名次 | 判定 |
|---|---|---|---|
| 视频生成 | MiniMax **H3**（768p） | **开源第 1**，总榜第 5，Elo 1158 | ✅ 已是天花板 |
| 图像生成 | **Qwen-Image-2.1** | **开源第 1**，总榜并列第 21，Elo 1042 | ✅ 已是天花板 |
| 声音克隆 TTS | 原方案 Qwen3-TTS | **未进榜** | ⚠️ 已补 **Ming-3.0-tts**（开源第 1，Elo 1066） |

**视频和图像没有更好的开源选择可换**。TTS 这一格原先确实不是最强，已经补上了。

---

## 1. 视频：H3 是开源断层第一

[AA-Video-T2V v2.1](https://artificialanalysis.ai/video/leaderboard/text-to-video)，榜单自己的 FAQ 原话：

> **Which is the best open weights model on AA-Video-T2V v2.1?**
> MiniMax H3 (768p) currently leads among open weights models with an Elo score of **1158**,
> followed by LTX-2.5 Fast (Elo 951) and LTX-2.5 Pro (Elo 948).

| 名次 | 模型 | Elo | 开源权重 |
|---|---|---|---|
| 1 | Wan 3.0 | 1173 | ❌ 只有 API，$12/min |
| 2 | Utopai X | 1166 | ❌ |
| 3 | Dreamina Seedance 2.5 | 1159 | ❌ |
| 4 | FLUX 3 Max | 1159 | ❌ |
| **5** | **MiniMax H3 (768p)** | **1158** | ✅ HuggingFace |
| 6 | MiniMax H3 Max | 1156 | ❌（第三方后训练，见下） |
| 23 | LTX-2.5 Fast | 951 | ✅ |
| 24 | LTX-2.5 Pro | 948 | ✅ |

**H3 领先第二名开源模型（LTX-2.5 Fast）整整 209 分**，这不是一个量级的差距。
总榜前四名全是闭源 API，跑不了本地。

【10-22 补充】**上面这张是 T2V（文生视频）榜。在 I2V（图生视频）榜上 H3 更强 —— 1140 分是总榜第 1**，压过 FLUX 3 Max (720p) 1138、Dreamina Seedance 2.5 1138、Gemini Omni Flash 1.1 1132、Wan 3.0 1127、H3 Max 1125。图生视频才是你做分镜动画的主路径，所以这条比 T2V 的第 5 名更有分量。

两个容易踩的坑，已经核实：

- **Wan 3.0 没有开源权重**。官方 GitHub 组织只有 2.1 / 2.2，`AlibabaCloud-Official/Wan3.0` 仓库截至 2026-09 只有 README 和 Apache 2.0 许可证，**没有任何模型卡和权重文件**，ComfyUI 集成也只是调托管 API。装不了，等官方放权重再换。
- **H3 Max 不是官方版，分数还更低**。它是有人拿 MiniMax 放出的 H3 权重做后训练、重建推理链路的成品，Elo 1156 **低于**原版 H3 的 1158。所以我们装的 `MiniMaxAI/MiniMax-H3` 就是最优解，不用追 Max。

---

## 2. 图像：Qwen-Image-2.1 是开源第一

[AA-Image-T2I v2.1](https://artificialanalysis.ai/image/leaderboard/text-to-image)：

| 名次 | 模型 | Elo | 开源权重 |
|---|---|---|---|
| 1 | GPT Image 2.5 Sunburst | 1222 | ❌ |
| 4 | Nano Banana 2.1 | 1176 | ❌ |
| 17 | Qwen-Image-3.0-Pro | 1095 | ❌ 只有 API |
| 19 | Qwen-Image-2.1-Pro | 1056 | ❌ 只有 API |
| **21** | **Qwen-Image-2.1** | **1042** | ✅ HuggingFace |
| 22 | Fibo 2.0-dev | 1039 | ✅ |
| 31 | Ideogram 4.0 | 1026 | ✅ |
| 45 | FLUX.2 [dev] | 1000（锚点） | ✅ |

带 HuggingFace 链接的模型里，Qwen-Image-2.1（1042）就是最高分，比第二名 Fibo 2.0-dev 高 3 分，
比 FLUX.2-dev 高 42 分。

**Qwen-Image-3.0 / 3.0-Pro 更强但只走 API**（AA 标注 `No API available` 的是 2.1，3.0 系列反而有定价
无权重），所以本地能跑的上限就是 2.1。

【10-22 更正】**"Z-Image-Turbo 不在 AA 榜上"这句话是错的。** 它在榜，**936 分、总榜第 71/105**，全类目排在 897–967、rank 54–84 之间。它不是"没参评质量档"，是"质量明显差一档"。8 步蒸馏的速度优势是真的（6B / 8 步），但**没有资格当"图像主力之一"，只能做草图与动态分镜预览**。

真正该补进主力候选的是 **FLUX 3 image klein**（5.6B / bf16 20.32GB / 10 参考图 / `flux-kommunity` 可商用），上一轮完全漏了它。详见 `frontier-2026-10-22.md` 第 2 节。

分工（降级后）：**Z-Image 只出草图和批量试镜，不上正片；Qwen-Image-2.1 出定稿。**

---

## 3. 声音：这一格原先错了，已修正

[AA Controlled Voice Leaderboard](https://artificialanalysis.ai/text-to-speech/leaderboard/controlled-voice)
测的是**同一批 8 个克隆音**（4 US + 4 UK）下的合成质量 —— 正好对应你要的「克隆音色做旁白」。

| 名次 | 模型 | Elo | 开源权重 |
|---|---|---|---|
| 1 | HeyGen Voice | 1195 | ❌ |
| 2 | Qwen-Audio-3.1-TTS-Plus | 1184 | ❌ 只有 API |
| 3 | Eleven v4 Turbo | 1156 | ❌ |
| **12** | **Ming-3.0-tts** | **1066** | ✅ MIT |
| **16** | **Fish Audio Drama 3 Preview** | **1058** | ✅ |
| 24 | Breeze TTS 2 | 1017 | ✅ |
| 28 | Voxtral 4B TTS | 1004 | ✅ |
| 29 | Fish Audio S2 Pro | 1001 | ✅ |
| 36 | Higgs Audio V3 | 957 | ✅ |
| 40 | Chatterbox | 930 | ✅ |
| 44 | XTTS v2 | 825 | ✅ |
| 45 | OpenVoice v2 | 806 | ✅ |

**开源第一是 Ming-3.0-tts（1066），第二是 Fish Audio Drama 3（1058）。**
原先选的 Qwen3-TTS 没有出现在这张榜上。

### 为什么换成 Ming-3.0-tts

不只是分数。逐条对着你的需求比：

| 需求 | Ming-3.0-tts | Qwen3-TTS |
|---|---|---|
| 日语（因幡巡是日语角色） | ✅ 显式 `language_id="ja"` | ✅ 10 语言 |
| 中文旁白 | ✅ 母语级，100+ 内置中文音色 | ✅ |
| 零样本克隆 | ✅ 短参考音频 | ✅ |
| 自然语言造音色 | ✅ `VOICE_DESIGN` | ✅ `generate_voice_design` |
| 采样率 | **44.1 kHz** | 24 kHz |
| 情感/语速/音高/音量 | ✅ 结构化 `controls` | 部分 |
| 副语言标签 | ✅ 14 个（呼吸/叹气/笑/犹豫/惊讶…） | ❌ |
| 方言 | ✅ 四川话 / 粤语 | ❌ |
| 许可证 | **MIT** | Apache 2.0 |
| 体积 | 0.5B ≈ 1.1 GB | 1.7B × 3 ≈ 12 GB |

44.1 kHz 对视频旁白是硬指标 —— 直接进剪辑软件不用重采样。
14 个副语言标签在解说里能做出「叹气后再开口」这种细节，Qwen3-TTS 没有。

**Drama 3 更高的分在「Provider Voice」榜（1248，开源最高），但那是各家自带音色的赛道，
不是克隆赛道**；而且它 39.6 GB / license `other`，做旁白不划算。不装。

### 【10-22 更正】因幡巡这一格：Ming 不是最优，VoxCPM2 才是

Ming 的 1066 是**英文克隆综合分**。日语音色相似度（克隆因幡めぐる 的唯一关键指标）在两张独立日语表里 Ming 都是 0.765/0.780，落后一档：

| 模型 | 体积 | 采样率 | 日语 SIM | 日语 CER | license |
|---|---|---|---|---|---|
| **VoxCPM2**（OpenBMB） | 4.62 GB | **48 kHz** | **0.825** | 4.358 | **Apache-2.0 可商用** |
| dots.tts | 4.81 GB | 48 kHz | **0.838** | 7.16（最差） | Apache-2.0 |
| FireRedTTS3 | 19.35 GB | — | 0.825 | 3.60 | Apache-2.0 但白盒克隆限学术 |
| Fish Audio S2 Pro | 10.25 GB | — | 0.755 | **2.76**（最好） | Research，商用另签 |
| **Ming-3.0-tts-0.5B** | 3.00 GB | 44.1 kHz | 0.765 | 3.765 | **MIT** |
| IndexTTS-2.5 | 5.49 GB | **22.05 kHz** | — | — | bilibili 协议 |

**结论修正**：
- **因幡巡（日语少女音）→ VoxCPM2 `hifi_clone`**（48kHz 母带 / Apache-2.0 / 4.62GB / RTF~0.3@4090）。参考音给 10–20s 干净单句日文，同一段音同时喂 `reference_wav_path` 与 `prompt_wav_path`，相似度最高。
- **中文旁白 → Ming-3.0-tts-0.5B 不变**（MIT / 44.1kHz / zh 最强，且是唯一用 `language_id` 逐句显式指定语种的，中旁白+日台词混排确定性最高）。
- **IndexTTS2 降级**：仓库 release 只有 v1.5.0（2025-09）/ v2.0.0 / **v2.5.0（2026-08-13）**，没有 `0.3.0` 这个 tag —— 平台镜像 `index-tts:0.3.0` 疑似初代。且 2.5 输出只有 **22.05 kHz**，做 48k 母版要重采样。
- **兜底 A/B**：日语咬字不满意再跑 Fish S2 Pro（10.25GB，日语 CER 2.76 最好）。


- **Ming-3.0-tts**（:9881）= 主力。中文/日语旁白、克隆、情感。
- **Qwen3-TTS**（:9880）= 备用。语言覆盖更广（10 种），且它的
  `Voice Design → create_voice_clone_prompt` 链路能把一句话生成的音色锁死复用。
- **GPT-SoVITS** = 质量上限。真要 1:1 复刻因幡巡，微调 20–30 分钟语料仍然是最像的。

三个服务独立 venv、独立进程，谁都不干扰谁。

---

## 4. 显存账：这些全都装得下

4090 48G 上同时挂不现实，但同时**装**没问题，按需起：

| 项目 | 显存 | 备注 |
|---|---|---|
| H3 fl2va pruned_int8 + nvfp4 TE 全常驻 | **42.0 GB** | 768p 带声实测窗口 **32–36 GB**；「27.8GiB」只对应 0.4MP，勿套用 |
| LTX-2.5 22B int8 | **38.7 GB** | int8 transformer 21.50 + TE int8 15.37 + vae 1.47 + audio 0.36 |
| Qwen-Image-2.1 bf16 | **33.1 GB** | 2K 需 ~56GiB ⇒ 锁 1024–1536 或走 GGUF Q8_0（7.64GB） |
| FLUX 3 klein bf16 | **20.3 GB** | 10 参考图，48G 上最舒服的前沿档 |
| Qwen-Image-2.1 【10-22 更正】 | ~~24 GB~~ 33.1 GB | 上一轮低估了 text encoder（17.54GB） |
| Wan2.2 Ti2V-5B | ~12 GB | 草稿 |
| Ming-3.0-tts 0.5B | **3.0 GB** | 可以和图像同时挂着 |
| VoxCPM2 | **4.6 GB** | 【10-22 新增】因幡巡日语克隆主力 |
| IndexTTS-2.5 | **5.5 GB** | 【10-22 新增】第三顺位，22.05kHz |

结论：**做视频时 TTS 挂后台、图像和视频模型轮流上**，这是 48G 唯一合理的用法。
`/unload` 接口就是为这个留的。

---

## 5. 复核方法（你自己也能验）

```bash
# 视频
curl -s https://api.github.com/repos/Comfy-Org/workflow_templates/contents/templates \
  | grep -o '"name": "[^"]*minimax[^"]*"'
# 权重是否真存在（HTTP 200 = 有）
curl -sI https://hf-mirror.com/MiniMaxAI/MiniMax-H3/resolve/main/model_index.json | head -1

# 图像
curl -sI https://hf-mirror.com/Qwen/Qwen-Image-2.1/resolve/main/model_index.json | head -1

# Ming 权重清单
curl -s https://hf-mirror.com/api/models/inclusionAI/Ming-3.0-tts-0.5B | grep -o '"rfilename": "[^"]*"'
```

榜单会变。建议每季度重看这三个页面，看到开源第一换人了再动 `fetch_models.sh` 的 tier。

## 参考

- [AA 视频 T2V 榜](https://artificialanalysis.ai/video/leaderboard/text-to-video)
- [AA 图像 T2I 榜](https://artificialanalysis.ai/image/leaderboard/text-to-image)
- [AA 克隆音色榜](https://artificialanalysis.ai/text-to-speech/leaderboard/controlled-voice)
- [AA 自带音色榜](https://artificialanalysis.ai/text-to-speech/leaderboard/provider-voice)
- [Wan 3.0 开源状态](https://wan2-7.io/blog/wan-3-0-open-source/)
- [Ming-3.0-tts 模型卡](https://hf-mirror.com/inclusionAI/Ming-3.0-tts-0.5B)
