"""L0.5 Content-Addressed Artifact Blob Store & Semantic Text Chunker.

Large verbatim payloads (full webpage Markdown, long audio transcripts, multi-turn AI chat
messages) are stored as immutable SHA-256 content-addressed files under `<data_dir>/blobs/`
so SQLite stays fast and compact while preserving 100% verbatim provenance and full-text
searchability across all chunks.
"""

from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path

INLINE_BODY_LIMIT = 4096
FTS_CHUNK_SIZE = 1200
FTS_CHUNK_OVERLAP = 160
MAX_FTS_CHUNKS_PER_EVENT = 48


def chunk_text(
    text: str,
    *,
    chunk_size: int = FTS_CHUNK_SIZE,
    overlap: int = FTS_CHUNK_OVERLAP,
    max_chunks: int = MAX_FTS_CHUNKS_PER_EVENT,
) -> list[str]:
    """Split large text into overlapping chunks along natural paragraph/line boundaries."""
    cleaned = text.strip()
    if not cleaned:
        return []
    if len(cleaned) <= chunk_size:
        return [cleaned]

    chunks: list[str] = []
    start = 0
    total = len(cleaned)
    while start < total and len(chunks) < max_chunks:
        end = min(total, start + chunk_size)
        if end < total:
            # Prefer splitting on double newline, then single newline, then whitespace
            split_at = cleaned.rfind("\n\n", start + chunk_size // 2, end)
            if split_at == -1:
                split_at = cleaned.rfind("\n", start + chunk_size // 2, end)
            if split_at == -1:
                split_at = cleaned.rfind(" ", start + chunk_size // 2, end)
            if split_at > start:
                end = split_at
        piece = cleaned[start:end].strip()
        if piece:
            chunks.append(piece)
        if end >= total:
            break
        next_start = max(start + 1, end - overlap)
        start = next_start
    return chunks


class BlobStore:
    """Content-addressed UTF-8 text blob store under `<data_dir>/blobs/`."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def _path_for(self, digest: str) -> Path:
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("Invalid blob sha256 digest.")
        return self.root / digest[:2] / f"{digest}.txt"

    def put_text(self, text: str) -> tuple[str, int]:
        """Atomically persist UTF-8 text by SHA-256 and return `(sha256, char_len)`."""
        encoded = text.encode("utf-8")
        digest = hashlib.sha256(encoded).hexdigest()
        dest = self._path_for(digest)
        if dest.is_file():
            return digest, len(text)
        dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.NamedTemporaryFile(
            dir=dest.parent, mode="wb", delete=False, prefix=".blob-"
        ) as tmp:
            tmp_path = Path(tmp.name)
            try:
                tmp.write(encoded)
                tmp.flush()
                os.fsync(tmp.fileno())
            except BaseException:
                tmp_path.unlink(missing_ok=True)
                raise
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, dest)
        return digest, len(text)

    def has_blob(self, digest: str) -> bool:
        try:
            return self._path_for(digest).is_file()
        except ValueError:
            return False

    def get_text(
        self,
        digest: str,
        *,
        offset: int = 0,
        limit: int | None = None,
    ) -> dict[str, object]:
        """Read full or paginated UTF-8 text from the content-addressed blob store."""
        path = self._path_for(digest)
        if not path.is_file():
            raise FileNotFoundError(f"Blob not found: {digest}")
        full = path.read_text(encoding="utf-8")
        total = len(full)
        start = max(0, min(offset, total))
        if limit is None or limit <= 0:
            slice_text = full[start:]
            end = total
        else:
            end = min(total, start + limit)
            slice_text = full[start:end]
        return {
            "sha256": digest,
            "text": slice_text,
            "offset": start,
            "returned_chars": len(slice_text),
            "total_chars": total,
            "has_more": end < total,
            "next_offset": end if end < total else None,
        }

    def stats(self) -> dict[str, int]:
        count = 0
        total_bytes = 0
        for p in self.root.glob("*/*.txt"):
            if p.is_file():
                count += 1
                total_bytes += p.stat().st_size
        return {"blob_count": count, "blob_bytes": total_bytes}
