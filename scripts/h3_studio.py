#!/usr/bin/env python3
"""H3 Studio demo API client.

Submits t2v / i2v / flf2v / ref2v jobs to a running 共绩弹性部署 H3 Studio instance,
polls until finished, and downloads the produced mp4.

Why hand-rolled multipart: the platform container has no `requests`, and this file is
also used from the local Windows box where only the bundled python exists.

Env:
  H3_BASE   base URL of the deployment, e.g. https://deployment-xxxx-8001.550w.link

Usage:
  python h3_studio.py --prompt "..." [--duration 5] [--quality 0.4] [--aspect "16:9 (Widescreen)"]
  python h3_studio.py --prompt "..." --first frame.png
  python h3_studio.py --prompt "..." --first a.png --last b.png
  python h3_studio.py --list
"""

import argparse
import json
import mimetypes
import os
import sys
import time
import urllib.request
import uuid

BASE = os.environ.get("H3_BASE", "").rstrip("/")

ASPECTS = [
    "16:9 (Widescreen)",
    "9:16 (Portrait)",
    "1:1 (Square)",
    "4:3 (Standard)",
    "3:4 (Portrait)",
    "21:9 (Ultrawide)",
]

# quality -> (width, height); 0.98 is the official 768p preset
QUALITY_SIZES = [
    (0.2, "608x352"), (0.3, "736x416"), (0.4, "864x480"),
    (0.5, "960x544"), (0.6, "1056x608"), (0.7, "1152x640"),
    (0.8, "1216x672"), (0.9, "1280x736"), (0.98, "1344x768"),
]

MAX_DURATION = 15
MIN_DURATION = 5


def _require_base():
    if not BASE:
        sys.exit("H3_BASE is not set, e.g. export H3_BASE=https://deployment-xxx-8001.550w.link")


def _multipart(fields, files):
    boundary = "----h3studio" + uuid.uuid4().hex
    buf = bytearray()
    for key, value in fields.items():
        buf += f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n'.encode()
        buf += value.encode("utf-8") + b"\r\n"
    for key, (filename, blob, ctype) in files.items():
        buf += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"; '
            f'filename="{filename}"\r\nContent-Type: {ctype}\r\n\r\n'
        ).encode()
        buf += blob + b"\r\n"
    buf += f"--{boundary}--\r\n".encode()
    return bytes(buf), f"multipart/form-data; boundary={boundary}"


def _call(path, body=None, content_type=None, method=None):
    _require_base()
    req = urllib.request.Request(
        BASE + path,
        data=body,
        method=method or ("POST" if body else "GET"),
    )
    if content_type:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=180) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8")) if raw else None


def list_jobs():
    return _call("/demo-api/jobs") or []


def submit(mode, segments, duration, aspect, quality, assets=()):
    """assets: iterable of local file paths; uploaded as asset:<uuid>."""
    asset_ids = []
    files = {}
    for path in assets:
        if not os.path.isfile(path):
            sys.exit(f"asset not found: {path}")
        aid = str(uuid.uuid4())
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        with open(path, "rb") as fh:
            files[f"asset:{aid}"] = (os.path.basename(path), fh.read(), ctype)
        asset_ids.append(aid)

    comp = {
        "mode": mode,
        "segments": segments,
        "assetIds": asset_ids,
        "duration": duration,
        "aspect": aspect,
        "quality": quality,
    }
    fields = {"id": str(uuid.uuid4()), "composition": json.dumps(comp, ensure_ascii=False)}
    body, ctype = _multipart(fields, files)
    return _call("/demo-api/jobs", body, ctype)


def wait(job_id, interval=10, timeout=2400, quiet=False):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        jobs = list_jobs()
        job = next((j for j in jobs if j.get("id") == job_id), None)
        if job is None:
            sys.exit(f"job {job_id} disappeared from the list")
        status = job.get("status")
        if status != last and not quiet:
            print(f"[{time.strftime('%H:%M:%S')}] {status}", flush=True)
            last = status
        if status in ("succeeded", "success", "done", "completed", "failed", "error"):
            return job
        time.sleep(interval)
    sys.exit(f"timed out after {timeout}s waiting for {job_id}")


def download(job, out_path):
    urls = []
    for item in job.get("outputs") or []:
        if isinstance(item, str):
            urls.append(item)
        elif isinstance(item, dict):
            for key in ("url", "path", "src"):
                if item.get(key):
                    urls.append(item[key])
                    break
    if not urls:
        print(json.dumps(job, ensure_ascii=False, indent=2))
        sys.exit("no downloadable output in job payload")
    url = urls[0]
    if url.startswith("/"):
        url = BASE + url
    with urllib.request.urlopen(url, timeout=300) as resp, open(out_path, "wb") as fh:
        fh.write(resp.read())
    return out_path


def main():
    # Windows consoles default to GBK; prompts and job payloads are UTF-8.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="H3 Studio demo API client")
    ap.add_argument("--prompt", help="text prompt (Chinese/English both fine)")
    ap.add_argument("--prompt-file", help="read the prompt from a UTF-8 file (avoids console codepage issues)")
    ap.add_argument("--first", help="first-frame image for i2v / flf2v")
    ap.add_argument("--last", help="last-frame image for flf2v")
    ap.add_argument("--ref", action="append", default=[], help="reference asset for ref2v (repeatable)")
    ap.add_argument("--duration", type=int, default=5, help="5-15 seconds")
    ap.add_argument("--aspect", default=ASPECTS[0], choices=ASPECTS)
    ap.add_argument("--quality", type=float, default=0.4, help="0.2-0.98 (0.98 = 1344x768)")
    ap.add_argument("--out", default="out.mp4")
    ap.add_argument("--list", action="store_true", help="print existing jobs and exit")
    ap.add_argument("--no-wait", action="store_true", help="submit and return immediately")
    ap.add_argument("--interval", type=int, default=10)
    ap.add_argument("--timeout", type=int, default=2400)
    args = ap.parse_args()

    if args.list:
        print(json.dumps(list_jobs(), ensure_ascii=False, indent=2))
        return

    if args.prompt_file:
        with open(args.prompt_file, encoding="utf-8") as fh:
            args.prompt = fh.read().strip()
    if not args.prompt:
        ap.error("--prompt or --prompt-file is required unless --list is given")
    if not (MIN_DURATION <= args.duration <= MAX_DURATION):
        ap.error(f"--duration must be {MIN_DURATION}-{MAX_DURATION}")

    if args.first and args.last:
        mode, assets = "flf2v", [args.first, args.last]
    elif args.first:
        mode, assets = "i2v", [args.first]
    elif args.ref:
        mode, assets = "ref2v", list(args.ref)
    else:
        mode, assets = "t2v", []

    job = submit(mode, [{"type": "text", "text": args.prompt}], args.duration, args.aspect, args.quality, assets)
    print(json.dumps({"id": job.get("id"), "status": job.get("status"), "mode": mode}, ensure_ascii=False))
    if args.no_wait:
        return

    job = wait(job["id"], args.interval, args.timeout)
    print(json.dumps(job, ensure_ascii=False, indent=2)[:2000])
    if job.get("status") in ("succeeded", "success", "done", "completed"):
        print("saved:", download(job, args.out))


if __name__ == "__main__":
    main()
