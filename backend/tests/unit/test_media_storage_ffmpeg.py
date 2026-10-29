"""Brief 008: S3 storage (moto), ffprobe validation and ffmpeg clip rendering on a tiny
generated clip (lavfi testsrc + sine, made in the test; nothing binary is committed)."""

from __future__ import annotations

import asyncio
import json
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

from app.media import ffmpeg
from app.media.storage import S3Storage, clip_key, source_key
from tests.conftest import make_test_video, require_ffmpeg

# --- storage -------------------------------------------------------------------------------


def test_presigned_put_signs_type_and_length(s3_storage: S3Storage) -> None:
    url = s3_storage.presign_put(
        "sources/u/m.mp4", content_type="video/mp4", content_length=1234, expires_in=900
    )
    query = parse_qs(urlsplit(url).query)
    assert query["X-Amz-SignedHeaders"] == ["content-length;content-type;host"]
    assert query["X-Amz-Expires"] == ["900"]
    assert "X-Amz-Signature" in query


def test_presigned_get_is_short_lived(s3_storage: S3Storage) -> None:
    url = s3_storage.presign_get("clips/u/c.mp4", expires_in=600, content_type="video/mp4")
    query = parse_qs(urlsplit(url).query)
    assert query["X-Amz-Expires"] == ["600"]
    assert query["response-content-type"] == ["video/mp4"]


async def test_storage_roundtrip(s3_storage: S3Storage, tmp_path: Path) -> None:
    src = tmp_path / "a.bin"
    src.write_bytes(b"0123456789")
    assert await s3_storage.head("k/a.bin") is None
    await s3_storage.upload(src, "k/a.bin", content_type="video/mp4")
    info = await s3_storage.head("k/a.bin")
    assert info is not None and info.size_bytes == 10 and info.content_type == "video/mp4"
    dest = tmp_path / "out" / "a.bin"
    await s3_storage.download("k/a.bin", dest)
    assert dest.read_bytes() == b"0123456789"
    await s3_storage.delete("k/a.bin")
    await s3_storage.delete("k/a.bin")  # idempotent
    assert await s3_storage.head("k/a.bin") is None


def test_keys_are_owner_scoped() -> None:
    import uuid

    owner, media = uuid.uuid4(), uuid.uuid4()
    assert source_key(owner, media, "mov") == f"sources/{owner}/{media}.mov"
    assert clip_key(owner, media) == f"clips/{owner}/{media}.mp4"


# --- ffprobe / ffmpeg ----------------------------------------------------------------------


async def test_probe_reads_generated_clip(test_video: Path) -> None:
    assert (await asyncio.to_thread(test_video.stat)).st_size < 200 * 1024
    result = await ffmpeg.probe(test_video)
    assert 4500 <= result.duration_ms <= 5500
    assert result.has_video and result.has_audio
    assert {"mov", "mp4"} & result.format_names
    ffmpeg.validate_probe(result, max_duration_ms=15 * 60 * 1000)


async def test_probe_rejects_too_long(test_video: Path) -> None:
    result = await ffmpeg.probe(test_video)
    with pytest.raises(ffmpeg.InvalidVideo) as exc:
        ffmpeg.validate_probe(result, max_duration_ms=2_000)
    assert exc.value.code == "VIDEO_TOO_LONG"


async def test_probe_rejects_non_video_bytes(tmp_path: Path) -> None:
    require_ffmpeg()
    junk = tmp_path / "fake.mp4"
    junk.write_bytes(b"this is not a video, it is a text file pretending" * 20)
    with pytest.raises(ffmpeg.InvalidVideo) as exc:
        await ffmpeg.probe(junk)
    assert exc.value.code == "VIDEO_UNREADABLE"


