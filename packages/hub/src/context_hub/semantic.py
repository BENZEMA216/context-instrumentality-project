"""Local-first Semantic Embedding Index & Hybrid RRF Engine for Raw Memory.

Design goals:
  - 100% local & offline-capable via quantized ONNX (`fastembed`) + pure `numpy` cosine search.
  - Zero external vector DB daemon (stores float32 blobs directly inside SQLite `semantic_vectors`).
  - Graceful fallback: if `fastembed` / `numpy` is not installed, `semantic_available()` returns
    False and `HubStore` runs its 2ms Hybrid BM25 engine with zero errors.
  - Optional persistent content-hash embedding cache (`embed_cache.sqlite3`) so repeated
    benchmark runs and re-indexing avoid redundant ONNX inference.
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
from pathlib import Path
from typing import Any

DEFAULT_EMBED_MODEL = os.environ.get("RAW_MEMORY_EMBED_MODEL", "BAAI/bge-small-en-v1.5")
DEFAULT_RERANK_MODEL = os.environ.get("RAW_MEMORY_RERANK_MODEL", "Xenova/ms-marco-MiniLM-L-6-v2")
MULTILINGUAL_EMBED_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

_MODEL_CACHE: dict[str, Any] = {}
_RERANKER_CACHE: dict[str, Any] = {}


def semantic_available() -> bool:
    """Return True if optional local semantic dependencies (`fastembed` + `numpy`) are installed."""
    try:
        import fastembed  # noqa: F401
        import numpy  # noqa: F401

        return True
    except Exception:
        return False


def reranker_available() -> bool:
    """Return True if local ONNX `TextCrossEncoder` reranker is available."""
    try:
        from fastembed.rerank.cross_encoder import TextCrossEncoder  # noqa: F401

        return True
    except Exception:
        return False


def text_sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def get_embedder(model_name: str = DEFAULT_EMBED_MODEL) -> Any:
    """Lazily load and cache a local ONNX `fastembed.TextEmbedding` model."""
    if model_name not in _MODEL_CACHE:
        from fastembed import TextEmbedding

        _MODEL_CACHE[model_name] = TextEmbedding(model_name=model_name)
    return _MODEL_CACHE[model_name]


def get_reranker(model_name: str = DEFAULT_RERANK_MODEL) -> Any:
    """Lazily load and cache a local ONNX `fastembed.TextCrossEncoder` model."""
    if model_name not in _RERANKER_CACHE:
        from fastembed.rerank.cross_encoder import TextCrossEncoder

        _RERANKER_CACHE[model_name] = TextCrossEncoder(model_name=model_name)
    return _RERANKER_CACHE[model_name]


def rerank_candidates(
    query: str,
    candidates: list[tuple[str, str]],
    *,
    model_name: str = DEFAULT_RERANK_MODEL,
    max_chars: int = 1200,
) -> list[tuple[str, float]]:
    """Score `(item_id, text)` candidates with a local ONNX Cross-Encoder, sorted descending."""
    if not candidates or not query.strip() or not reranker_available():
        return []
    reranker = get_reranker(model_name)
    docs = [txt[:max_chars] for _, txt in candidates]
    scores = [float(s) for s in reranker.rerank(query.strip(), docs)]
    paired = [(candidates[i][0], scores[i]) for i in range(len(candidates))]
    paired.sort(key=lambda kv: kv[1], reverse=True)
    return paired


class PersistentEmbedCache:
    """Content-addressed SQLite cache (`(model, text_hash) -> float32 bytes`) for fast re-runs."""

    def __init__(self, cache_path: Path):
        self.cache_path = Path(cache_path).expanduser()
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(self.cache_path), timeout=20, isolation_level=None)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute(
            """CREATE TABLE IF NOT EXISTS embed_cache (
                   model TEXT NOT NULL,
                   text_hash TEXT NOT NULL,
                   dim INTEGER NOT NULL,
                   vec_blob BLOB NOT NULL,
                   PRIMARY KEY(model, text_hash)
               )"""
        )
        self._ram: dict[tuple[str, str], bytes] = {}
        self._dim: dict[str, int] = {}

    def close(self) -> None:
        if getattr(self, "_conn", None) is not None:
            self._conn.close()
            self._conn = None

    def embed_texts(
        self,
        texts: list[str],
        *,
        model_name: str = DEFAULT_EMBED_MODEL,
        batch_size: int = 64,
    ) -> Any:
        """Return an L2-normalized `(len(texts), dim)` float32 numpy array."""
        import numpy as np

        if not texts:
            return np.zeros((0, 0), dtype=np.float32)

        hashes = [text_sha256(t) for t in texts]
        uniq_hashes = list(dict.fromkeys(hashes))
        found: dict[str, bytes] = {}
        dim = self._dim.get(model_name, 0)

        need_db: list[str] = []
        for th in uniq_hashes:
            cached = self._ram.get((model_name, th))
            if cached is not None:
                found[th] = cached
            else:
                need_db.append(th)

        conn = self._conn
        if conn is None:
            conn = sqlite3.connect(str(self.cache_path), timeout=20, isolation_level=None)
            self._conn = conn

        if need_db:
            for start in range(0, len(need_db), 400):
                chunk = need_db[start : start + 400]
                ph = ",".join("?" for _ in chunk)
                for th, d, blob in conn.execute(
                    f"SELECT text_hash, dim, vec_blob FROM embed_cache WHERE model=? AND text_hash IN ({ph})",
                    [model_name, *chunk],
                ).fetchall():
                    found[th] = blob
                    self._ram[(model_name, th)] = blob
                    dim = int(d)
                    self._dim[model_name] = dim

        missing_pairs: list[tuple[str, str]] = []
        seen_missing: set[str] = set()
        for t, th in zip(texts, hashes, strict=False):
            if th not in found and th not in seen_missing:
                seen_missing.add(th)
                missing_pairs.append((th, t[:2000]))

        if missing_pairs:
            embedder = get_embedder(model_name)
            vecs = list(
                embedder.embed([t for _, t in missing_pairs], batch_size=batch_size)
            )
            to_insert: list[tuple[str, str, int, bytes]] = []
            for (th, _), raw_v in zip(missing_pairs, vecs, strict=False):
                arr = np.asarray(raw_v, dtype=np.float32)
                norm = float(np.linalg.norm(arr))
                if norm > 0:
                    arr = arr / norm
                blob = arr.tobytes()
                found[th] = blob
                self._ram[(model_name, th)] = blob
                dim = int(arr.shape[0])
                self._dim[model_name] = dim
                to_insert.append((model_name, th, dim, blob))
            conn.execute("BEGIN IMMEDIATE")
            conn.executemany(
                "INSERT OR IGNORE INTO embed_cache(model, text_hash, dim, vec_blob) VALUES (?, ?, ?, ?)",
                to_insert,
            )
            conn.commit()

        mat = np.empty((len(texts), dim), dtype=np.float32)
        for i, th in enumerate(hashes):
            mat[i] = np.frombuffer(found[th], dtype=np.float32)
        return mat


def embed_texts_direct(
    texts: list[str],
    *,
    model_name: str = DEFAULT_EMBED_MODEL,
    batch_size: int = 64,
) -> Any:
    """Encode texts directly into L2-normalized float32 vectors without external cache."""
    import numpy as np

    if not texts:
        return np.zeros((0, 0), dtype=np.float32)
    embedder = get_embedder(model_name)
    vecs = list(embedder.embed([t[:2000] for t in texts], batch_size=batch_size))
    mat = np.asarray(vecs, dtype=np.float32)
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return mat / norms


def cosine_top_k(
    query_vec: Any,
    item_ids: list[str],
    matrix: Any,
    *,
    top_k: int = 20,
    min_score: float = 0.22,
) -> list[tuple[str, float]]:
    """Fast vectorized cosine similarity ranking over L2-normalized float32 rows."""
    import numpy as np

    if not item_ids or matrix.size == 0:
        return []
    scores = matrix @ query_vec
    k = min(top_k, len(item_ids))
    if k <= 0:
        return []
    if k < len(item_ids):
        top_idx = np.argpartition(scores, -k)[-k:]
        top_idx = top_idx[np.argsort(scores[top_idx])[::-1]]
    else:
        top_idx = np.argsort(scores)[::-1]
    out: list[tuple[str, float]] = []
    for idx in top_idx:
        sc = float(scores[idx])
        if sc >= min_score:
            out.append((item_ids[int(idx)], sc))
    return out


def rrf_fuse_lists(
    ranked_lists: list[tuple[list[str], float]],
    *,
    k: float = 20.0,
) -> list[str]:
    """Reciprocal Rank Fusion across weighted ranked ID lists."""
    scores: dict[str, float] = {}
    for ids, weight in ranked_lists:
        for rank, item_id in enumerate(ids):
            scores[item_id] = scores.get(item_id, 0.0) + weight / (k + rank + 1)
    return [item_id for item_id, _ in sorted(scores.items(), key=lambda kv: kv[1], reverse=True)]
