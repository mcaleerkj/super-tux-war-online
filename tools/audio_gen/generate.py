"""CLI for the Super Tux War audio pipeline.

    python generate.py --all                # every SFX + every song -> assets/audio/
    python generate.py --sfx jump stomp     # specific SFX (or: --sfx all)
    python generate.py --song menu --preview
    python generate.py --song menu --loop-check   # render loop 3x and play the seams
    python generate.py --list
    --wav-only    skip ffmpeg encode (debugging)
    --out-dir     override the assets/audio target
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np

from render import (
    check_loop_seam,
    encode_ogg,
    make_loop_preview,
    normalize,
    peak_dbfs,
    verify_sample_exact,
    write_wav,
)
from sfx import SFX

TOOL_DIR = Path(__file__).resolve().parent
GAME_AUDIO_DIR = TOOL_DIR.parents[1] / "assets" / "audio"
BUILD_DIR = TOOL_DIR / "build"

# SFX whose file must loop seamlessly (no declick trim, seam is checked).
LOOPING_SFX = {"skid"}


def _load_songs() -> dict:
    try:
        from songs import SONGS  # noqa: PLC0415
        return SONGS
    except ImportError:
        return {}


def _report(name: str, audio: np.ndarray, path: Path, seam: float | None) -> None:
    dur = audio.shape[0] / 44100.0
    seam_txt = f" seam={seam:.4f}" if seam is not None else ""
    print(f"  {name:14s} {dur:7.2f}s  peak={peak_dbfs(audio):6.2f} dBFS{seam_txt}  -> {path}")


def _preview(path: Path) -> None:
    try:
        subprocess.run(["ffplay", "-autoexit", "-nodisp", "-loglevel", "error", str(path)], check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        import os
        os.startfile(path)  # noqa: S606


def build_sfx(names: list[str], out_dir: Path, wav_only: bool, preview: bool) -> None:
    print(f"SFX -> {out_dir / 'sfx'}")
    for name in names:
        audio = normalize(SFX[name]())
        wav = write_wav(BUILD_DIR / "sfx" / f"{name}.wav", audio)
        seam = check_loop_seam(audio) if name in LOOPING_SFX else None
        target = BUILD_DIR / "sfx" / f"{name}.wav"
        if not wav_only:
            target = out_dir / "sfx" / f"{name}.ogg"
            encode_ogg(BUILD_DIR / "sfx" / f"{name}.wav", target, q=4)
            verify_sample_exact(wav, target)
        _report(name, audio, target, seam)
        if preview:
            _preview(target)


def build_songs(names: list[str], out_dir: Path, wav_only: bool, preview: bool,
                loop_check: bool) -> None:
    songs = _load_songs()
    print(f"Music -> {out_dir / 'music'}")
    for name in names:
        song = songs[name]
        from sequencer import render_song  # noqa: PLC0415
        audio = normalize(render_song(song))
        wav = write_wav(BUILD_DIR / "music" / f"{name}.wav", audio)
        seam = check_loop_seam(audio) if song.loop else None
        target = BUILD_DIR / "music" / f"{name}.wav"
        if not wav_only:
            target = out_dir / "music" / f"{name}.ogg"
            encode_ogg(BUILD_DIR / "music" / f"{name}.wav", target, q=5)
            verify_sample_exact(wav, target)
        _report(name, audio, target, seam)
        if loop_check:
            p = make_loop_preview(audio, BUILD_DIR / "music" / f"{name}_x3.wav")
            print(f"    loop preview (2 seams): {p}")
            _preview(p)
        elif preview:
            _preview(target)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--all", action="store_true", help="build every SFX and song")
    ap.add_argument("--sfx", nargs="+", metavar="NAME", help="SFX names, or 'all'")
    ap.add_argument("--song", nargs="+", metavar="NAME", help="song names, or 'all'")
    ap.add_argument("--list", action="store_true", help="list available assets")
    ap.add_argument("--preview", action="store_true", help="play each result (ffplay)")
    ap.add_argument("--loop-check", action="store_true", help="render song loop 3x and play it")
    ap.add_argument("--wav-only", action="store_true", help="skip OGG encode")
    ap.add_argument("--out-dir", type=Path, default=GAME_AUDIO_DIR)
    args = ap.parse_args(argv)

    songs = _load_songs()
    if args.list or not (args.all or args.sfx or args.song):
        print("SFX:  " + " ".join(sorted(SFX)))
        print("Songs: " + (" ".join(sorted(songs)) if songs else "(none yet)"))
        return 0

    sfx_names: list[str] = []
    song_names: list[str] = []
    if args.all:
        sfx_names = sorted(SFX)
        song_names = sorted(songs)
    if args.sfx:
        sfx_names = sorted(SFX) if args.sfx == ["all"] else args.sfx
    if args.song:
        song_names = sorted(songs) if args.song == ["all"] else args.song

    for name in sfx_names:
        if name not in SFX:
            ap.error(f"unknown sfx '{name}' (see --list)")
    for name in song_names:
        if name not in songs:
            ap.error(f"unknown song '{name}' (see --list)")

    if sfx_names:
        build_sfx(sfx_names, args.out_dir, args.wav_only, args.preview)
    if song_names:
        build_songs(song_names, args.out_dir, args.wav_only, args.preview, args.loop_check)
    return 0


if __name__ == "__main__":
    sys.exit(main())