async def test_probe_rejects_other_containers(tmp_path: Path) -> None:
    require_ffmpeg()
    wav = tmp_path / "tone.wav"
    await asyncio.to_thread(
        subprocess.run,
        [
            "ffmpeg",
            "-nostdin",
            "-y",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=duration=1",
            str(wav),
        ],
        check=True,
        timeout=30,
    )
    # The mov demuxer is forced, so a WAV never even parses.
    with pytest.raises(ffmpeg.InvalidVideo) as exc:
        await ffmpeg.probe(wav)
    assert exc.value.code == "VIDEO_UNREADABLE"
    # And a container the probe did read but that isn't MP4/MOV is refused by validation.
    other = ffmpeg.ProbeResult(
        duration_ms=1000,
        format_names=frozenset({"matroska", "webm"}),
        has_video=True,
        has_audio=False,
        width=1,
        height=1,
    )
    with pytest.raises(ffmpeg.InvalidVideo) as exc:
        ffmpeg.validate_probe(other, max_duration_ms=60_000)
    assert exc.value.code == "VIDEO_TYPE_UNSUPPORTED"


@pytest.mark.parametrize(
    "body",
    [
        "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\n{url}/seg.ts\n#EXT-X-ENDLIST\n",
        "ffconcat version 1.0\nfile '{url}/seg.mp4'\nfile '/etc/hosts'\n",
    ],
)
async def test_playlist_disguised_as_mp4_fetches_nothing(
    tmp_path: Path, test_video: Path, body: str
) -> None:
    """HLS / ffconcat text named .mp4 must be rejected without any network or file fetch."""
    hits: list[bytes] = []

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        hits.append(await reader.read(100))
        writer.close()

    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    evil = tmp_path / "evil.mp4"
    evil.write_text(body.format(url=f"http://127.0.0.1:{port}"))
    try:
        with pytest.raises(ffmpeg.InvalidVideo):
            await ffmpeg.probe(evil)
        with pytest.raises(ffmpeg.MediaToolError):
            await ffmpeg.render_clip(evil, tmp_path / "out.mp4", start_ms=0, end_ms=1000)
        await asyncio.sleep(0.2)
    finally:
        server.close()
        await server.wait_closed()
    assert hits == []


def test_every_invocation_uses_the_safe_input_options() -> None:
    assert ffmpeg.SAFE_INPUT_ARGS[:4] == ("-f", "mov", "-protocol_whitelist", "file")
    assert "-probesize" in ffmpeg.SAFE_INPUT_ARGS and "-analyzeduration" in ffmpeg.SAFE_INPUT_ARGS


async def test_render_clip_is_h264_aac_mp4(test_video: Path, tmp_path: Path) -> None:
    out = tmp_path / "clip.mp4"
    await ffmpeg.render_clip(test_video, out, start_ms=1000, end_ms=3000)
    probed = await asyncio.to_thread(
        subprocess.run,
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration,format_name:stream=codec_name,codec_type,pix_fmt,has_b_frames",
            "-of",
            "json",
            str(out),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    data = json.loads(probed.stdout)
    codecs = {s["codec_type"]: s for s in data["streams"]}
    assert codecs["video"]["codec_name"] == "h264"
    assert codecs["video"]["pix_fmt"] == "yuv420p"
    assert codecs["video"]["has_b_frames"] == 0
    assert codecs["audio"]["codec_name"] == "aac"
    assert 1.8 <= float(data["format"]["duration"]) <= 2.3


async def test_render_clip_without_audio(tmp_path: Path) -> None:
    require_ffmpeg()
    silent = make_test_video(tmp_path / "silent.mp4", seconds=2, audio=False)
    out = tmp_path / "clip.mp4"
    await ffmpeg.render_clip(silent, out, start_ms=0, end_ms=1500)
    assert out.stat().st_size > 0


async def test_render_clip_failure_raises(tmp_path: Path) -> None:
    require_ffmpeg()
    junk = tmp_path / "junk.mp4"
    junk.write_bytes(b"nope")
    with pytest.raises(ffmpeg.MediaToolError):
        await ffmpeg.render_clip(junk, tmp_path / "o.mp4", start_ms=0, end_ms=1000)
    with pytest.raises(ffmpeg.MediaToolError):
        await ffmpeg.render_clip(junk, tmp_path / "o.mp4", start_ms=1000, end_ms=1000)


async def test_missing_binary_is_a_tool_error(tmp_path: Path) -> None:
    with pytest.raises(ffmpeg.MediaToolError, match="not installed"):
        await ffmpeg.probe(tmp_path / "x.mp4", ffprobe="/nonexistent/ffprobe")
