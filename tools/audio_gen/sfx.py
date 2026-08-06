"""Every SFX as a synth recipe. Each function returns a mono float array;
generate.py normalizes to -1 dBFS and encodes. All frame math is 60 Hz.

Design language: pulse sweeps for motion, triangle for weight, LFSR noise for
impact/texture. The stomp is the game's core verb -- it gets three layers.
"""

from __future__ import annotations

import numpy as np

from nes_synth import (
    SAMPLES_PER_FRAME,
    SR,
    declick,
    note_to_freq as nf,
    render_dpcm_tom,
    render_noise,
    render_pulse,
    render_triangle,
    sweep_frames,
)


def _n(frames: int) -> int:
    return frames * SAMPLES_PER_FRAME


def _mix(*layers: np.ndarray) -> np.ndarray:
    n = max(a.shape[0] for a in layers)
    out = np.zeros(n)
    for a in layers:
        out[: a.shape[0]] += a
    return out


def _env(*vals: int) -> np.ndarray:
    return np.asarray(vals, dtype=np.float64)


def sfx_jump() -> np.ndarray:
    # 50% pulse, convex rising sweep A3->A5 over ~120 ms, fast decay.
    freq = sweep_frames(nf("A3"), nf("A5"), 8, curve=1.6)
    vol = _env(15, 14, 12, 10, 8, 6, 3, 0)
    return declick(render_pulse(freq, vol, 0.5, _n(9)))


def sfx_jump_turbo() -> np.ndarray:
    # 25% duty C4->C6 sweep + 50% octave-up ghost layer; reads "stronger".
    frames = 11
    main = render_pulse(sweep_frames(nf("C4"), nf("C6"), 9, curve=1.5),
                        _env(15, 14, 13, 11, 9, 7, 5, 3, 1, 0), 0.25, _n(frames))
    ghost = render_pulse(sweep_frames(nf("C5"), nf("C7"), 9, curve=1.5),
                         _env(7, 6, 6, 5, 4, 3, 2, 1, 0), 0.5, _n(frames))
    return declick(_mix(main, ghost * 0.6))


def sfx_land() -> np.ndarray:
    # Triangle thud E3->A1 in ~60 ms + 1-frame noise tick.
    thud = render_triangle(sweep_frames(nf("E3"), nf("A1"), 4), _env(1, 1, 1, 1, 0), _n(6))
    tick = render_noise(_env(12), _env(9, 0), _n(2))
    return declick(_mix(thud, tick * 0.5))


def sfx_stomp() -> np.ndarray:
    # The core verb -- meaty, 3 layers: fake-DPCM tom drop, noise burst
    # sweeping dark, and a pulse impact blip.
    tom = render_dpcm_tom(nf("G3"), nf("G1"), 0.16)
    burst = render_noise(np.linspace(6, 13, 9), _env(15, 13, 10, 8, 6, 4, 3, 1, 0), _n(10))
    blip = render_pulse(sweep_frames(nf("C5"), nf("C4"), 2), _env(13, 6, 0), 0.5, _n(3))
    rumble = render_triangle(sweep_frames(nf("G2"), nf("C2"), 6), _env(1, 1, 1, 1, 1, 0), _n(7))
    return declick(_mix(tom, burst * 0.9, blip * 0.5, rumble * 0.6), ms=3.0)


def sfx_die() -> np.ndarray:
    # Classic downward tumble: 25% pulse chromatic gliss C5->C3 (one semitone
    # per frame), volume sagging, low triangle bump at the end.
    semis = np.arange(0, 25)
    freq = nf("C5") * 2.0 ** (-semis / 12.0)
    vol = np.round(np.linspace(14, 4, 25))
    gliss = render_pulse(freq, vol, 0.25, _n(25))
    bump = render_triangle(_env(*[nf("G1")] * 4), _env(1, 1, 1, 0), _n(5))
    out = _mix(gliss, np.concatenate([np.zeros(_n(24)), bump]))
    return declick(out)


def sfx_respawn() -> np.ndarray:
    # Exactly 0.8 s to match the spawn animation: 12.5% rising sparkle arp
    # over a triangle root, then a held high note with fading vibrato tail.
    frames = 48
    notes = ["C5", "E5", "G5", "C6", "E6", "G6"]
    freq = np.zeros(frames)
    vol = np.zeros(frames)
    for i, name in enumerate(notes):
        s = i * 5
        freq[s : s + 5] = nf(name)
        vol[s : s + 5] = [12, 10, 8, 6, 4]
    # held G6 with vibrato, fading over the last 18 frames
    t = np.arange(18)
    freq[30:] = nf("G6") * 2.0 ** (0.15 * np.sin(2 * np.pi * 5.0 * t / 60.0) / 12.0)
    vol[30:] = np.round(np.linspace(11, 0, 18))
    sparkle = render_pulse(freq, vol, 0.125, _n(frames))
    root = render_triangle(np.full(28, nf("C3")), np.concatenate([np.ones(26), np.zeros(2)]), _n(28))
    out = _mix(sparkle, root * 0.55)
    return declick(out[: int(0.8 * SR)])


