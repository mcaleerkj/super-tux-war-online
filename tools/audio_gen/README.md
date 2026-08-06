# audio_gen — NES-style audio pipeline

Generates every sound effect and music track in `assets/audio/` from code.
All compositions are **original** (Maniac Mansion NES *idiom* homage — funky
triangle bass, composed pulse echo, 60 Hz frame-locked modulation — with no
melodic quotation), so everything is MIT-licensed with the rest of the repo.

## Requirements

- Python 3.12+ with `numpy>=2.0` (`pip install -r requirements.txt`)
- `ffmpeg` on PATH (uses the `libvorbis` encoder; `ffplay` enables `--preview`)

## Usage

```
python generate.py --all                 # rebuild every SFX + song
python generate.py --sfx jump stomp     # specific SFX (or: --sfx all)
python generate.py --song menu --preview
python generate.py --song menu --loop-check   # render the loop 3x and listen to the seams
python generate.py --list
```

Output goes straight to `assets/audio/sfx/*.ogg` and `assets/audio/music/*.ogg`.
WAV intermediates land in `build/` (safe to delete). Regeneration is
deterministic — no randomness anywhere.

## Architecture

| File | Role |
|---|---|
| `nes_synth.py` | 2A03-flavored oscillators: pulse (12.5/25/50% duty, 4-bit volume), envelope-less 32-step triangle, 15-bit LFSR noise (both modes), fake-DPCM tom. All modulation steps at 60 Hz "APU frames". |
| `sequencer.py` | Song model + mini-notation parser (`E4:2 G4:1 r B4:2{vib} \| ...`, bar-length checked) + loop-exact compiler: total length is `round(bars x beats x 60/BPM x SR)` samples and tails wrap modulo the buffer into the loop start. |
| `sfx.py` | Each SFX as a recipe function. |
| `songs/` | One module per track; `instruments.py` is the shared palette. |
| `render.py` | APU-balance mix, stereo spread (music), −1 dBFS normalize with clipping assert, WAV out, ffmpeg OGG encode, granule-position length verification, loop-seam check. |

## Adding a song

Copy any module in `songs/`, keep every bar summing to 16 sixteenths (the
parser errors with the exact bar number if not), register it in
`songs/__init__.py`. Music loops must stay full-file loops: the game sets
`AudioStreamOggVorbis.loop = true` with no `loop_offset`.
