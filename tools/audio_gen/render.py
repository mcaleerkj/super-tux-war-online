"""Mixdown, mastering, WAV/OGG output, and verification helpers."""

from __future__ import annotations

import subprocess
import wave
from pathlib import Path

import numpy as np

from nes_synth import SR

# Linear channel gains approximating APU balance: triangle sits ~+2 dB above
# the pulses, noise ~-3 dB under them. (The true APU nonlinear mixer formula
# is deliberately skipped -- linear with tuned gains is close enough here.)
APU_BALANCE = {"pulse1": 1.0, "pulse2": 1.0, "tri": 1.26, "noise": 0.71}


def mix(channels: dict[str, np.ndarray], gains: dict[str, float] | None = None) -> np.ndarray:
    gains = gains or APU_BALANCE
    n = max(c.shape[0] for c in channels.values())
    out = np.zeros(n)
    for name, audio in channels.items():
        g = gains.get(name, 1.0)
        out[: audio.shape[0]] += audio * g
    return out


def pan_spread(channels: dict[str, np.ndarray], spread: float = 0.25,
               gains: dict[str, float] | None = None) -> np.ndarray:
    """Music stereo: pulse1 spread% left, pulse2 spread% right, rest center.
    Constant-power panning. Returns (N, 2). spread=0 -> dual mono."""
    gains = gains or APU_BALANCE
    pans = {"pulse1": -spread, "pulse2": spread}
    n = max(c.shape[0] for c in channels.values())
    out = np.zeros((n, 2))
    for name, audio in channels.items():
        g = gains.get(name, 1.0)
        p = pans.get(name, 0.0)  # -1..1
        theta = (p + 1.0) * np.pi / 4.0
        left, right = np.cos(theta), np.sin(theta)
        out[: audio.shape[0], 0] += audio * g * left * np.sqrt(2.0)
        out[: audio.shape[0], 1] += audio * g * right * np.sqrt(2.0)
    return out


def normalize(audio: np.ndarray, peak_db: float = -1.0) -> np.ndarray:
    peak = float(np.max(np.abs(audio)))
    if peak == 0.0:
        raise ValueError("normalize: silent buffer")
    target = 10.0 ** (peak_db / 20.0)
    out = audio * (target / peak)
    assert float(np.max(np.abs(out))) <= 1.0, "clipping after normalize"
    return out


def peak_dbfs(audio: np.ndarray) -> float:
    peak = float(np.max(np.abs(audio)))
    return -np.inf if peak == 0.0 else 20.0 * np.log10(peak)


def check_loop_seam(audio: np.ndarray, threshold: float = 0.05) -> float:
    """Wrap-point step |last - first| vs the largest step anywhere in the song.

    Chip music is full of legitimate instant steps (square edges, drum
    attacks), so an absolute threshold is meaningless: the wrap step is fine
    as long as it's no bigger than steps the song already contains. The real
    seam guarantees are structural -- exact bar-length render, modulo-wrapped
    tails, per-clip fades -- this check is a sanity alarm on top.
    """
    if audio.ndim == 1:
        wrap = abs(float(audio[-1]) - float(audio[0]))
        biggest = float(np.max(np.abs(np.diff(audio))))
    else:
        wrap = float(np.max(np.abs(audio[-1] - audio[0])))
        biggest = float(np.max(np.abs(np.diff(audio, axis=0))))
    if wrap > max(threshold, biggest):
        print(f"  WARNING: loop wrap step {wrap:.3f} exceeds song max step {biggest:.3f}")
    return wrap


def write_wav(path: Path, audio: np.ndarray) -> int:
    """int16 WAV; mono for 1-D input, stereo for (N, 2). Returns sample count."""
    path.parent.mkdir(parents=True, exist_ok=True)
    channels = 1 if audio.ndim == 1 else audio.shape[1]
    pcm = np.clip(audio, -1.0, 1.0)
    data = (pcm * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    return audio.shape[0]


def encode_ogg(wav: Path, ogg: Path, q: int) -> None:
    """MUST be libvorbis -- ffmpeg's builtin 'vorbis' encoder is experimental."""
    ogg.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav),
         "-c:a", "libvorbis", "-q:a", str(q), str(ogg)],
        check=True,
    )


def decoded_sample_count(ogg: Path) -> int:
    """Authoritative decoded length from the Ogg granule position (what Godot
    honors when looping). NOTE: piping through ffmpeg's PCM decode instead is
    NOT reliable -- its trim of the priming/final block is off by a block size.
    """
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "stream=duration_ts",
         "-of", "csv=p=0", str(ogg)],
        capture_output=True, text=True, check=True,
    )
    return int(proc.stdout.strip())


def verify_sample_exact(wav_samples: int, ogg: Path) -> bool:
    got = decoded_sample_count(ogg)
    ok = got == wav_samples
    if not ok:
        print(f"  WARNING: {ogg.name} granule length {got} samples, source WAV had {wav_samples}")
    return ok


def make_loop_preview(audio: np.ndarray, path: Path, repeats: int = 3) -> Path:
    tiled = np.tile(audio, (repeats,) if audio.ndim == 1 else (repeats, 1))
    write_wav(path, tiled)
    return path
