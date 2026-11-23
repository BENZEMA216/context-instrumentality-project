"""Local offline ASR engine using `sherpa-onnx` + `SenseVoice-Small` (int8) + `Silero-VAD`.

Design goals:
- Zero cloud API keys, zero network calls during transcription.
- Decodes macOS CoreAudio `.caf`, `.m4a`, `.aac`, `.wav`, `.opus` cleanly via built-in
  `afconvert` (macOS) or `ffmpeg` fallback into 16 kHz mono PCM float32.
- Uses Silero-VAD to skip silence and slice 60s+ recordings into natural utterances
  with sub-second relative timestamps so SenseVoice stays accurate and fast.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request
import wave
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

SENSEVOICE_DIR_NAME = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
SENSEVOICE_FALLBACK_DIR_NAMES = (
    SENSEVOICE_DIR_NAME,
    "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
)
SENSEVOICE_ARCHIVE_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
    f"{SENSEVOICE_DIR_NAME}.tar.bz2"
)
SILERO_VAD_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
)


def default_models_dir() -> Path:
    if env := os.environ.get("CONTEXT_HUB_MODELS_DIR"):
        return Path(env).expanduser()
    return Path.home() / ".local" / "share" / "context-hub-v2" / "models"


@dataclass
class ASRSpan:
    start: float  # seconds relative to segment start
    end: float
    text: str

    def to_dict(self, segment_started_at_ms: int | None = None) -> dict[str, Any]:
        out: dict[str, Any] = {
            "start": round(self.start, 3),
            "end": round(self.end, 3),
            "text": self.text,
        }
        if segment_started_at_ms is not None:
            out["abs_start_ms"] = segment_started_at_ms + round(self.start * 1000)
            out["abs_end_ms"] = segment_started_at_ms + round(self.end * 1000)
        return out


@dataclass
class ASRResult:
    text: str
    spans: list[ASRSpan] = field(default_factory=list)
    engine: str = "sensevoice-small"
    locale: str = "zh-en"
    audio_seconds: float = 0.0
    speech_seconds: float = 0.0
    elapsed_ms: int = 0

    @property
    def rtf(self) -> float:
        if self.audio_seconds <= 0:
            return 0.0
        return round((self.elapsed_ms / 1000.0) / self.audio_seconds, 4)


class AudioTranscriber(Protocol):
    engine_name: str

    def transcribe_file(self, audio_path: Path) -> ASRResult: ...


def sensevoice_model_status(models_dir: Path | None = None) -> dict[str, Any]:
    root = Path(models_dir) if models_dir else default_models_dir()
    chosen_model: Path | None = None
    tokens: Path | None = None
    for dname in SENSEVOICE_FALLBACK_DIR_NAMES:
        sv_dir = root / dname
        cand_tokens = sv_dir / "tokens.txt"
        cand_int8 = sv_dir / "model.int8.onnx"
        cand_fp32 = sv_dir / "model.onnx"
        cand_model = cand_int8 if cand_int8.is_file() else (cand_fp32 if cand_fp32.is_file() else None)
        if cand_model and cand_tokens.is_file():
            chosen_model = cand_model
            tokens = cand_tokens
            break
    vad = root / "silero_vad.onnx"
    try:
        import sherpa_onnx  # noqa: F401

        runtime_ok = True
    except ImportError:
        runtime_ok = False
    return {
        "models_dir": str(root),
        "sherpa_onnx_installed": runtime_ok,
        "sensevoice_ready": bool(chosen_model and tokens),
        "model_path": str(chosen_model) if chosen_model else None,
        "tokens_path": str(tokens) if tokens else None,
        "silero_vad_ready": vad.is_file(),
        "vad_path": str(vad) if vad.is_file() else None,
    }


def _download_file(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(dir=dest.parent, prefix=".dl-", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "context-hub-v2/0.2"})
        with urllib.request.urlopen(req, timeout=180) as resp, tmp_path.open("wb") as out:
            shutil.copyfileobj(resp, out, length=1024 * 256)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp_path, dest)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise


def ensure_sensevoice_models(models_dir: Path | None = None) -> dict[str, Any]:
    """Download official SenseVoice-Small (int8) + Silero-VAD ONNX models if missing."""
    root = Path(models_dir) if models_dir else default_models_dir()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    status = sensevoice_model_status(root)

    if not status["sensevoice_ready"]:
        archive_path = root / f"{SENSEVOICE_DIR_NAME}.tar.bz2"
        _download_file(SENSEVOICE_ARCHIVE_URL, archive_path)
        try:
            with tarfile.open(archive_path, "r:bz2") as tar:
                # Safe extraction confined strictly under `root`
                resolved_root = root.resolve()
                members = []
                for m in tar.getmembers():
                    target = (root / m.name).resolve()
                    if not target.is_relative_to(resolved_root):
                        raise ValueError(f"Unsafe archive path: {m.name}")
                    members.append(m)
                tar.extractall(root, members=members)
        finally:
            archive_path.unlink(missing_ok=True)

    vad_path = root / "silero_vad.onnx"
    if not vad_path.is_file():
        _download_file(SILERO_VAD_URL, vad_path)

    return sensevoice_model_status(root)


def decode_audio_to_pcm16k(audio_path: Path) -> tuple[Any, int]:
    """Decode any supported audio file (`.caf`, `.m4a`, `.wav`, `.opus`, ...) to 16 kHz mono float32 numpy array."""
    import numpy as np

    if not audio_path.is_file():
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    # Fast path if already 16kHz 16-bit mono WAV
    if audio_path.suffix.lower() == ".wav":
        try:
            with wave.open(str(audio_path), "rb") as wf:
                if wf.getnchannels() == 1 and wf.getsampwidth() == 2 and wf.getframerate() == 16000:
                    raw = wf.readframes(wf.getnframes())
                    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
                    return samples, 16000
        except wave.Error:
            pass

    with tempfile.NamedTemporaryFile(suffix=".wav", prefix="ctx-pcm-", delete=False) as tmp:
        wav_path = Path(tmp.name)

    try:
        afconvert = shutil.which("afconvert")
        ffmpeg = shutil.which("ffmpeg")
        if afconvert:
            cmd = [
                afconvert,
                "-f",
                "WAVE",
                "-d",
                "LEI16@16000",
                "-c",
                "1",
                str(audio_path),
                str(wav_path),
            ]
        elif ffmpeg:
            cmd = [
                ffmpeg,
                "-y",
                "-v",
                "error",
                "-i",
                str(audio_path),
                "-ar",
                "16000",
                "-ac",
                "1",
                "-f",
                "wav",
                str(wav_path),
            ]
        else:
            raise RuntimeError("Neither macOS `afconvert` nor `ffmpeg` is available to decode audio.")

        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            raise RuntimeError(f"Audio decode failed ({proc.returncode}): {proc.stderr.strip()[:240]}")

        with wave.open(str(wav_path), "rb") as wf:
            sr = wf.getframerate()
            raw = wf.readframes(wf.getnframes())
            samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            return samples, sr
    finally:
        wav_path.unlink(missing_ok=True)


class SenseVoiceASR:
    """Offline multilingual ASR powered by `sherpa-onnx` SenseVoice-Small + Silero-VAD."""

    engine_name = "sensevoice-small"

    def __init__(
        self,
        models_dir: Path | None = None,
        *,
        num_threads: int = 4,
        language: str = "",
        use_itn: bool = True,
        vad_threshold: float = 0.45,
        min_silence_duration: float = 0.45,
        min_speech_duration: float = 0.25,
        max_speech_duration: float = 22.0,
    ):
        self.models_dir = Path(models_dir) if models_dir else default_models_dir()
        self.num_threads = max(1, num_threads)
        self.language = language
        self.use_itn = use_itn
        self.vad_threshold = vad_threshold
        self.min_silence_duration = min_silence_duration
        self.min_speech_duration = min_speech_duration
        self.max_speech_duration = max_speech_duration
        self._recognizer: Any = None
        self._vad_config: Any = None

    def _ensure_loaded(self) -> None:
        if self._recognizer is not None:
            return
        import sherpa_onnx

        status = sensevoice_model_status(self.models_dir)
        if not status["sensevoice_ready"]:
            raise FileNotFoundError(
                f"SenseVoice-Small model not found under {self.models_dir}. "
                "Run `uv run context-collectors download-asr-models` first."
            )
        self._recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=status["model_path"],
            tokens=status["tokens_path"],
            num_threads=self.num_threads,
            sample_rate=16000,
            language=self.language,
            use_itn=self.use_itn,
            provider="cpu",
        )
        if status["silero_vad_ready"]:
            cfg = sherpa_onnx.VadModelConfig()
            cfg.silero_vad.model = status["vad_path"]
            cfg.silero_vad.threshold = self.vad_threshold
            cfg.silero_vad.min_silence_duration = self.min_silence_duration
            cfg.silero_vad.min_speech_duration = self.min_speech_duration
            cfg.silero_vad.max_speech_duration = self.max_speech_duration
            cfg.silero_vad.window_size = 512
            cfg.sample_rate = 16000
            cfg.num_threads = 1
            self._vad_config = cfg

    def _segment_with_vad(self, samples: Any, sr: int) -> list[tuple[float, float, Any]]:
        """Slice waveform into speech chunks via Silero-VAD, or fixed 20s windows if VAD absent."""
        if self._vad_config is None:
            win = 20 * sr
            out = []
            for start_i in range(0, len(samples), win):
                chunk = samples[start_i : start_i + win]
                if len(chunk) >= sr // 4:
                    out.append((start_i / sr, (start_i + len(chunk)) / sr, chunk))
            return out

        import sherpa_onnx

        vad = sherpa_onnx.VoiceActivityDetector(self._vad_config, buffer_size_in_seconds=120)
        window = self._vad_config.silero_vad.window_size
        segments: list[tuple[float, float, Any]] = []
        total = len(samples)
        for idx in range(0, total, window):
            chunk = samples[idx : idx + window]
            if len(chunk) < window:
                import numpy as np

                padded = np.zeros(window, dtype=np.float32)
                padded[: len(chunk)] = chunk
                vad.accept_waveform(padded)
            else:
                vad.accept_waveform(chunk)
            while not vad.empty():
                seg = vad.front
                seg_samples = seg.samples
                start_s = seg.start / sr
                end_s = (seg.start + len(seg_samples)) / sr
                segments.append((start_s, end_s, seg_samples))
                vad.pop()
        vad.flush()
        while not vad.empty():
            seg = vad.front
            seg_samples = seg.samples
            start_s = seg.start / sr
            end_s = (seg.start + len(seg_samples)) / sr
            segments.append((start_s, end_s, seg_samples))
            vad.pop()
        return segments

    def transcribe_file(self, audio_path: Path) -> ASRResult:
        t0 = time.perf_counter()
        self._ensure_loaded()
        samples, sr = decode_audio_to_pcm16k(audio_path)
        audio_seconds = len(samples) / float(sr) if sr > 0 else 0.0

        # Skip near-zero digital silence immediately
        if len(samples) < sr // 5 or float(max(abs(samples.min()), abs(samples.max()))) < 1e-4:
            return ASRResult(
                text="",
                spans=[],
                engine=self.engine_name,
                audio_seconds=round(audio_seconds, 2),
                speech_seconds=0.0,
                elapsed_ms=round((time.perf_counter() - t0) * 1000),
            )

        vad_segments = self._segment_with_vad(samples, sr)
        spans: list[ASRSpan] = []
        speech_seconds = 0.0
        detected_langs: set[str] = set()

        for start_s, end_s, seg_samples in vad_segments:
            dur = max(0.0, end_s - start_s)
            speech_seconds += dur
            stream = self._recognizer.create_stream()
            stream.accept_waveform(sr, seg_samples)
            self._recognizer.decode_stream(stream)
            res = stream.result
            txt = str(getattr(res, "text", "") or "").strip()
            lang = str(getattr(res, "lang", "") or "").strip()
            if lang:
                detected_langs.add(lang.strip("<>|"))
            if txt:
                spans.append(ASRSpan(start=start_s, end=end_s, text=txt))

        full_text = " ".join(s.text for s in spans).strip()
        locale = ",".join(sorted(detected_langs)) if detected_langs else (self.language or "auto")
        return ASRResult(
            text=full_text,
            spans=spans,
            engine=self.engine_name,
            locale=locale,
            audio_seconds=round(audio_seconds, 2),
            speech_seconds=round(speech_seconds, 2),
            elapsed_ms=round((time.perf_counter() - t0) * 1000),
        )
