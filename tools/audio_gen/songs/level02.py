"""Level 02 "Beastie's Lair" -- darker, funkier. G minor, 116 BPM,
swing 0.08, 36 bars (~74 s). Slinky walking triangle with b5 chromatic
creep, stabby 12.5% duty lead full of rests, open hats on offbeat pushes.
"""

from sequencer import Channel, Song
from songs.instruments import BASS, SOFT125, STAB125

_G1 = "G2:2 G2:1 G3:1 r:2 G2:1 Bb2:1 r:1 C3:2 Db3:1 C3:2 Bb2:2"
_G2 = "G2:2 G2:1 G3:1 r:2 F2:1 F3:1 r:1 Eb3:2 D3:1 C3:2 Bb2:2"
_C1 = "C3:2 C3:1 C2:1 r:2 C3:1 Eb3:1 r:1 F3:2 Gb3:1 F3:2 Eb3:2"
_D1 = "D3:2 D2:1 D3:1 r:2 F#2:1 F#3:1 r:1 A2:2 C3:1 Eb3:2 D3:2"
_E1 = "Eb3:2 Eb2:1 Eb3:1 r:2 Eb2:1 Eb3:1 r:1 G2:2 Ab2:1 Bb2:2 C3:2"
_DW = "D3:2 D3:1 C3:1 Bb2:2 A2:2 Ab2:2 G2:2 Gb2:2 F2:1 D2:1"

_DM = "K.h.S.hhK.h.S.hH"
_DI = "K...S..hK..hS..h"
_DF = "K.h.S.hhKKS.SShH"

_S1 = "r:2 G4:1 r:1 Bb4:1 r:1 G4:1 r:2 D5:2 C5:1 Bb4:1 A4:1 Bb4:2"
_S2 = "r:2 G4:1 r:1 Bb4:1 r:1 C5:1 r:2 Db5:2 C5:1 Bb4:1 G4:1 F4:2"
_S3 = "r:4 F4:1 G4:1 Bb4:2 C5:4 r:2 Eb5:1 D5:1"
_S4 = "D5:2 C5:1 Bb4:1 A4:2 F#4:2 D4:2 F#4:2 A4:2 C5:2"
_S5 = "r:2 C5:1 r:1 Eb5:1 r:1 C5:1 r:2 G5:2 F5:1 Eb5:1 D5:1 Eb5:2"
_S6 = "r:2 C5:1 r:1 Eb5:1 r:1 F5:1 r:2 Gb5:2 F5:1 Eb5:1 C5:1 Bb4:2"

SONG = Song(
    name="level02",
    tempo=116,
    swing=0.08,
    channels={
        "pulse1": Channel(STAB125),
        "pulse2": Channel(SOFT125, echo_of="pulse1", echo_16ths=3, echo_vol=-7),
        "tri": Channel(BASS),
        "noise": Channel(),
    },
    sections={
        "intro": {
            "tri": f"{_G1} | {_G2} | {_G1} | {_D1}",
            "noise": f"{_DI} | {_DI} | {_DM} | {_DM}",
        },
        "A": {
            "pulse1": f"{_S1} | {_S2} | {_S1} | {_S3} | {_S5} | {_S6} | {_S1} | {_S4}",
            "tri": f"{_G1} | {_G2} | {_G1} | {_G2} | {_C1} | {_C1} | {_G1} | {_D1}",
            "noise": f"{_DM} | {_DM} | {_DM} | {_DF} | {_DM} | {_DM} | {_DM} | {_DF}",
        },
        "B": {
            "pulse1": (
                "Bb4:2 G4:2 Eb4:2 G4:2 Bb4:4 C5:2 Bb4:2 | "
                "C5:2 Bb4:2 G4:2 Bb4:2 C5:4 D5:2 Eb5:2 | "
                "D5:2 Bb4:2 G4:2 Bb4:2 D5:4 C5:2 Bb4:2 | "
                "C5:2 A4:2 F#4:2 A4:2 C5:4 Bb4:2 A4:2 | "
                "Bb4:2 G4:2 Eb4:2 G4:2 Bb4:4 C5:2 Bb4:2 | "
                "C5:2 Bb4:2 G4:2 Bb4:2 C5:4 D5:2 Eb5:2 | "
                "D5:2 Bb4:2 G4:2 Bb4:2 D5:4 C5:2 Bb4:2 | "
                "D5:2 C5:2 Bb4:2 A4:2 Bb4:2 G4:2 A4:2 F#4:2"
            ),
            "tri": f"{_E1} | {_E1} | {_G1} | {_G2} | {_E1} | {_E1} | {_D1} | {_DW}",
            "noise": f"{_DM} | {_DF} | {_DM} | {_DF} | {_DM} | {_DF} | {_DM} | {_DF}",
        },
    },
    arrangement=["intro", "A", "A", "B", "A"],
)
