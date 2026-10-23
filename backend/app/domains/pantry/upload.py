"""In-memory multipart reading for pantry photos (PRIV-01, PRD §13.2).

Starlette's ``request.form()`` spools file parts larger than 1 MB to a temporary file on disk.
Pantry photos may show a home interior, so they must never touch disk: this module reads the
capped request body into memory and parses it with ``python_multipart`` callbacks into
``bytes``. Nothing here opens a file.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from python_multipart.multipart import MultipartParser, parse_options_header
from starlette.requests import Request

from app.core.errors import PayloadTooLarge, UnsupportedMediaType, ValidationError

MAX_IMAGE_BYTES = 5_000_000  # matches the iOS client's limit
MULTIPART_OVERHEAD = 64 * 1024
MAX_BODY_BYTES = MAX_IMAGE_BYTES + MULTIPART_OVERHEAD
MAX_PARTS = 8
MAX_FIELD_BYTES = 4096

_HEIC_BRANDS = {b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1"}


@dataclass
class Part:
    name: str = ""
    filename: str | None = None
    content_type: str | None = None
    data: bytearray = field(default_factory=bytearray)


async def read_body_capped(request: Request, limit: int = MAX_BODY_BYTES) -> bytes:
    declared = request.headers.get("content-length")
    if declared is not None and declared.isdigit() and int(declared) > limit:
        raise PayloadTooLarge("Photo must be 5 MB or smaller")
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > limit:
            raise PayloadTooLarge("Photo must be 5 MB or smaller")
    return bytes(body)


def parse_multipart(body: bytes, content_type: str) -> dict[str, Part]:
    _, params = parse_options_header(content_type)
    boundary = params.get(b"boundary")
    if not boundary:
        raise ValidationError("multipart body has no boundary", extra={"fields": ["body"]})

    parts: dict[str, Part] = {}
    current: list[Part] = []
    header_field = bytearray()
    header_value = bytearray()

    def on_part_begin() -> None:
        if len(parts) + len(current) >= MAX_PARTS:
            raise ValidationError("too many form fields", extra={"fields": ["body"]})
        current.append(Part())

    def on_header_field(data: bytes, start: int, end: int) -> None:
        header_field.extend(data[start:end])

    def on_header_value(data: bytes, start: int, end: int) -> None:
        header_value.extend(data[start:end])

    def on_header_end() -> None:
        name = bytes(header_field).decode("latin-1").strip().lower()
        value = bytes(header_value).decode("latin-1")
        part = current[-1]
        if name == "content-disposition":
            _, options = parse_options_header(value)
            part.name = options.get(b"name", b"").decode("utf-8", "replace")
            filename = options.get(b"filename")
            part.filename = filename.decode("utf-8", "replace") if filename is not None else None
        elif name == "content-type":
            part.content_type = value.strip()
        header_field.clear()
        header_value.clear()

    def on_part_data(data: bytes, start: int, end: int) -> None:
        part = current[-1]
        part.data.extend(data[start:end])
        cap = MAX_IMAGE_BYTES if part.filename is not None else MAX_FIELD_BYTES
        if len(part.data) > cap:
            if part.filename is not None:
                raise PayloadTooLarge("Photo must be 5 MB or smaller")
            raise ValidationError("form field too long", extra={"fields": [part.name]})

    def on_part_end() -> None:
        part = current.pop()
        if part.name and part.name not in parts:
            parts[part.name] = part

    parser = MultipartParser(
        boundary,
        {
            "on_part_begin": on_part_begin,
            "on_header_field": on_header_field,
            "on_header_value": on_header_value,
            "on_header_end": on_header_end,
            "on_part_data": on_part_data,
            "on_part_end": on_part_end,
        },
    )
    try:
        parser.write(body)
        parser.finalize()
    except (PayloadTooLarge, ValidationError):
        raise
    except Exception as exc:
        raise ValidationError("malformed multipart body", extra={"fields": ["body"]}) from exc
    return parts


def text_field(parts: dict[str, Part], name: str) -> str | None:
    part = parts.get(name)
    if part is None or part.filename is not None:
        return None
    try:
        return bytes(part.data).decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise ValidationError(f"{name} is not UTF-8", extra={"fields": [name]}) from exc


def sniff_image(data: bytes) -> str:
    """MIME type from magic bytes (JPEG, PNG, HEIC/HEIF); anything else is a 415."""
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if len(data) >= 12 and data[4:8] == b"ftyp" and data[8:12] in _HEIC_BRANDS:
        return "image/heic"
    raise UnsupportedMediaType("Photo must be a JPEG, PNG or HEIC image")
