"""2A03-flavored synthesizer core.

All modulation (volume envelopes, pitch sweeps, arps, vibrato) is stepped at
60 Hz "APU frames" and expanded to audio samples with zero-order hold -- this
frame quantization, not the oscillators, is what makes the output read as NES
rather than softsynth.

Enforced chip constraints: pulse duty in {12.5%, 25%, 50%}, 4-bit volume on
pulse/noise, 32-step envelope-less triangle, real 15-bit LFSR noise (both
feedback modes), pitch quantized to the 11-bit NTSC timer.
Relaxed: naive 44.1 kHz oscillators (mild aliasing = crunch), linear mixing.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

SR = 44100
FRAME_RATE = 60
SAMPLES_PER_FRAME = SR // FRAME_RATE  # 735 exactly
CPU = 1_789_773  # NTSC 2A03 clock

# NTSC noise-channel period table (CPU cycles per LFSR shift), indices 0-15.
NOISE_PERIODS = [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068]

_NOTE_OFFSETS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def note_to_freq(name: str) -> float:
    """'C4', 'F#3', 'Bb2' -> Hz (A4 = 440, before NES pitch quantization)."""
    letter = name[0].upper()
    rest = name[1:]
    semi = _NOTE_OFFSETS[letter]
    if rest and rest[0] in "#b":
        semi += 1 if rest[0] == "#" else -1
        rest = rest[1:]
    octave = int(rest)
    midi = semi + (octave + 1) * 12
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


def nes_pitch(freq_hz: float) -> float:
    """Quantize to the 11-bit pulse timer: f = CPU / (16*(t+1)), t in 0..2047.

    Produces the authentic slight detune, most audible in high registers.
    """
    if freq_hz <= 0.0:
        return 0.0
    t = int(round(CPU / (16.0 * freq_hz) - 1.0))
    t = max(0, min(2047, t))
    return CPU / (16.0 * (t + 1))


def nes_pitch_arr(freq: np.ndarray) -> np.ndarray:
    f = np.asarray(freq, dtype=np.float64)
    out = np.zeros_like(f)
    nz = f > 0
    t = np.clip(np.round(CPU / (16.0 * f[nz]) - 1.0), 0, 2047)
    out[nz] = CPU / (16.0 * (t + 1))
    return out


def frames_to_samples(values, n_samples: int) -> np.ndarray:
    """Expand a 60 Hz frame array to per-sample with zero-order hold."""
    v = np.asarray(values, dtype=np.float64)
    if v.size == 0:
        return np.zeros(n_samples)
    out = np.repeat(v, SAMPLES_PER_FRAME)
    if out.size < n_samples:
        out = np.concatenate([out, np.full(n_samples - out.size, v[-1])])
    return out[:n_samples]


def _phase(freq_s: np.ndarray) -> np.ndarray:
    """Cumulative phase in cycles from a per-sample frequency array."""
    return np.cumsum(freq_s) / SR


def quantize_vol(vol_s: np.ndarray) -> np.ndarray:
    """4-bit (16-step) volume quantization, input/output in 0..1."""
    return np.round(np.clip(vol_s, 0.0, 1.0) * 15.0) / 15.0


def render_pulse(freq_f, vol_f, duty_f, n_samples: int, phase0: float = 0.0) -> np.ndarray:
    """Pulse channel. freq_f in Hz, vol_f in 0..15, duty_f in {0.125, 0.25, 0.5}.

    All three are 60 Hz frame arrays (scalars allowed for duty).
    """
    freq_s = nes_pitch_arr(frames_to_samples(freq_f, n_samples))
    vol_s = quantize_vol(frames_to_samples(np.asarray(vol_f, dtype=np.float64) / 15.0, n_samples))
    if np.isscalar(duty_f):
        duty_s = np.full(n_samples, float(duty_f))
    else:
        duty_s = frames_to_samples(duty_f, n_samples)
    ph = (_phase(freq_s) + phase0) % 1.0
    wave = np.where(ph < duty_s, 1.0, -1.0)
    wave[freq_s <= 0] = 0.0
    return (wave * vol_s).astype(np.float64)


def render_triangle(freq_f, gate_f, n_samples: int) -> np.ndarray:
    """Triangle channel: 32-step staircase, NO volume envelope (gate only)."""
    freq_s = nes_pitch_arr(frames_to_samples(freq_f, n_samples))
    gate_s = frames_to_samples(gate_f, n_samples)
    # ~1.5 ms smoothing on the gate only, to de-click on/off edges.
    kernel = np.ones(64) / 64.0
    gate_s = np.convolve(gate_s, kernel, mode="same")
    ph = _phase(freq_s) % 1.0
    tri = 2.0 * np.abs(2.0 * ph - 1.0) - 1.0
    steps = np.floor((tri * 0.5 + 0.5) * 31.9999)
    tri_q = steps / 31.0 * 2.0 - 1.0
    tri_q[freq_s <= 0] = 0.0
    return tri_q * gate_s


_LFSR_CACHE: dict[int, np.ndarray] = {}


def _lfsr_sequence(mode: int) -> np.ndarray:
    """Full-period 15-bit LFSR bit sequence. mode 0: bit0^bit1 (32767 steps);
    mode 1: bit0^bit6 (93-step periodic 'metallic' buzz)."""
    if mode in _LFSR_CACHE:
        return _LFSR_CACHE[mode]
    reg = 1
    tap = 1 if mode == 0 else 6
    length = 32767 if mode == 0 else 93
    bits = np.empty(length, dtype=np.float64)
    for i in range(length):
        bits[i] = 1.0 if (reg & 1) else -1.0
        fb = (reg & 1) ^ ((reg >> tap) & 1)
        reg = (reg >> 1) | (fb << 14)
    bits -= bits.mean()  # remove DC (mode 1's short sequence is asymmetric)
    _LFSR_CACHE[mode] = bits
    return bits


def render_noise(period_f, vol_f, n_samples: int, mode: int = 0) -> np.ndarray:
    """Noise channel. period_f: frame array of indices 0-15 into NOISE_PERIODS
    (0 = hissiest/highest rate, 15 = lowest rumble). vol_f in 0..15."""
    idx_s = np.clip(frames_to_samples(period_f, n_samples), 0, 15)
    periods = np.asarray(NOISE_PERIODS, dtype=np.float64)
    cycles = periods[np.round(idx_s).astype(int)]
    shift_rate = CPU / cycles  # LFSR shifts per second
    shifts = np.cumsum(shift_rate) / SR
    seq = _lfsr_sequence(mode)
    bits = seq[np.floor(shifts).astype(np.int64) % seq.size]
    vol_s = quantize_vol(frames_to_samples(np.asarray(vol_f, dtype=np.float64) / 15.0, n_samples))
    return bits * vol_s


def render_dpcm_tom(f_start: float, f_end: float, dur_s: float, vol: float = 1.0) -> np.ndarray:
    """Fake DPCM drum: triangle pitch-drop resampled through ~8 kHz sample-hold
    and 7-bit quantization for the crunchy sampled-tom character."""
    n = int(round(dur_s * SR))
    t = np.arange(n) / SR
    freq = f_start * (f_end / f_start) ** (t / dur_s)
    ph = np.cumsum(freq) / SR % 1.0
    tri = 2.0 * np.abs(2.0 * ph - 1.0) - 1.0
    hold = int(round(SR / 8000.0))
    idx = (np.arange(n) // hold) * hold
    crunched = tri[idx]
    crunched = np.round(crunched * 63.0) / 63.0  # 7-bit
    env = np.exp(-t / (dur_s * 0.4))
    return crunched * env * vol


def declick(audio: np.ndarray, ms: float = 2.0) -> np.ndarray:
    """Linear fade-in/out over `ms` at both ends."""
    n = min(int(SR * ms / 1000.0), audio.shape[0] // 2)
    if n <= 0:
        return audio
    out = audio.copy()
    ramp = np.linspace(0.0, 1.0, n)
    out[:n] *= ramp
    out[-n:] *= ramp[::-1]
    return out


def sweep_frames(f0: float, f1: float, n_frames: int, curve: float = 1.0) -> np.ndarray:
    """Frequency sweep as a frame array. curve > 1 biases time toward f0
    (convex rise), < 1 toward f1."""
    t = np.linspace(0.0, 1.0, max(n_frames, 1)) ** curve
    return f0 * (f1 / f0) ** t


@dataclass
class Env:
    """FamiTracker-style 60 Hz volume table, values 0..15.

    sustain: index held while a note is gated (release plays the rest);
    None = one-shot (holds last value once exhausted).
    """

    values: list[int] = field(default_factory=lambda: [15, 0])
    sustain: int | None = None

    def frames(self, n_frames: int) -> np.ndarray:
        v = np.asarray(self.values, dtype=np.float64)
        if n_frames <= v.size:
            return v[:n_frames]
        return np.concatenate([v, np.full(n_frames - v.size, v[-1])])


@dataclass
class Instrument:
    """Playable instrument for the sequencer.

    duty: pulse duty (ignored by triangle/noise channels).
    env: volume table; None means gate-only (triangle).
    vibrato: (delay_frames, rate_hz, depth_semitones) or None.
    arp: FamiTracker-style semitone-offset string, e.g. '047', 1 frame/step.
    """

    duty: float = 0.5
    env: Env | None = None
    vibrato: tuple[int, float, float] | None = None
    arp: str | None = None
