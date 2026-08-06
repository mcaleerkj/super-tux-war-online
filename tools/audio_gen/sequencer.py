"""Song data model, mini-notation parser, and the loop-exact compiler.

Pitch channels (pulse1/pulse2/tri) use whitespace-separated tokens:
    E4:2 G4:1 r B4:2{vib} ~ | ...
  - note name + ':' + duration in 16ths (default 1, floats allowed)
  - 'r' rest, '~' tie (extends the previous note, no re-attack)
  - effects in braces, comma-separated: {vib} {arp=047} {slide=G4} {d=25}
    (duty % override) {v=9} (volume scale, 0-15) {stac} (gate at 50%)
  - '|' bar check: parser errors if a bar's 16ths don't sum to the bar length.

Noise channel: one char per 16th -- K kick, S snare, h closed hat, H open
hat, T tom, '.' rest, '-' sustain (treated as rest). Same '|' bar checks.

Loop-exactness: total length is round(bars * beats * 60/BPM * SR) samples;
any clip audio past the end (final-bar releases, late echoes) wraps modulo
the buffer into the loop start. No DSP reverb/delay exists, so wrapped
material is only envelope tails and composed echoes -- the seam is silent
by construction.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from nes_synth import (
    SAMPLES_PER_FRAME,
    SR,
    Env,
    Instrument,
    note_to_freq,
    render_dpcm_tom,
    render_noise,
    render_pulse,
    render_triangle,
)

SIXTEENTH = 0.25  # of a beat


@dataclass
class Channel:
    instrument: Instrument | None = None
    echo_of: str | None = None  # auto-generate from this channel's events
    echo_16ths: int = 3         # the classic dotted-8th NES echo
    echo_vol: int = -6          # 4-bit volume steps subtracted from source


@dataclass
class Song:
    name: str
    tempo: float
    channels: dict[str, Channel]
    sections: dict[str, dict[str, str]]
    arrangement: list[str]
    beats_per_bar: int = 4
    swing: float = 0.0  # 0..0.33, delay applied to off-16ths
    loop: bool = True


@dataclass
class NoteEvent:
    start: float  # in 16ths from song start
    dur: float    # in 16ths
    freq: float | None  # None = drum slot
    drum: str | None = None
    fx: dict = field(default_factory=dict)


_DRUMS = "KShHT"


def parse_pitch(text: str, sixteenths_per_bar: int, where: str) -> list[NoteEvent]:
    events: list[NoteEvent] = []
    pos = 0.0
    bar_fill = 0.0
    bar_no = 1
    for token in text.split():
        if token == "|":
            if abs(bar_fill - sixteenths_per_bar) > 1e-6:
                raise ValueError(f"{where}: bar {bar_no} has {bar_fill} 16ths, want {sixteenths_per_bar}")
            bar_fill = 0.0
            bar_no += 1
            continue
        fx: dict = {}
        if "{" in token:
            token, _, fx_part = token.partition("{")
            for part in fx_part.rstrip("}").split(","):
                k, _, v = part.partition("=")
                fx[k.strip()] = v.strip() if v else True
        name, _, dur_txt = token.partition(":")
        dur = float(dur_txt) if dur_txt else 1.0
        if name == "~":
            if not events or events[-1].freq is None:
                raise ValueError(f"{where}: bar {bar_no}: tie with nothing to extend")
            events[-1].dur += dur
        elif name == "r":
            pass
        else:
            events.append(NoteEvent(pos, dur, note_to_freq(name), fx=fx))
        pos += dur
        bar_fill += dur
    if bar_fill > 1e-6 and abs(bar_fill - sixteenths_per_bar) > 1e-6:
        raise ValueError(f"{where}: final bar {bar_no} has {bar_fill} 16ths, want {sixteenths_per_bar}")
    return events


def parse_noise(text: str, sixteenths_per_bar: int, where: str) -> list[NoteEvent]:
    events: list[NoteEvent] = []
    pos = 0
    bar_fill = 0
    bar_no = 1
    for ch in text:
        if ch.isspace():
            continue
        if ch == "|":
            if bar_fill != sixteenths_per_bar:
                raise ValueError(f"{where}: bar {bar_no} has {bar_fill} 16ths, want {sixteenths_per_bar}")
            bar_fill = 0
            bar_no += 1
            continue
        if ch in _DRUMS:
            events.append(NoteEvent(float(pos), 1.0, None, drum=ch))
        elif ch not in ".-":
            raise ValueError(f"{where}: bar {bar_no}: bad drum char {ch!r}")
        pos += 1
        bar_fill += 1
    if bar_fill and bar_fill != sixteenths_per_bar:
        raise ValueError(f"{where}: final bar {bar_no} has {bar_fill} 16ths, want {sixteenths_per_bar}")
    return events


def _pattern_16ths(text: str, is_noise: bool) -> float:
    if is_noise:
        return float(sum(1 for c in text if c in _DRUMS or c in ".-"))
    total = 0.0
    for token in text.split():
        if token == "|":
            continue
        token = token.partition("{")[0]
        _, _, dur_txt = token.partition(":")
        total += float(dur_txt) if dur_txt else 1.0
    return total


_DUTY_MAP = {"125": 0.125, "12.5": 0.125, "25": 0.25, "50": 0.5}
_DEFAULT_VIB = (6, 5.5, 0.12)


def _note_clip(ev: NoteEvent, inst: Instrument, n_samples: int, is_triangle: bool) -> np.ndarray:
    n_frames = max(1, -(-n_samples // SAMPLES_PER_FRAME))
    freq_f = np.full(n_frames, ev.freq)
    if "slide" in ev.fx:
        target = note_to_freq(ev.fx["slide"])
        semis = 12.0 * np.log2(target / ev.freq)
        freq_f *= 2.0 ** (np.linspace(0.0, semis, n_frames) / 12.0)
    arp = ev.fx.get("arp") or inst.arp
    if arp:
        offsets = np.array([float(c) for c in arp])
        freq_f *= 2.0 ** (offsets[np.arange(n_frames) % offsets.size] / 12.0)
    vib = inst.vibrato if inst.vibrato else (_DEFAULT_VIB if "vib" in ev.fx else None)
    if vib:
        delay, rate, depth = vib
        i = np.arange(n_frames, dtype=np.float64)
        lfo = np.where(i >= delay, np.sin(2 * np.pi * rate * (i - delay) / 60.0), 0.0)
        freq_f *= 2.0 ** (depth * lfo / 12.0)

    gate_frames = n_frames
    if "stac" in ev.fx:
        gate_frames = max(1, n_frames // 2)

    if is_triangle:
        gate = np.zeros(n_frames)
        gate[:gate_frames] = 1.0
        clip = render_triangle(freq_f, gate, n_samples)
        return _edge_fade(clip, 22, 132)

    env = inst.env or _FALLBACK_ENV
    vol_f = env.frames(n_frames).astype(np.float64)
    if gate_frames < n_frames:
        vol_f = vol_f.copy()
        vol_f[gate_frames:] = 0.0
    if "v" in ev.fx:
        vol_f = vol_f * (float(ev.fx["v"]) / 15.0)
    duty = _DUTY_MAP[ev.fx["d"]] if "d" in ev.fx else inst.duty
    clip = render_pulse(freq_f, vol_f, duty, n_samples)
    return _edge_fade(clip, 22, 88)


def _edge_fade(clip: np.ndarray, n_in: int, n_out: int) -> np.ndarray:
    n_in = min(n_in, clip.size // 2)
    n_out = min(n_out, clip.size // 2)
    if n_in > 0:
        clip[:n_in] *= np.linspace(0.0, 1.0, n_in)
    if n_out > 0:
        clip[-n_out:] *= np.linspace(1.0, 0.0, n_out)
    return clip


def _drum_clip(drum: str, limit: int | None = None) -> np.ndarray:
    """Render a drum at natural length; the noise channel is monophonic, so
    the caller passes `limit` = samples until the next drum hit, and forced
    cuts get a short fade to stay click-free at loop wrap points."""
    if drum == "K":
        clip = render_noise([13, 14, 14], [14, 9, 3, 0], 4 * SAMPLES_PER_FRAME)
    elif drum == "S":
        clip = render_noise([7, 7, 7, 8], [13, 10, 6, 3, 0], 5 * SAMPLES_PER_FRAME)
    elif drum == "h":
        clip = render_noise([1, 1], [8, 4, 0], 3 * SAMPLES_PER_FRAME)
    elif drum == "H":
        clip = render_noise([2, 2, 2, 2], [9, 7, 5, 3, 2, 1, 0], 8 * SAMPLES_PER_FRAME)
    elif drum == "T":
        clip = render_dpcm_tom(110.0, 50.0, 0.1, vol=0.8)
    else:
        raise ValueError(drum)
    if limit is not None and clip.size > limit > 0:
        clip = clip[:limit].copy()
        fade = min(66, clip.size)
        clip[-fade:] *= np.linspace(1.0, 0.0, fade)
    return clip


_FALLBACK_ENV = Env([15, 12, 10, 9, 8, 7, 7, 6, 6, 5])


def compile_song(song: Song) -> dict[str, np.ndarray]:
    """Returns channel name -> full-length audio buffer (mono, unmixed)."""
    spb = song.beats_per_bar * 4  # 16ths per bar

    # Per-channel event lists across the arrangement, in absolute 16ths.
    events: dict[str, list[NoteEvent]] = {name: [] for name in song.channels}
    cursor = 0.0
    section_bars: dict[str, float] = {}
    for sec_name in song.arrangement:
        sec = song.sections[sec_name]
        bars = None
        for ch_name, text in sec.items():
            got = _pattern_16ths(text, ch_name == "noise") / spb
            if bars is None:
                bars = got
            elif abs(got - bars) > 1e-6:
                raise ValueError(f"{song.name}/{sec_name}: channel '{ch_name}' is {got} bars, others {bars}")
        if bars is None:
            raise ValueError(f"{song.name}/{sec_name}: empty section")
        section_bars[sec_name] = bars
        for ch_name, text in sec.items():
            where = f"{song.name}/{sec_name}/{ch_name}"
            parsed = (parse_noise if ch_name == "noise" else parse_pitch)(text, spb, where)
            for ev in parsed:
                ev.start += cursor
                events[ch_name].append(ev)
        cursor += bars * spb
    total_16ths = cursor

    # Auto-echo: fill echo channels from their source, but only in sections
    # where the echo channel has no explicit pattern of its own.
    sec_starts: list[tuple[float, float, str]] = []
    at = 0.0
    for sec_name in song.arrangement:
        sec_starts.append((at, at + section_bars[sec_name] * spb, sec_name))
        at += section_bars[sec_name] * spb
    for ch_name, ch in song.channels.items():
        if not ch.echo_of:
            continue
        explicit = {s for a, b, s in sec_starts if ch_name in song.sections[s]}
        for src in events[ch.echo_of]:
            sec = next((s for a, b, s in sec_starts if a <= src.start < b), None)
            if sec in explicit:
                continue
            fx = dict(src.fx)
            scale = max(0.0, (15.0 + ch.echo_vol) / 15.0) * float(fx.pop("v", 15)) / 15.0
            fx["v"] = scale * 15.0
            events[ch_name].append(NoteEvent(src.start + ch.echo_16ths, src.dur, src.freq, fx=fx))

    # Timing grid with swing: off-16ths are delayed, totals stay bar-exact.
    base = 60.0 / song.tempo * SIXTEENTH
    total_samples = round(total_16ths * base * SR)

    def grid(pos_16th: float) -> int:
        idx = int(pos_16th)
        frac = pos_16th - idx
        swing_off = song.swing if idx % 2 == 1 else 0.0
        return round((pos_16th + swing_off * (1.0 - frac)) * base * SR)

    tail = 0 if song.loop else int(0.6 * SR)
    out: dict[str, np.ndarray] = {}
    for ch_name, ch in song.channels.items():
        buf = np.zeros(total_samples + tail)
        is_tri = ch_name == "tri"
        chan_events = sorted(events[ch_name], key=lambda e: e.start)
        for i, ev in enumerate(chan_events):
            start = grid(ev.start)
            if ev.drum:
                # Monophonic noise channel: ring until the next hit (wrapping
                # to the first hit of the next loop iteration at the end).
                if i + 1 < len(chan_events):
                    limit = grid(chan_events[i + 1].start) - start
                elif song.loop and chan_events:
                    limit = total_samples + grid(chan_events[0].start) - start
                else:
                    limit = None
                clip = _drum_clip(ev.drum, limit)
            else:
                n = grid(ev.start + ev.dur) - start
                if n <= 0:
                    continue
                clip = _note_clip(ev, ch.instrument or Instrument(), n, is_tri)
            _place(buf, clip, start, total_samples if song.loop else buf.size)
        out[ch_name] = buf
    return out


def _place(buf: np.ndarray, clip: np.ndarray, start: int, wrap_at: int) -> None:
    start = start % wrap_at
    end = start + clip.size
    if end <= wrap_at:
        buf[start:end] += clip
        return
    first = wrap_at - start
    buf[start:wrap_at] += clip[:first]
    rest = clip[first:]
    if rest.size > wrap_at:  # clip longer than the whole loop; clamp
        rest = rest[:wrap_at]
    buf[: rest.size] += rest[: buf.size]


def render_song(song: Song) -> np.ndarray:
    """Compile, balance-mix, and stereo-spread a song. Returns (N, 2)."""
    from render import pan_spread
    channels = compile_song(song)
    return pan_spread(channels, spread=0.25 if song.loop else 0.15)
