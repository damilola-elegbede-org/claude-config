#!/usr/bin/env python3
"""watch — pull a video transcript (and optionally frames) for AI research.

Default mode: transcript-only. No video download, no frame extraction. Just
fetches captions via yt-dlp and prints a clean timestamped transcript. Fast
(usually <5s for YouTube) and near-zero token cost.

Opt-in with --with-frames to also download the video, extract auto-budgeted
frames, and emit a full report Claude can Read for visual context.

If a video has no captions, falls back to Whisper API (Groq preferred,
OpenAI fallback) when a key is set in env or ~/.config/watch/.env.

Usage:
  watch.py <url-or-path>
           [--with-frames]                  # add visual context (heavier)
           [--start T] [--end T]            # SS / MM:SS / HH:MM:SS
           [--max-frames N]                 # frames mode only (default 80)
           [--resolution W]                 # frames mode only (default 512)
           [--fps F]                        # frames mode only
           [--out-dir DIR]
           [--no-whisper]
           [--whisper groq|openai]
           [--json]                         # machine-readable transcript output

Exit codes:
  0  success
  1  unknown error
  2  no captions AND no Whisper fallback available
"""
from __future__ import annotations

import argparse
import io
import json
import mimetypes
import os
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import uuid
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}
MAX_FPS = 2.0
GROQ_ENDPOINT = "https://api.groq.com/openai/v1/audio/transcriptions"
GROQ_MODEL = "whisper-large-v3"
OPENAI_ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"
OPENAI_MODEL = "whisper-1"


# ---------- time helpers ----------

def parse_time(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip()
    if not s:
        return None
    parts = s.split(":")
    try:
        if len(parts) == 1:
            return float(parts[0])
        if len(parts) == 2:
            return int(parts[0]) * 60 + float(parts[1])
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    except ValueError:
        pass
    raise SystemExit(f"Cannot parse time: {value!r} (expected SS, MM:SS, or HH:MM:SS)")


def format_time(seconds):
    total = int(round(seconds))
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def is_url(source):
    if source.startswith("-"):
        return False
    p = urlparse(source)
    return p.scheme in ("http", "https") and bool(p.netloc)


# ---------- fast path: subtitles only (no video download) ----------

def fetch_subs_only(url, work):
    """Pull captions without downloading the video. Returns (sub_path, info)."""
    if not shutil.which("yt-dlp"):
        raise SystemExit("yt-dlp not installed (brew install yt-dlp).")
    work.mkdir(parents=True, exist_ok=True)
    tpl = str(work / "video.%(ext)s")
    cmd = [
        "yt-dlp", "--no-warnings",
        "--skip-download",
        "--write-info-json",
        "--write-subs", "--write-auto-subs",
        "--sub-langs", "en,en-US,en-GB,en-orig",
        "--sub-format", "vtt", "--convert-subs", "vtt",
        "--no-playlist", "--ignore-errors",
        "-o", tpl, "--", url,
    ]
    subprocess.run(cmd, stdout=sys.stderr, stderr=sys.stderr)

    subs = sorted(work.glob("video*.vtt"))
    preferred = [c for c in subs if ".en" in c.name]
    sub_path = (preferred or subs or [None])[0]

    info = {}
    info_path = work / "video.info.json"
    if info_path.exists():
        try:
            raw = json.loads(info_path.read_text(encoding="utf-8"))
            info = {
                "title": raw.get("title"),
                "uploader": raw.get("uploader") or raw.get("channel"),
                "duration": raw.get("duration"),
                "url": raw.get("webpage_url") or url,
                "upload_date": raw.get("upload_date"),
                "view_count": raw.get("view_count"),
            }
        except Exception as exc:
            print(f"[watch] info.json parse failed: {exc}", file=sys.stderr)
    return sub_path, info or {"url": url}


def fetch_audio_only(url, out_path):
    """Download audio only for Whisper fallback when no captions exist."""
    if not shutil.which("yt-dlp"):
        raise SystemExit("yt-dlp not installed.")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "yt-dlp", "--no-warnings",
        "-f", "bestaudio/best",
        "--extract-audio", "--audio-format", "mp3", "--audio-quality", "64K",
        "--postprocessor-args", "ffmpeg:-ar 16000 -ac 1",
        "--no-playlist", "--ignore-errors",
        "-o", str(out_path.with_suffix(".%(ext)s")), "--", url,
    ]
    r = subprocess.run(cmd, stdout=sys.stderr, stderr=sys.stderr)
    final = out_path.parent / (out_path.stem + ".mp3")
    if not final.exists():
        raise SystemExit(f"yt-dlp audio-only download failed (exit {r.returncode})")
    return final


