# 因幡巡的声音：权重现状与语料来源

一句话结论：**已经有权重，不需要采集音频就能出声**。三份公开 VITS 权重可直接下载、
零训练推理，`sid` 映射都已核实。下面是实查结果，以及"想要更好音质时"的语料路线。

---

## 1. 现成权重（可直接用，无需任何参考音频）

| 仓库 | 文件 | 体积 | 结构 | 因幡巡 sid | 许可 |
|---|---|---|---|---|---|
| `Redmonm/SanobaWitch` | `model.pth` + `config.json` | 158,902,940 B + 2,248 B | 原版 VITS（MoeGoe 直读） | **1** | apache-2.0 |
| ~~`skytnt/moe-tts`~~ | ~~`saved_model/0/model.pth` + `config.json`~~ | ~~476,620,221 B + 1,260 B~~ | **2026-10-22 实测仓库已空（files=0，404），不可用** | ~~1~~ | 未标 license，作者声明禁商用 |
| `chinoll/ACGTTS` | `new/acg_base/jp_1196000.pth` | 159,103,181 B | 原版 VITS，**仓库内无 config.json** | **2** | CC-BY-NC-SA-4.0 |

### 首选 `Redmonm/SanobaWitch` 的理由

它的 `config.json` 是 MoeGoe 生态的原生格式，`text_cleaners` 直接写着
`["zh_ja_mixture_cleaners"]`——这是 MoeGoe 作者写的日中混合 cleaner，说明权重就是拿
MoeGoe 那套工具链训的，加载不会卡在架构或符号表上。

config 关键字段（照抄，便于校对）：

```
data.text_cleaners  = ["zh_ja_mixture_cleaners"]
data.sampling_rate  = 22050
data.n_speakers     = 6
data.add_blank      = true
model.inter_channels = 192
model.filter_channels = 768
model.n_heads = 2, n_layers = 6
model.upsample_rates = [8,8,2,2]
model.gin_channels = 256
speakers = {"宁宁":0, "因幡巡":1, "紬":2, "憧子":3, "和奏":4, "七绪":5}
```

`symbols` 是 MoeGoe 标准表（含 `ʃ tʃ ts ɯ ɹ ə ħ ʲ ʰ` 这些 IPA 符号），
和 MoeGoe `text/symbols.py` 完全一致。

### 装与跑

```bash
bash scripts/fetch_models.sh --tier vits     # 三份全下，约 780 MB
vits                                          # 起服务，:9882
curl :9882/speakers                           # 看 sid 表
curl -X POST :9882/tts -H 'Content-Type: application/json' \
  -d '{"text":"今天的视频，就由我来解说吧！","speaker":"因幡巡","speed":1.0}' \
  -o line001.wav
```

MoeGoe 会从 `$MEGOE_DIR`（默认 `/root/src/MoeGoe`）导入，`setup_env.sh` 已经 clone 好
并建了独立的 `vits` venv（Python 3.10；它的 cleaner 依赖 jieba/pypinyin/jaconv/pyopenjtalk，
和 ComfyUI 的依赖树冲突，必须隔离）。

### 音质预期

这是 2022 年代的 22 kHz VITS。**能听出是那个角色，但达不到现代 TTS 的自然度**：
长句韵律偏平、气声和情绪细节几乎没有。做旁白解说够用，做角色台词就露怯。
要更好的，看第 2 节。

---

## 2. 想要更好音质的两条路

### 路 A：零样本克隆（5–10 秒参考音频，5 分钟出结果）

用 Ming-3.0-tts（`vits` 之外的 :9881 服务）或 Qwen3-TTS（:9880）。
**不需要语料库，一段干净人声就够**。参考音频来源：

- 游戏里截一段因幡巡的台词（最直接）
- B 站已有的 AI 因幡巡翻唱视频，抽音轨（`ffmpeg -i x.mp4 -vn -ar 44100 -ac 1 ref.wav`）
- 上面第 1 节那份 VITS 合成的音频——音色对，虽然有机器味，但作为**音色锚点**够用

### 路 B：GPT-SoVITS 微调（30 分钟语料，质量上限）

要 1:1 复刻，就得有语料。两个来源：

---

## 3. 语料来源（实查，2026-10-21）

### 3.1 现成公开数据集

