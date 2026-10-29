"""ffprobe validation and ffmpeg step-clip rendering (brief 008, CAP-01 / CAP-04).

Ported from Retrace ``services/video_probe.py`` and ``services/clip_extractor.py`` (ADR-0001):
the H.264 + AAC encode flags that iOS plays reliably (no B-frames, explicit BT.709 tags,
``+faststart``) are kept verbatim. Changes from Retrace:

* ffprobe reads container *and* streams as JSON, so the worker can reject non-video bytes and
  non-MP4/MOV containers, not only read the duration.
* Input seeking (``-ss`` before ``-i``) instead of output seeking: a re-encode is still frame
  accurate and a clip near the end of a 15-minute source no longer decodes the whole file.
  ``-avoid_negative_ts make_zero`` keeps the timestamps iOS needs.
* Clips are scaled so the longer side is at most 1280 px.
* Every subprocess has a timeout and is killed when it runs over; no shell is involved.
* Every read of user media forces the mov demuxer, whitelists only the file protocol and caps
  probing (``SAFE_INPUT_ARGS``), so playlist tricks can't make ffmpeg fetch anything.
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("souslens.media.ffmpeg")

PROBE_TIMEOUT_SECONDS = 30.0
# Input options for every invocation over user media (fix round 1). Forcing the mov/mp4 demuxer
# means a playlist (HLS, concat, ffconcat) disguised as .mp4 is never interpreted as one, the
# file-only protocol whitelist means nothing can be fetched over the network or from another
# path, and the probe caps bound how much of a hostile file is read before deciding.
SAFE_INPUT_ARGS: tuple[str, ...] = (
    "-f",
    "mov",
    "-protocol_whitelist",
    "file",
    "-probesize",
    str(50 * 1024 * 1024),
    "-analyzeduration",
    str(30 * 1000 * 1000),
)


def _input(path: Path) -> str:
    # "file:" so a path can never be read as another protocol ("concat:", "http:" ...).
    return f"file:{path}"


ACCEPTED_FORMATS = frozenset({"mov", "mp4"})
MAX_CLIP_SIDE = 1280


class MediaToolError(Exception):
    """ffprobe/ffmpeg failed or timed out (the file may still be fine; the tool was not)."""


class InvalidVideo(Exception):
    """The file is not an acceptable creator video. ``code`` is the API error code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class ProbeResult:
    duration_ms: int
    format_names: frozenset[str]
    has_video: bool
    has_audio: bool
    width: int | None
    height: int | None


async def _run(cmd: list[str], limit_seconds: float) -> tuple[int, bytes, bytes]:
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise MediaToolError(f"{cmd[0]} is not installed") from exc
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=limit_seconds)
    except TimeoutError as exc:
        proc.kill()
        await proc.wait()
        raise MediaToolError(f"{Path(cmd[0]).name} timed out after {limit_seconds:.0f}s") from exc
    return proc.returncode or 0, out, err


async def probe(path: Path, *, ffprobe: str = "ffprobe") -> ProbeResult:
    """Raises ``InvalidVideo("VIDEO_UNREADABLE")`` when ffprobe cannot parse the file."""
    code, out, err = await _run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=format_name,duration:stream=codec_type,width,height",
            "-of",
            "json",
            *SAFE_INPUT_ARGS,
            _input(path),
        ],
        PROBE_TIMEOUT_SECONDS,
    )
    if code != 0:
        log.info(
            "ffprobe rejected file", extra={"stderr_tail": err[-300:].decode(errors="replace")}
        )
        raise InvalidVideo("VIDEO_UNREADABLE", "This file couldn't be read as a video.")
    try:
        data = json.loads(out or b"{}")
        fmt = data.get("format") or {}
        duration_s = float(fmt.get("duration"))
    except (ValueError, TypeError) as exc:
        raise InvalidVideo("VIDEO_UNREADABLE", "This file couldn't be read as a video.") from exc
    streams = data.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    return ProbeResult(
        duration_ms=max(round(duration_s * 1000), 0),
        format_names=frozenset(str(fmt.get("format_name", "")).split(",")),
        has_video=video is not None,
        has_audio=any(s.get("codec_type") == "audio" for s in streams),
        width=(video or {}).get("width"),
        height=(video or {}).get("height"),
    )


def validate_probe(result: ProbeResult, *, max_duration_ms: int) -> None:
    """CAP-01: MP4/MOV with a video stream, longer than zero and at most the configured limit."""
    if not (result.format_names & ACCEPTED_FORMATS):
        raise InvalidVideo("VIDEO_TYPE_UNSUPPORTED", "Only MP4 and MOV videos are supported.")
    if not result.has_video or result.duration_ms <= 0:
        raise InvalidVideo("VIDEO_UNREADABLE", "This file has no playable video.")
    if result.duration_ms > max_duration_ms:
        minutes = max_duration_ms // 60000
        raise InvalidVideo("VIDEO_TOO_LONG", f"Videos can be at most {minutes} minutes long.")


def _non_empty(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def clip_timeout_seconds(duration_ms: int) -> float:
    return max(60.0, 3.0 * duration_ms / 1000.0)


async def render_clip(
    source: Path, dest: Path, *, start_ms: int, end_ms: int, ffmpeg: str = "ffmpeg"
) -> None:
    """Render ``[start_ms, end_ms)`` of ``source`` to an H.264/AAC MP4 at ``dest``."""
    duration_ms = end_ms - start_ms
    if duration_ms <= 0:
        raise MediaToolError("empty clip range")
    dest.parent.mkdir(parents=True, exist_ok=True)
    scale = (
        f"scale='trunc(min(1,{MAX_CLIP_SIDE}/max(iw,ih))*iw/2)*2'"
        f":'trunc(min(1,{MAX_CLIP_SIDE}/max(iw,ih))*ih/2)*2'"
    )
    cmd = [
        ffmpeg,
        "-nostdin",
        "-y",
        "-v",
        "error",
        "-ss",
        f"{start_ms / 1000:.3f}",
        *SAFE_INPUT_ARGS,
        "-i",
        _input(source),
        "-t",
        f"{duration_ms / 1000:.3f}",
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-vf",
        scale,
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        # iOS HD playback rejects clips with negative DTS: no B-frames, so PTS == DTS.
        "-bf",
        "0",
        "-pix_fmt",
        "yuv420p",
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
        "-color_range",
        "tv",
        # libx264 needs the SEI colour tags here too (iOS VideoToolbox verify errors otherwise).
        "-x264opts",
        "colorprim=bt709:transfer=bt709:colormatrix=bt709",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-avoid_negative_ts",
        "make_zero",
        "-movflags",
        "+faststart",
        str(dest),
    ]
    code, _out, err = await _run(cmd, clip_timeout_seconds(duration_ms))
    if code != 0 or not _non_empty(dest):
        log.warning(
            "ffmpeg clip failed", extra={"stderr_tail": err[-300:].decode(errors="replace")}
        )
        raise MediaToolError("ffmpeg could not render this clip")