# ---------- frames mode: full download + extraction ----------

def download_video(source, work):
    if is_url(source):
        return _download_url(source, work)
    p = Path(source).expanduser().resolve()
    if not p.exists():
        raise SystemExit(f"File not found: {p}")
    return {"video_path": str(p), "subtitle_path": None,
            "info": {"title": p.name, "url": str(p)}, "downloaded": False}


def _download_url(url, work):
    if not shutil.which("yt-dlp"):
        raise SystemExit("yt-dlp not installed (brew install yt-dlp).")
    work.mkdir(parents=True, exist_ok=True)
    tpl = str(work / "video.%(ext)s")
    cmd = [
        "yt-dlp", "-N", "8",
        "-f", "bv*[height<=720]+ba/b[height<=720]/bv+ba/b",
        "--merge-output-format", "mp4",
        "--write-info-json",
        "--write-subs", "--write-auto-subs",
        "--sub-langs", "en,en-US,en-GB,en-orig",
        "--sub-format", "vtt", "--convert-subs", "vtt",
        "--no-playlist", "--ignore-errors",
        "-o", tpl, "--", url,
    ]
    subprocess.run(cmd, stdout=sys.stderr, stderr=sys.stderr)

    video = None
    for ext in (".mp4", ".mkv", ".webm", ".mov"):
        hits = sorted(work.glob(f"video*{ext}"))
        if hits:
            video = hits[0]
            break
    if not video:
        raise SystemExit(f"yt-dlp did not produce a video file in {work}")

    subs = sorted(work.glob("video*.vtt"))
    preferred = [c for c in subs if ".en" in c.name]
    subtitle = (preferred or subs or [None])[0]

    info = {}
    info_path = work / "video.info.json"
    if info_path.exists():
        try:
            raw = json.loads(info_path.read_text(encoding="utf-8"))
            info = {
                "title": raw.get("title"),
                "uploader": raw.get("uploader") or raw.get("channel"),
                "duration": raw.get("duration"),
                "url": raw.get("webpage_url") or url,
                "upload_date": raw.get("upload_date"),
                "view_count": raw.get("view_count"),
            }
        except Exception:
            info = {"url": url}
    return {"video_path": str(video),
            "subtitle_path": str(subtitle) if subtitle else None,
            "info": info or {"url": url}, "downloaded": True}


def ffprobe_meta(video_path):
    if not shutil.which("ffprobe"):
        raise SystemExit("ffprobe not installed (brew install ffmpeg).")
    r = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json",
         "-show_format", "-show_streams", str(Path(video_path).resolve())],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"ffprobe failed: {r.stderr.strip()}")
    data = json.loads(r.stdout or "{}")
    streams = data.get("streams", [])
    fmt = data.get("format", {})
    v = next((s for s in streams if s.get("codec_type") == "video"), {})
    a = next((s for s in streams if s.get("codec_type") == "audio"), None)
    return {
        "duration_seconds": float(fmt.get("duration") or v.get("duration") or 0),
        "width": v.get("width"), "height": v.get("height"),
        "codec": v.get("codec_name"),
        "size_bytes": int(fmt.get("size") or 0),
        "has_audio": a is not None,
    }


def _clamp(fps, duration, cap):
    fps = min(fps, MAX_FPS)
    target = min(cap, max(1, int(round(fps * duration))))
    return fps, target


def auto_fps(duration, cap=100):
    if duration <= 0:
        return 1.0, 1
    if duration <= 30:
        target = min(cap, max(12, int(round(duration))))
    elif duration <= 60:
        target = min(cap, 40)
    elif duration <= 180:
        target = min(cap, 60)
    elif duration <= 600:
        target = min(cap, 80)
    else:
        target = cap
    return _clamp(target / duration, duration, cap)