| 数据集 | 规模 | 许可 | 结构 | 可用性 |
|---|---|---|---|---|
| `NandemoGHS/Japanese-Eroge-Voice-V2` | **1,033,142 条 / 2,657 小时** | **MIT** | 520 个 parquet，每个约 460 MB（总 240 GB） | 字段齐全但**匿名化** |
| `NandemoGHS/Japanese-Eroge-Voice` | 409.33 小时 | MIT | WebDataset，每 tar 1024 条，单个约 369 MB | 同上，规模小 6 倍 |
| `litagin/Galgame_Speech_ASR_16kHz` | — | GPL-3.0 | parquet + ASR 标注 | 有 `num_samples_of_tar.csv` 可先查分布 |
| `HisAtri/YuzuSoft-temporary` | — | — | `S.B.Sounds.7z` / `丛雨（部分）.7z` / `芳乃_部分.7z` | **千恋万花**，不是魔女的夜宴，无因幡巡 |

V2 的字段：

```
source_dataset  string   游戏标识（哈希）
scene_id        string   场景标识（哈希）
char_id         string   角色标识（哈希）   ← 关键
audio           audio    音频
text            string   台词文本
text_source     string   original（从游戏剧本解析）| asr（anime-whisper 转写）
duration        float64
sampling_rate   int64
```

**匿名化是唯一障碍**：`source_dataset` 和 `char_id` 都做了哈希，README 明说
"difficult to reconstruct the original works in their entirety"，目的是规避日本著作权法。
所以不能直接 `where game='サノバウィッチ' and char='因幡めぐる'`。

### 3.2 反查 char_id 的办法

哈希去不掉，但 `text` 是明文。做法：

1. 拿几句**只有因幡巡会说的台词**（从游戏攻略站/剧本/wiki 抄，或从第 1 节的 VITS
   合成验证过的台词），到数据集里做文本匹配；
2. 命中的记录里统计 `char_id` 分布，出现最多的那个就是她；
3. 再按该 `char_id` 拉全部记录。

```python
# 流式扫描，不落全量盘；命中就停
from datasets import load_dataset
ds = load_dataset("NandemoGHS/Japanese-Eroge-Voice-V2", split="train", streaming=True)
KEY = ["えへへ", "そんなことないですよ"]        # 换成确认属于她的台词片段
hits = {}
for row in ds:
    if any(k in row["text"] for k in KEY):
        hits[row["char_id"]] = hits.get(row["char_id"], 0) + 1
print(sorted(hits.items(), key=lambda x: -x[1])[:5])
```

成本提醒：全量流式扫一遍 240 GB 很慢。实际做法是先下 3–5 个 shard（1.5–2.3 GB）
做粗筛，命中率不够再加。或者直接走 3.3 那条路——更快更干净。

### 3.3 自己从游戏里提取（最干净，推荐）

魔女的夜宴是柚子社的 **Kirikiri 引擎**，语音资源在 `voice.xp3` 里，解包是成熟流程：

```bash
# 1) 装解包器（Windows 侧）
#    KrkrExtract：https://github.com/xmoezzz/KrkrExtract
#    或 GARbro（图形界面，支持 xp3 直接浏览/导出）

# 2) 解出 voice.xp3，得到按场景编号的 .ogg/.wav
#    因幡巡的语音文件名通常带角色前缀（如 mgr_xxxx.ogg）

# 3) 按角色筛 + 转 44.1k 单声道 + 静音切分
ffmpeg -i in.ogg -ar 44100 -ac 1 out.wav

# 4) 台词对齐：pjh456/KrkrDataLoader 能按剧本把文本和语音对上
```

这条路的好处：语料干净（游戏原盘无损）、台词文本现成、角色边界清晰，
30 分钟高质量语料大概对应 300–500 句。缺点是要有正版游戏。

---

## 4. 路线建议

| 你的情况 | 走哪条 |
|---|---|
| 现在就想听个响，验证像不像 | **第 1 节现成权重**，`fetch_models.sh --tier vits`，2 分钟 |
| 做旁白解说，音色对就行 | **路 A 零样本克隆**，截 8 秒参考音频，5 分钟 |
| 要做角色台词、长期出片 | **路 B + 3.3 游戏提取**，一次性投入，之后质量封顶 |
| 不想买游戏、能接受匿名数据 | **路 B + 3.2 反查 char_id**，先下 3 个 shard 试命中率 |

三条路不冲突：先用第 1 节确认音色方向对不对，再决定要不要往路 B 投入。