def sfx_skid() -> np.ndarray:
    # Loopable screech: mode-1 periodic LFSR buzz with full-depth 30 Hz
    # tremolo. 9 whole tremolo cycles in 0.3 s and amplitude 0 at both ends,
    # so the file loops (and starts/stops) with no seam or click.
    n = int(0.3 * SR)
    frames = 18
    period = np.tile([7, 8], frames // 2)
    buzz = render_noise(period, np.full(frames, 12), n, mode=1)
    t = np.arange(n) / SR
    tremolo = 0.5 - 0.5 * np.cos(2 * np.pi * 30.0 * t)
    return buzz * tremolo


def sfx_score() -> np.ndarray:
    # Kill-credit "cha-ching": G5 grace into C6 pluck over a triangle tap.
    frames = 12
    freq = np.concatenate([[nf("G5")] * 2, [nf("C6")] * 10])
    vol = _env(12, 12, 15, 13, 11, 9, 7, 5, 4, 2, 1, 0)
    chime = render_pulse(freq, vol, 0.5, _n(frames))
    tap = render_triangle(np.full(3, nf("C4")), _env(1, 1, 0), _n(3))
    return declick(_mix(chime, tap * 0.4))


def sfx_match_start() -> np.ndarray:
    # "Go!": three snare hits on 16ths (136 BPM feel) into a unison C-major
    # stab -- both pulses + triangle root -- with a hard cutoff.
    hit_frames = 7  # ~one 16th at 136 BPM
    total = 48
    noise_p = np.zeros(total)
    noise_v = np.zeros(total)
    for i in range(3):
        s = i * hit_frames
        noise_p[s : s + 4] = 7
        noise_v[s : s + 4] = [13, 9, 5, 0]
    snare = render_noise(noise_p, noise_v, _n(total))
    stab_at = 3 * hit_frames
    stab_len = total - stab_at
    stab_env = _env(*(15, 15, 14, 13, 12, 11, 10, 9, 8, 8, 7, 7, 6, 6, 5, 5), *(4,) * (stab_len - 16))
    p1 = render_pulse(np.full(stab_len, nf("G4")), stab_env, 0.5, _n(stab_len))
    p2 = render_pulse(np.full(stab_len, nf("E5")), stab_env * 0.8, 0.25, _n(stab_len))
    tri = render_triangle(np.full(stab_len, nf("C3")),
                          np.concatenate([np.ones(stab_len - 2), np.zeros(2)]), _n(stab_len))
    kick = render_noise(_env(13, 14), _env(14, 8, 0), _n(3))
    stab = _mix(p1, p2, tri * 0.9, kick)
    out = _mix(snare, np.concatenate([np.zeros(_n(stab_at)), stab]))
    return declick(out)


def sfx_pause() -> np.ndarray:
    # Two-blip up: C5 -> G5.
    freq = np.concatenate([[nf("C5")] * 3, [nf("G5")] * 6])
    vol = _env(11, 10, 9, 13, 11, 8, 5, 3, 0)
    return declick(render_pulse(freq, vol, 0.5, _n(9)))


def sfx_unpause() -> np.ndarray:
    freq = np.concatenate([[nf("G5")] * 3, [nf("C5")] * 6])
    vol = _env(11, 10, 9, 13, 11, 8, 5, 3, 0)
    return declick(render_pulse(freq, vol, 0.5, _n(9)))


def sfx_ui_select() -> np.ndarray:
    # Confirm: C5 -> E5 + tiny triangle root tap. The universal button click.
    freq = np.concatenate([[nf("C5")] * 3, [nf("E5")] * 4])
    vol = _env(13, 12, 11, 13, 10, 6, 0)
    blip = render_pulse(freq, vol, 0.5, _n(7))
    tap = render_triangle(np.full(2, nf("C4")), _env(1, 0), _n(2))
    return declick(_mix(blip, tap * 0.35))


def sfx_ui_open() -> np.ndarray:
    # Airy 12.5% arp C5-E5-G5 for popups.
    freq = np.array([nf("C5"), nf("E5"), nf("G5"), nf("G5"), nf("G5"), nf("G5")])
    vol = _env(11, 11, 12, 8, 4, 0)
    return declick(render_pulse(freq, vol, 0.125, _n(6)))


def sfx_ui_move() -> np.ndarray:
    # Focus tick.
    return declick(render_pulse(np.full(3, nf("E5")), _env(12, 6, 0), 0.125, _n(3)))


def sfx_ui_back() -> np.ndarray:
    freq = np.concatenate([[nf("E5")] * 3, [nf("C5")] * 3])
    vol = _env(10, 9, 8, 9, 5, 0)
    return declick(render_pulse(freq, vol, 0.25, _n(6)))


def sfx_ui_tick() -> np.ndarray:
    # Micro click for +/- steppers.
    click = render_noise(_env(4), _env(9, 0), _n(1))
    blip = render_pulse(np.full(1, nf("G5")), _env(7), 0.5, int(0.015 * SR))
    return declick(_mix(click, blip), ms=1.0)


def sfx_gravestone() -> np.ndarray:
    # Comedic plop: triangle drop D3->G1 + quiet pulse "boink" bounce.
    plop = render_triangle(sweep_frames(nf("D3"), nf("G1"), 5), _env(1, 1, 1, 1, 0), _n(6))
    boink_f = np.array([nf("G2"), nf("C3"), nf("C3"), nf("G2"), nf("G2")])
    boink = render_pulse(boink_f, _env(7, 8, 6, 5, 0), 0.5, _n(6))
    return declick(_mix(plop, np.concatenate([np.zeros(_n(4)), boink])[: _n(12)] * 0.5))


def sfx_drop_through() -> np.ndarray:
    # Subtle down-chirp for phasing through a semisolid platform.
    chirp = render_pulse(sweep_frames(nf("B4"), nf("E4"), 3), _env(8, 6, 4, 0), 0.25, _n(4))
    whisper = render_noise(_env(3, 3), _env(3, 2, 0), _n(3))
    return declick(_mix(chirp, whisper * 0.4))


def sfx_coin() -> np.ndarray:
    # Classic bright two-blip coin: B5 grace into held E6.
    freq = np.concatenate([[nf("B5")] * 2, [nf("E6")] * 5])
    return declick(render_pulse(freq, _env(12, 12, 15, 12, 8, 4, 0), 0.5, _n(7)))


def sfx_tick() -> np.ndarray:
    # Countdown tick: ui_tick a semitone up, slightly longer blip.
    click = render_noise(_env(4), _env(9, 0), _n(1))
    blip = render_pulse(np.full(1, nf("G#5")), _env(9), 0.5, int(0.02 * SR))
    return declick(_mix(click, blip), ms=1.0)


def sfx_horn() -> np.ndarray:
    # Time-up horn: C4+G4 25% pulses held ~0.5 s over a triangle root.
    frames = 32
    env = np.concatenate([np.full(20, 13.0), np.round(np.linspace(12, 0, 12))])
    p1 = render_pulse(np.full(frames, nf("C4")), env, 0.25, _n(frames))
    p2 = render_pulse(np.full(frames, nf("G4")), env * 0.8, 0.25, _n(frames))
    tri = render_triangle(np.full(frames, nf("C3")),
                          np.concatenate([np.ones(frames - 2), np.zeros(2)]), _n(frames))
    return declick(_mix(p1, p2, tri * 0.8))


def sfx_whistle() -> np.ndarray:
    # Referee whistle for hill moves: 12.5% duty 9 Hz warble around E6.
    t = np.arange(21)
    freq = nf("E6") * 2.0 ** (0.8 * np.sin(2 * np.pi * 9.0 * t / 60.0) / 12.0)
    vol = np.concatenate([np.full(15, 12.0), _env(10, 8, 6, 4, 2, 0)])
    return declick(render_pulse(freq, vol, 0.125, _n(21)))


def sfx_cluck() -> np.ndarray:
    # Chicken transfer: two fast chirps (noise peck + falling A5->D5 blip).
    def chirp() -> np.ndarray:
        return _mix(render_noise(_env(5), _env(10, 0), _n(1)) * 0.6,
                    render_pulse(sweep_frames(nf("A5"), nf("D5"), 3), _env(12, 8, 4, 0), 0.25, _n(4)))
    return declick(np.concatenate([chirp(), np.zeros(_n(2)), chirp() * 0.85]))


SFX = {
    "jump": sfx_jump,
    "jump_turbo": sfx_jump_turbo,
    "land": sfx_land,
    "stomp": sfx_stomp,
    "die": sfx_die,
    "respawn": sfx_respawn,
    "skid": sfx_skid,
    "score": sfx_score,
    "match_start": sfx_match_start,
    "pause": sfx_pause,
    "unpause": sfx_unpause,
    "ui_select": sfx_ui_select,
    "ui_open": sfx_ui_open,
    "ui_move": sfx_ui_move,
    "ui_back": sfx_ui_back,
    "ui_tick": sfx_ui_tick,
    "gravestone": sfx_gravestone,
    "drop_through": sfx_drop_through,
    "coin": sfx_coin,
    "tick": sfx_tick,
    "horn": sfx_horn,
    "whistle": sfx_whistle,
    "cluck": sfx_cluck,
}