def auto_fps_focus(duration, cap=100):
    if duration <= 0:
        return min(MAX_FPS, 2.0), 2
    if duration <= 5:
        target = min(cap, max(10, int(round(duration * 6))))
    elif duration <= 15:
        target = min(cap, max(30, int(round(duration * 4))))
    elif duration <= 30:
        target = min(cap, 60)
    elif duration <= 60:
        target = min(cap, 80)
    else:
        target = cap
    return _clamp(target / duration, duration, cap)


def extract_frames(video, out_dir, fps, resolution=512, cap=100,
                   start=None, end=None):
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg not installed (brew install ffmpeg).")
    out_dir.mkdir(parents=True, exist_ok=True)
    for existing in out_dir.glob("frame_*.jpg"):
        existing.unlink()

    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    if start is not None:
        cmd += ["-ss", f"{start:.3f}"]
    if end is not None:
        cmd += ["-to", f"{end:.3f}"]
    cmd += ["-i", str(Path(video).resolve()),
            "-vf", f"fps={fps},scale={resolution}:-2",
            "-frames:v", str(cap), "-q:v", "4",
            str(out_dir / "frame_%04d.jpg")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"ffmpeg frame extraction failed: {r.stderr.strip()}")

    offset = start or 0.0
    frames = sorted(out_dir.glob("frame_*.jpg"))
    return [
        {"index": i,
         "timestamp_seconds": round(offset + (i / fps if fps > 0 else 0.0), 2),
         "path": str(p)}
        for i, p in enumerate(frames)
    ]


# ---------- VTT transcript ----------

_TS_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2})[.,](\d{3})"
)
_TAG_RE = re.compile(r"<[^>]+>")


def _to_sec(h, m, s, ms):
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def parse_vtt(path):
    text = Path(path).read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    segs = []
    i = 0
    while i < len(lines):
        m = _TS_RE.match(lines[i])
        if not m:
            i += 1
            continue
        start = _to_sec(*m.groups()[:4])
        end = _to_sec(*m.groups()[4:])
        i += 1
        cue = []
        while i < len(lines) and lines[i].strip():
            cleaned = _TAG_RE.sub("", lines[i]).strip()
            if cleaned:
                cue.append(cleaned)
            i += 1
        txt = " ".join(cue).strip()
        if txt:
            segs.append({"start": round(start, 2), "end": round(end, 2), "text": txt})
        i += 1
    # Collapse YouTube auto-sub rolling duplicates.
    out = []
    for s in segs:
        if out and s["text"] == out[-1]["text"]:
            out[-1]["end"] = s["end"]
            continue
        if out and s["text"].startswith(out[-1]["text"] + " "):
            out[-1]["text"] = s["text"]
            out[-1]["end"] = s["end"]
            continue
        out.append(s)
    return out


def filter_range(segs, start, end):
    if start is None and end is None:
        return segs
    lo = start if start is not None else float("-inf")
    hi = end if end is not None else float("inf")
    return [s for s in segs if s["end"] >= lo and s["start"] <= hi]


def format_transcript(segs):
    out = []
    for s in segs:
        t = int(s["start"])
        out.append(f"[{t // 60:02d}:{t % 60:02d}] {s['text']}")
    return "\n".join(out)


# ---------- Whisper fallback ----------

def _read_env_key(name):
    v = os.environ.get(name)
    if v and v.strip():
        return v.strip()
    for path in (Path.home() / ".config" / "watch" / ".env", Path.cwd() / ".env"):
        if not path.exists():
            continue
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, raw = line.partition("=")
                if k.strip() != name:
                    continue
                raw = raw.strip()
                if len(raw) >= 2 and raw[0] in ('"', "'") and raw[-1] == raw[0]:
                    raw = raw[1:-1]
                if raw:
                    return raw
        except OSError:
            continue
    return None


def load_api_key(preferred=None):
    candidates = (("GROQ_API_KEY", "groq"), ("OPENAI_API_KEY", "openai"))
    if preferred:
        candidates = tuple(c for c in candidates if c[1] == preferred)
    for key, backend in candidates:
        v = _read_env_key(key)
        if v:
            return backend, v
    return None, None


