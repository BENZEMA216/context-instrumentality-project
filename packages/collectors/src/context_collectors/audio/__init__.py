"""Audio channel collector (`Record for Agent` + CloudKit inbox) & offline SenseVoice ASR."""

from .asr import (
    ASRResult,
    ASRSpan,
    SenseVoiceASR,
    decode_audio_to_pcm16k,
    default_models_dir,
    ensure_sensevoice_models,
    sensevoice_model_status,
)
from .cloud_sync import (
    CloudPullReport,
    GoogleDriveAudioTransport,
    WebDAVAudioTransport,
    build_audio_soak_report,
    compress_to_m4a,
    pack_audio_packet,
    probe_cloud_endpoints,
    unpack_audio_packet,
)
from .collector import AudioCollector, AudioPaths, discover_audio_paths

__all__ = [
    "ASRResult",
    "ASRSpan",
    "AudioCollector",
    "AudioPaths",
    "CloudPullReport",
    "GoogleDriveAudioTransport",
    "SenseVoiceASR",
    "WebDAVAudioTransport",
    "build_audio_soak_report",
    "compress_to_m4a",
    "decode_audio_to_pcm16k",
    "default_models_dir",
    "discover_audio_paths",
    "ensure_sensevoice_models",
    "pack_audio_packet",
    "probe_cloud_endpoints",
    "sensevoice_model_status",
    "unpack_audio_packet",
]
