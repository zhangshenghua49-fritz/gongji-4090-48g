#!/usr/bin/env python3
"""novel2storyboard.py — 小说正文 → 分镜表 + MiniMax-H3 提示词骨架

只做机械工作：切场景、分镜、算时长、编号、导出骨架。
画面提示词（prompt 列）留空，由人/上层模型填写后 JSONL 直接喂给 H3 工作流。

用法:
  python scripts/novel2storyboard.py 正文.txt -o out/
  python scripts/novel2storyboard.py 正文.txt --cps 4.2 --max-shot 8 --min-shot 2

时长口径:
  中文旁白约 4.2~4.8 字/秒。默认 4.5。
  H3 的帧数网格是 17k+5（24fps），脚本会按此把秒数对齐到合法 length。

切镜规则:
  只在「引号配平 + 句末标点」处断开，绝不把一句台词切成两半。

输出:
  <out>/storyboard.csv   人读分镜表（Excel 可直接开）
  <out>/storyboard.jsonl 机读，每行一个镜头，含 H3 的 length 字段
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

# 章节标题
CHAPTER = re.compile(r"^\s*第\s*[0-9一二三四五六七八九十百千两]+\s*[章节回卷]\b")
# 场景分隔标记
SCENE_BREAK = re.compile(r"^\s*(\*{3,}|-{3,}|_{3,}|※+|◆+|◇+)\s*$")
# 地点/时间提示行：括号独占一行
SCENE_MARK = re.compile(r"^\s*[（(\[【][^）)\]】]{1,30}[）)\]】]\s*$")
# 对话行
DIALOGUE = re.compile(r"[「『“\"]")
# 句末标点（可作切点）
SENT_END = "。！？…"
# 引号对
QUOTE_OPEN = "「『“‘（(《【["
QUOTE_CLOSE = "」』”’）)）》】]"


def force_utf8_stdout() -> None:
    """Windows 控制台默认 GBK，中文会乱码。"""
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass


def norm_lines(text: str) -> list[str]:
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\u3000", " ")
    return [ln.rstrip() for ln in text.split("\n")]


def split_scenes(lines: list[str]) -> list[tuple[str, list[str]]]:
    """返回 [(场景名, [块...]), ...]。场景名取最近的括号提示行。"""
    scenes: list[tuple[str, list[str]]] = []
    cur: list[str] = []
    name = ""

    def flush() -> None:
        nonlocal cur, name
        if cur:
            scenes.append((name, cur))
        cur = []

    for ln in lines:
        if SCENE_BREAK.match(ln):
            flush()
            continue
        if SCENE_MARK.match(ln):
            flush()
            name = ln.strip()
            continue
        if not ln.strip():
            if cur and cur[-1] != "":
                cur.append("")
            continue
        cur.append(ln.strip())
    flush()
    return scenes


def split_paras(blocks: list[str]) -> list[str]:
    out: list[str] = []
    buf: list[str] = []
    for b in blocks:
        if b == "":
            if buf:
                out.append("".join(buf))
                buf = []
            continue
        buf.append(b)
    if buf:
        out.append("".join(buf))
    return out


def safe_cut_points(text: str) -> list[int]:
    """返回可安全断开的字符下标（引号配平且是句末标点之后）。"""
    pts: list[int] = []
    depth = 0
    for i, ch in enumerate(text):
        if ch in QUOTE_OPEN:
            depth += 1
        elif ch in QUOTE_CLOSE:
            depth = max(0, depth - 1)
        elif depth == 0 and ch in SENT_END:
            pts.append(i + 1)
    if not pts or pts[-1] != len(text):
        pts.append(len(text))
    return pts


def split_long(para: str, cps: float, max_shot: float) -> list[str]:
    """长段落按安全切点断开，单镜不超过 max_shot 秒。"""
    if len(para) / cps <= max_shot:
        return [para]
    pts = safe_cut_points(para)
    shots: list[str] = []
    start = 0
    prev = 0
    for p in pts:
        if (p - start) / cps > max_shot:
            # 超时了，退回上一个安全切点断开；若上一句本身就超长，只能切在 p
            cut = prev if prev > start else p
            shots.append(para[start:cut])
            start = cut
        prev = p
    if start < len(para):
        shots.append(para[start:])
    return [s for s in shots if s]


def snap_length(seconds: float, fps: int = 24) -> int:
    """把秒数对齐到 H3 合法的 length（17k+5，训练区间 124~362）。"""
    target = max(5, round(seconds * fps))
    k = max(0, round((target - 5) / 17))
    return 17 * k + 5


def main() -> int:
    force_utf8_stdout()
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="小说正文 txt（UTF-8）")
    ap.add_argument("-o", "--out", default="out", help="输出目录")
    ap.add_argument("--cps", type=float, default=4.5, help="中文朗读速度，字/秒（默认 4.5）")
    ap.add_argument("--max-shot", type=float, default=8.0, help="单镜最长秒数（默认 8）")
    ap.add_argument("--min-shot", type=float, default=2.0, help="单镜最短秒数，过短合并（默认 2）")
    ap.add_argument("--fps", type=int, default=24, help="帧率（默认 24，H3 固定）")
    args = ap.parse_args()

    src = Path(args.src)
    if not src.is_file():
        print(f"[err] 找不到 {src}", file=sys.stderr)
        return 2
    text = src.read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        print("[err] 文本为空", file=sys.stderr)
        return 2

    rows: list[dict] = []
    shot = 0

    def add(scene: int, sname: str, piece: str, kind: str) -> None:
        nonlocal shot
        shot += 1
        secs = round(len(piece) / args.cps, 2)
        rows.append({
            "shot": shot, "scene": scene, "scene_name": sname, "kind": kind,
            "chars": len(piece), "seconds": secs,
            "length": snap_length(secs, args.fps),
            "text": piece, "prompt": "",
        })

    for si, (sname, blocks) in enumerate(split_scenes(norm_lines(text)), 1):
        sname = sname or f"Scene-{si}"
        pending = ""
        for para in split_paras(blocks):
            # 章节标题单独成镜，不进正文
            if CHAPTER.match(para):
                add(si, sname, para.strip(), "title")
                continue
            for piece in split_long(para, args.cps, args.max_shot):
                if pending:
                    piece = pending + piece
                    pending = ""
                if len(piece) / args.cps < args.min_shot:
                    pending = piece
                    continue
                add(si, sname, piece, "dialogue" if DIALOGUE.search(piece) else "narration")
        if pending:
            add(si, sname, pending, "dialogue" if DIALOGUE.search(pending) else "narration")

    if not rows:
        print("[err] 没切出任何镜头，检查文本编码或标点", file=sys.stderr)
        return 2

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    csv_path = out / "storyboard.csv"
    jsonl_path = out / "storyboard.jsonl"

    with csv_path.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    with jsonl_path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    total = sum(r["seconds"] for r in rows)
    print(f"[ok] {len({r['scene'] for r in rows})} 个场景 -> {len(rows)} 个镜头 / 总时长 {total:.1f}s")
    print(f"     {csv_path}")
    print(f"     {jsonl_path}")
    print(f"[next] 填 prompt 列后: bash scripts/run_wf.sh workflows/h3_t2va.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