def extract_audio_from_video(video_path, out_path):
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg not installed.")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-i", str(Path(video_path).resolve()),
         "-vn", "-acodec", "libmp3lame", "-ar", "16000",
         "-ac", "1", "-b:a", "64k", str(out_path.resolve())],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise SystemExit(f"ffmpeg audio extract failed: {r.stderr.strip()}")
    if not out_path.exists() or out_path.stat().st_size == 0:
        raise SystemExit("No audio extracted (video may be silent).")
    return out_path


def _multipart(fields, file_path):
    boundary = f"----WatchBoundary{uuid.uuid4().hex}"
    eol = b"\r\n"
    buf = io.BytesIO()
    for name, value in fields.items():
        buf.write(f"--{boundary}".encode()); buf.write(eol)
        buf.write(f'Content-Disposition: form-data; name="{name}"'.encode()); buf.write(eol)
        buf.write(eol)
        buf.write(str(value).encode()); buf.write(eol)
    mt = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    buf.write(f"--{boundary}".encode()); buf.write(eol)
    buf.write(
        f'Content-Disposition: form-data; name="file"; filename="{file_path.name}"'.encode()
    ); buf.write(eol)
    buf.write(f"Content-Type: {mt}".encode()); buf.write(eol)
    buf.write(eol)
    buf.write(file_path.read_bytes()); buf.write(eol)
    buf.write(f"--{boundary}--".encode()); buf.write(eol)
    return buf.getvalue(), boundary


def _post_whisper(endpoint, api_key, model, audio):
    body, boundary = _multipart(
        {"model": model, "response_format": "verbose_json", "temperature": "0"},
        audio,
    )
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "User-Agent": "watch-skill/1.0 (+python-urllib)",
    }
    ctx = ssl.create_default_context()
    last = ""
    for attempt in range(4):
        req = Request(endpoint, data=body, headers=headers, method="POST")
        try:
            with urlopen(req, timeout=300, context=ctx) as resp:
                payload = resp.read().decode("utf-8", errors="replace")
            return json.loads(payload)
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = f" — {exc.read().decode('utf-8', errors='replace')[:400]}"
            except Exception:
                pass
            last = f"HTTP {exc.code}{detail}"
            if 400 <= exc.code < 500 and exc.code != 429:
                raise SystemExit(f"Whisper request failed: {last}")
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last = f"{type(exc).__name__}: {exc}"
        if attempt < 3:
            delay = 2.0 * (2 ** attempt)
            print(f"[watch] whisper retry in {delay:.1f}s ({last})", file=sys.stderr)
            time.sleep(delay)
    raise SystemExit(f"Whisper failed after 4 attempts: {last}")


def whisper_transcribe(audio_path, backend, api_key):
    print(f"[watch] uploading {audio_path.stat().st_size // 1024} kB to {backend}",
          file=sys.stderr)
    endpoint, model = (
        (GROQ_ENDPOINT, GROQ_MODEL) if backend == "groq" else (OPENAI_ENDPOINT, OPENAI_MODEL)
    )
    data = _post_whisper(endpoint, api_key, model, audio_path)
    segs = []
    for s in data.get("segments") or []:
        txt = (s.get("text") or "").strip()
        if not txt:
            continue
        segs.append({"start": round(float(s.get("start") or 0.0), 2),
                     "end": round(float(s.get("end") or 0.0), 2), "text": txt})
    if not segs:
        full = (data.get("text") or "").strip()
        if full:
            segs.append({"start": 0.0, "end": 0.0, "text": full})
    if not segs:
        raise SystemExit("Whisper returned no segments.")
    return segs


# ---------- entry ----------

