"""Level 01 "Tux's Castle" -- upbeat, confident. C mixolydian, 144 BPM,
48 bars (~80 s). Marching root-fifth-octave funk bass, bold 50% lead,
B section doubled in 6ths, machine-gun arp turnaround.
"""

from sequencer import Channel, Song
from songs.instruments import BASS, LEAD50, SOFT125

_C1 = "C2:2 C2:1 C3:1 r:2 C2:1 C3:1 r:1 C2:2 E2:1 G2:2 A2:2"
_C2 = "Bb1:2 Bb1:1 Bb2:1 r:2 Bb1:1 Bb2:1 r:1 Bb1:2 D2:1 F2:2 G2:2"
_C4 = "F2:2 F2:1 F3:1 r:2 F2:2 G2:2 A2:2 Bb2:1 B2:1 C3:2"
_F1 = "F2:2 F2:1 F3:1 r:2 F2:1 F3:1 r:1 F2:2 A2:1 C3:2 D3:2"
_G1 = "G2:2 G2:1 G3:1 r:2 G2:1 G3:1 r:1 G2:2 B2:1 D3:2 F3:2"
_GW = "G2:2 G3:2 F3:2 E3:2 D3:2 C3:2 B2:2 Bb2:2"

_DM = "K.hhS.h.K.hhS.hh"
_DO = "K.hhS.h.K.hhS.hH"
_DF = "K.hhS.h.KKSSK.SS"
_DI = "K...K...K...K.S."

_BASS_A = f"{_C1} | {_C2} | {_C1} | {_C4} | {_C1} | {_C2} | {_C1} | {_C4}"
_DRUM_8 = f"{_DM} | {_DO} | {_DM} | {_DO} | {_DM} | {_DO} | {_DM} | {_DF}"

SONG = Song(
    name="level01",
    tempo=144,
    channels={
        "pulse1": Channel(LEAD50),
        "pulse2": Channel(SOFT125, echo_of="pulse1", echo_16ths=3, echo_vol=-6),
        "tri": Channel(BASS),
        "noise": Channel(),
    },
    sections={
        "intro": {
            "tri": f"{_C1} | {_C2} | {_C1} | {_C4}",
            "noise": f"{_DI} | {_DI} | {_DM} | {_DF}",
        },
        "A": {
            "pulse1": (
                "G4:2 E4:1 F4:1 G4:2 C5:2 E5:3 D5:1 C5:2 A4:2 | "
                "Bb4:2 A4:1 G4:1 F4:2 G4:1 A4:1 G4:4 r:2 E4:1 F4:1 | "
                "G4:2 E4:1 F4:1 G4:2 C5:2 E5:2 G5:2 F5:2 D5:2 | "
                "E5:2 D5:1 C5:1 D5:2 Bb4:2 C5:6 r:2 | "
                "G4:2 E4:1 F4:1 G4:2 C5:2 E5:3 D5:1 C5:2 A4:2 | "
                "Bb4:2 A4:1 G4:1 F4:2 G4:1 A4:1 G4:4 r:2 E4:1 F4:1 | "
                "A4:2 C5:2 B4:1 Bb4:1 A4:2 F5:2 E5:2 D5:2 C5:2 | "
                "D5:2 C5:1 Bb4:1 A4:2 G4:1 F4:1 E4:2 F4:2 D4:2 C4:2"
            ),
            "tri": _BASS_A,
            "noise": _DRUM_8,
        },
        "B": {
            "pulse1": (
                "A4:2 C5:2 D5:2 C5:2 A4:4 F4:2 G4:2 | "
                "A4:2 C5:2 D5:2 F5:2 E5:4 C5:2 A4:2 | "
                "G4:2 C5:2 E5:2 C5:2 G5:4 E5:2 C5:2 | "
                "E5:2 D5:2 C5:2 D5:2 E5:4 D5:2 C5:2 | "
                "A4:2 C5:2 D5:2 C5:2 A4:4 F4:2 G4:2 | "
                "A4:2 C5:2 D5:2 F5:2 E5:4 C5:2 A4:2 | "
                "B4:2 D5:2 F5:2 D5:2 G5:4 F5:2 D5:2 | "
                "F5:2 E5:2 D5:2 C5:2 B4:2 Bb4:2 A4:2 G4:2"
            ),
            # Explicit 6ths-below double replaces the echo in this section.
            "pulse2": (
                "C4:2 E4:2 F4:2 E4:2 C4:4 A3:2 Bb3:2 | "
                "C4:2 E4:2 F4:2 A4:2 G4:4 E4:2 C4:2 | "
                "Bb3:2 E4:2 G4:2 E4:2 Bb4:4 G4:2 E4:2 | "
                "G4:2 F4:2 E4:2 F4:2 G4:4 F4:2 E4:2 | "
                "C4:2 E4:2 F4:2 E4:2 C4:4 A3:2 Bb3:2 | "
                "C4:2 E4:2 F4:2 A4:2 G4:4 E4:2 C4:2 | "
                "D4:2 F4:2 A4:2 F4:2 B4:4 A4:2 F4:2 | "
                "A4:2 G4:2 F4:2 E4:2 D4:2 C4:2 C4:2 Bb3:2"
            ),
            "tri": f"{_F1} | {_F1} | {_C1} | {_C1} | {_F1} | {_F1} | {_G1} | {_GW}",
            "noise": _DRUM_8,
        },
        "turn": {
            "pulse1": "C5:16{arp=047} | Bb4:16{arp=047} | F4:16{arp=047} | G4:16{arp=047}",
            "tri": f"{_C1} | {_C2} | {_F1} | {_GW}",
            "noise": f"{_DM} | {_DO} | {_DM} | {_DF}",
        },
    },
    arrangement=["intro", "A", "A", "B", "A", "turn", "B"],
)
