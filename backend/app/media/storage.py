"""S3-compatible object storage (brief 008, PRD §9.1 / §13.2).

Production is Tigris (``https://t3.storage.dev``); dev is the MinIO container in
``backend/docker-compose.yml``; tests use moto. One ``ObjectStorage`` Protocol so the worker and
the endpoints never touch boto3 directly.

* Uploads go phone → store through a **presigned PUT** whose ``Content-Type`` and
  ``Content-Length`` are part of the signature, so the phone cannot send a different type or
  size than the backend accepted. The backend then ``HEAD``s the object before trusting it.
* Downloads are short-lived **presigned GETs**. Nothing is public-read; no bytes go through
  Postgres.
* boto3 is synchronous, so every network call runs in a worker thread.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from app.core.config import Settings

log = logging.getLogger("souslens.media.storage")


@dataclass(frozen=True)
class ObjectInfo:
    size_bytes: int
    content_type: str | None


class ObjectStorage(Protocol):
    bucket: str

    def presign_put(
        self, key: str, *, content_type: str, content_length: int, expires_in: int
    ) -> str: ...

    def presign_get(self, key: str, *, expires_in: int, content_type: str | None = None) -> str: ...

    async def head(self, key: str) -> ObjectInfo | None: ...

    async def download(self, key: str, dest: Path) -> None: ...

    async def upload(self, src: Path, key: str, *, content_type: str) -> None: ...

    async def delete(self, key: str) -> None: ...


def source_key(owner_id: uuid.UUID, media_id: uuid.UUID, ext: str) -> str:
    return f"sources/{owner_id}/{media_id}.{ext}"


def clip_key(owner_id: uuid.UUID, clip_id: uuid.UUID) -> str:
    return f"clips/{owner_id}/{clip_id}.mp4"


class S3Storage:
    def __init__(self, settings: Settings, *, client: Any | None = None) -> None:
        self.bucket = settings.storage_bucket
        cfg = Config(
            signature_version="s3v4",
            s3={"addressing_style": settings.storage_addressing_style},
            retries={"max_attempts": 3, "mode": "standard"},
            connect_timeout=10,
            read_timeout=60,
        )
        common: dict[str, Any] = {
            "region_name": settings.storage_region,
            "aws_access_key_id": settings.storage_access_key_id.get_secret_value(),
            "aws_secret_access_key": settings.storage_secret_access_key.get_secret_value(),
            "config": cfg,
        }
        self._client = client or boto3.client(
            "s3", endpoint_url=settings.storage_endpoint_url, **common
        )
        public = settings.storage_public_endpoint_url
        # Presigning is local (no network), but the host is part of the signature, so URLs for
        # the phone are signed against the host the phone will actually connect to.
        self._presigner = (
            boto3.client("s3", endpoint_url=public, **common)
            if public and client is None
            else self._client
        )

    @property
    def client(self) -> Any:
        return self._client

    def presign_put(
        self, key: str, *, content_type: str, content_length: int, expires_in: int
    ) -> str:
        return self._presigner.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": self.bucket,
                "Key": key,
                "ContentType": content_type,
                "ContentLength": content_length,
            },
            ExpiresIn=expires_in,
        )

    def presign_get(self, key: str, *, expires_in: int, content_type: str | None = None) -> str:
        params: dict[str, Any] = {"Bucket": self.bucket, "Key": key}
        if content_type:
            params["ResponseContentType"] = content_type
        return self._presigner.generate_presigned_url(
            "get_object", Params=params, ExpiresIn=expires_in
        )

    async def head(self, key: str) -> ObjectInfo | None:
        def _head() -> ObjectInfo | None:
            try:
                res = self._client.head_object(Bucket=self.bucket, Key=key)
            except ClientError as exc:
                code = str(exc.response.get("Error", {}).get("Code", ""))
                if code in ("404", "NoSuchKey", "NotFound"):
                    return None
                raise
            return ObjectInfo(
                size_bytes=int(res.get("ContentLength", 0)), content_type=res.get("ContentType")
            )

        return await asyncio.to_thread(_head)

    async def download(self, key: str, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        await asyncio.to_thread(self._client.download_file, self.bucket, key, str(dest))

    async def upload(self, src: Path, key: str, *, content_type: str) -> None:
        await asyncio.to_thread(
            self._client.upload_file,
            str(src),
            self.bucket,
            key,
            ExtraArgs={"ContentType": content_type},
        )

    async def delete(self, key: str) -> None:
        # S3 DELETE is idempotent: deleting a missing key succeeds.
        await asyncio.to_thread(self._client.delete_object, Bucket=self.bucket, Key=key)

    async def ensure_bucket(self) -> None:
        """Dev/test convenience (MinIO, moto). Production buckets are created by the operator."""

        def _ensure() -> None:
            try:
                self._client.head_bucket(Bucket=self.bucket)
            except ClientError:
                region = self._client.meta.region_name
                extra: dict[str, Any] = {}
                if region and region != "us-east-1":
                    extra["CreateBucketConfiguration"] = {"LocationConstraint": region}
                self._client.create_bucket(Bucket=self.bucket, **extra)
                log.info("created storage bucket", extra={"bucket": self.bucket})

        await asyncio.to_thread(_ensure)


def build_storage(settings: Settings) -> S3Storage:
    return S3Storage(settings)