def run_transcript_only(args, work):
    """Fast path: no video download, just captions (+ optional whisper)."""
    source = args.source
    info = {}
    sub_path = None
    duration = 0.0

    if is_url(source):
        print("[watch] fetching captions (no video download)…", file=sys.stderr)
        sub_path, info = fetch_subs_only(source, work / "download")
        duration = float(info.get("duration") or 0)
    else:
        local = Path(source).expanduser().resolve()
        if not local.exists():
            raise SystemExit(f"File not found: {local}")
        info = {"title": local.name, "url": str(local)}
        try:
            duration = ffprobe_meta(local)["duration_seconds"]
        except SystemExit:
            duration = 0.0
        # Local file: no native captions to pull.

    segments = []
    source_label = None
    if sub_path:
        try:
            segments = parse_vtt(sub_path)
            source_label = "captions"
        except Exception as exc:
            print(f"[watch] vtt parse failed: {exc}", file=sys.stderr)

    start = parse_time(args.start)
    end = parse_time(args.end)
    if segments and (start is not None or end is not None):
        segments = filter_range(segments, start, end)

    # Whisper fallback for transcript-only: audio-only download + whisper.
    if not segments and not args.no_whisper:
        backend, key = load_api_key(args.whisper)
        if backend and key:
            try:
                if is_url(source):
                    print("[watch] no captions; downloading audio for Whisper…",
                          file=sys.stderr)
                    audio = fetch_audio_only(source, work / "audio")
                else:
                    audio = extract_audio_from_video(source, work / "audio.mp3")
                allsegs = whisper_transcribe(audio, backend, key)
                segments = filter_range(allsegs, start, end) if (start is not None or end is not None) else allsegs
                source_label = f"whisper ({backend})"
            except SystemExit as exc:
                print(f"[watch] whisper fallback failed: {exc}", file=sys.stderr)

    if args.json:
        out = {
            "source": source,
            "title": info.get("title"),
            "uploader": info.get("uploader"),
            "url": info.get("url") or source,
            "duration_seconds": duration,
            "transcript_source": source_label,
            "segments": segments,
        }
        print(json.dumps(out, indent=2))
        return 0 if segments else 2

    if not segments:
        print(f"[watch] ERROR: no transcript available for {source}", file=sys.stderr)
        print("        (captions missing; Whisper unavailable — set GROQ_API_KEY or",
              file=sys.stderr)
        print("         OPENAI_API_KEY in ~/.config/watch/.env, or omit --no-whisper)",
              file=sys.stderr)
        return 2

    print()
    print("# watch: transcript")
    print()
    print(f"- **Source:** {source}")
    if info.get("title"):
        print(f"- **Title:** {info['title']}")
    if info.get("uploader"):
        print(f"- **Uploader:** {info['uploader']}")
    if duration:
        print(f"- **Duration:** {format_time(duration)} ({duration:.1f}s)")
    if start is not None or end is not None:
        print(f"- **Filtered:** "
              f"{format_time(start or 0)} → "
              f"{format_time(end) if end is not None else 'end'}")
    print(f"- **Segments:** {len(segments)} (via {source_label})")
    print()
    print("```")
    print(format_transcript(segments))
    print("```")
    print()
    print("---")
    print(f"_Work dir: `{work}` — delete when done._")
    return 0


def run_with_frames(args, work):
    """Full pipeline: download video, extract frames, transcript."""
    cap = min(args.max_frames, 100)
    dl = download_video(args.source, work / "download")
    video = dl["video_path"]
    meta = ffprobe_meta(video)
    total = meta["duration_seconds"]

    start = parse_time(args.start)
    end = parse_time(args.end)
    if start is not None and start < 0:
        raise SystemExit("--start must be non-negative")
    if start is not None and end is not None and end <= start:
        raise SystemExit("--end must be greater than --start")
    if total and start is not None and start >= total:
        raise SystemExit(f"--start past end of video ({total:.1f}s)")

    eff_start = start if start is not None else 0.0
    eff_end = end if end is not None else total
    eff_dur = max(0.0, eff_end - eff_start)
    focused = start is not None or end is not None

    fps, target = (auto_fps_focus(eff_dur, cap) if focused else auto_fps(eff_dur, cap))
    if args.fps is not None:
        fps = min(args.fps, MAX_FPS)
        target = max(1, int(round(fps * eff_dur)))

    scope = (f"{format_time(eff_start)}-{format_time(eff_end)} ({eff_dur:.1f}s)"
             if focused else f"full {eff_dur:.1f}s")
    print(f"[watch] extracting ~{target} frames at {fps:.3f} fps over {scope}",
          file=sys.stderr)
    frames = extract_frames(video, work / "frames", fps=fps,
                            resolution=args.resolution, cap=cap,
                            start=start, end=end)

    segments = []
    source_label = None
    if dl.get("subtitle_path"):
        try:
            allsegs = parse_vtt(dl["subtitle_path"])
            segments = filter_range(allsegs, start, end) if focused else allsegs
            source_label = "captions"
        except Exception as exc:
            print(f"[watch] vtt parse failed: {exc}", file=sys.stderr)

    if not segments and not args.no_whisper:
        backend, key = load_api_key(args.whisper)
        if backend and key:
            try:
                audio = extract_audio_from_video(video, work / "audio.mp3")
                allsegs = whisper_transcribe(audio, backend, key)
                segments = filter_range(allsegs, start, end) if focused else allsegs
                source_label = f"whisper ({backend})"
            except SystemExit as exc:
                print(f"[watch] whisper fallback failed: {exc}", file=sys.stderr)

    info = dl.get("info") or {}
    transcript_text = format_transcript(segments) if segments else None

    print()
    print("# watch: video report")
    print()
    print(f"- **Source:** {args.source}")
    if info.get("title"):
        print(f"- **Title:** {info['title']}")
    if info.get("uploader"):
        print(f"- **Uploader:** {info['uploader']}")
    print(f"- **Duration:** {format_time(total)} ({total:.1f}s)")
    if focused:
        print(f"- **Focus:** {format_time(eff_start)} → {format_time(eff_end)} ({eff_dur:.1f}s)")
    if meta.get("width") and meta.get("height"):
        print(f"- **Resolution:** {meta['width']}x{meta['height']} "
              f"({meta.get('codec') or 'unknown'})")
    mode = "focused" if focused else "full"
    print(f"- **Frames:** {len(frames)} @ {fps:.3f} fps, {mode} (budget {target}, max {cap})")
    if segments:
        rng = " in range" if focused else ""
        print(f"- **Transcript:** {len(segments)} segments{rng} (via {source_label})")
    else:
        print("- **Transcript:** none available")

    if not focused and total > 600:
        mins = int(total // 60)
        print()
        print(f"> **Warning:** {mins}-minute video — frame coverage is sparse. "
              "Re-run with `--start HH:MM:SS --end HH:MM:SS` for better detail.")

    print()
    print("## Frames")
    print()
    print(f"Frames at: `{work / 'frames'}`")
    print()
    print("**Read each path below with the Read tool to view the image.** "
          "`t=MM:SS` is the absolute timestamp in the source video.")
    print()
    for fr in frames:
        print(f"- `{fr['path']}` (t={format_time(fr['timestamp_seconds'])})")

    print()
    print("## Transcript")
    print()
    if transcript_text:
        if focused:
            print(f"_Source: {source_label}. Filtered to "
                  f"{format_time(eff_start)} → {format_time(eff_end)}:_")
        else:
            print(f"_Source: {source_label}._")
        print()
        print("```")
        print(transcript_text)
        print("```")
    else:
        print("_No transcript available — frames only._")

    print()
    print("---")
    print(f"_Work dir: `{work}` — delete when done._")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="watch")
    ap.add_argument("source", help="Video URL or local path")
    ap.add_argument("--with-frames", action="store_true",
                    help="Also download video + extract frames (heavier, slower).")
    ap.add_argument("--max-frames", type=int, default=80)
    ap.add_argument("--resolution", type=int, default=512)
    ap.add_argument("--fps", type=float, default=None)
    ap.add_argument("--start", type=str, default=None)
    ap.add_argument("--end", type=str, default=None)
    ap.add_argument("--out-dir", type=str, default=None)
    ap.add_argument("--no-whisper", action="store_true")
    ap.add_argument("--whisper", choices=["groq", "openai"], default=None)
    ap.add_argument("--json", action="store_true",
                    help="Transcript-only: emit machine-readable JSON.")
    args = ap.parse_args()

    work = Path(args.out_dir).expanduser().resolve() if args.out_dir \
        else Path(tempfile.mkdtemp(prefix="watch-"))
    work.mkdir(parents=True, exist_ok=True)
    print(f"[watch] work dir: {work}", file=sys.stderr)

    if args.with_frames:
        return run_with_frames(args, work)
    return run_transcript_only(args, work)


if __name__ == "__main__":
    raise SystemExit(main())
