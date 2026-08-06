"""Title theme -- the flagship track. E dorian, 136 BPM, 40 bars (~71 s).

The closest homage to the Maniac Mansion NES idiom: driving octave-funk
triangle bass with chromatic pickups, syncopated pulse lead answered by a
composed dotted-8th echo, a surf turn (Am -> B7) in the B section, and a
bass+drums-only break. Original melody throughout.
"""

from sequencer import Channel, Song
from songs.instruments import BASS, LEAD50, SOFT125

# Bass vamp cells (all 16 sixteenths per bar).
_BA = "E2:2 E2:1 E3:1 r:2 E2:1 E3:1 r:1 E2:2 G2:1 A2:2 B2:2"
_BB = "E2:2 E2:1 E3:1 r:2 D3:2 C3:1 B2:2 A2:1 G2:1 F#2:1 E2:2"
_BC = "D2:2 D2:1 D3:1 r:2 D2:1 D3:1 r:1 D2:2 F#2:1 A2:2 C3:2"
_BD = "D2:2 D3:1 D2:1 r:1 C3:1 B2:2 A2:2 G2:1 F#2:1 D#2:2 E2:2"

_DRUM_MAIN = "K.hhS.h.h.KhS.hh"
_DRUM_OPEN = "K.hhS.h.h.KhS.hH"
_DRUM_FILL = "K.hhS.h.KKS.SSHh"
_DRUM_INTRO = "K...S...K.K.S..."

SONG = Song(
    name="menu",
    tempo=136,
    channels={
        "pulse1": Channel(LEAD50),
        "pulse2": Channel(SOFT125, echo_of="pulse1", echo_16ths=3, echo_vol=-6),
        "tri": Channel(BASS),
        "noise": Channel(),
    },
    sections={
        "intro": {
            "tri": f"{_BA} | {_BB} | {_BA} | {_BD}",
            "noise": f"{_DRUM_INTRO} | {_DRUM_INTRO} | {_DRUM_MAIN} | {_DRUM_FILL}",
        },
        "A": {
            "pulse1": (
                "r:2 E4:1 F#4:1 G4:2 B4:2 E5:3 D5:1 B4:2 A4:1 G4:1 | "
                "F#4:2 A4:2 F#4:1 E4:1 D4:2 F#4:4 r:2 A4:1 B4:1 | "
                "C5:2 B4:1 A4:1 B4:2 G4:2 E4:2 G4:2 A4:2 F#4:2 | "
                "B4:2 A4:1 G4:1 F#4:2 G4:1 F#4:1 E4:4 r:4 | "
                "r:2 E4:1 F#4:1 G4:2 B4:2 E5:3 D5:1 B4:2 A4:1 G4:1 | "
                "F#4:2 A4:2 F#4:1 E4:1 D4:2 F#4:2 A4:2 B4:2 C#5:2 | "
                "D5:2 C#5:1 B4:1 A4:2 B4:1 A4:1 G4:2 A4:2 B4:2 G4:2 | "
                "F#4:2 G4:2 F#4:1 D4:1 E4:6{vib} r:2 B3:1 E4:1"
            ),
            "tri": f"{_BA} | {_BB} | {_BC} | {_BD} | {_BA} | {_BB} | {_BC} | {_BD}",
            "noise": f"{_DRUM_MAIN} | {_DRUM_OPEN} | {_DRUM_MAIN} | {_DRUM_OPEN} | "
                     f"{_DRUM_MAIN} | {_DRUM_OPEN} | {_DRUM_MAIN} | {_DRUM_FILL}",
        },
        "A2": {
            "pulse1": (
                "r:2 G4:1 A4:1 B4:2 D5:2 G5:3 F#5:1 D5:2 C5:1 B4:1 | "
                "A4:2 C5:2 A4:1 G4:1 F#4:2 A4:4 r:2 C5:1 D5:1 | "
                "E5:2 D5:1 C5:1 D5:2 B4:2 G4:2 B4:2 C5:2 A4:2 | "
                "D5:2 C5:1 B4:1 A4:2 B4:1 A4:1 G4:4 r:4 | "
                "r:2 G4:1 A4:1 B4:2 D5:2 G5:3 F#5:1 D5:2 C5:1 B4:1 | "
                "A4:2 C5:2 A4:1 G4:1 F#4:2 A4:2 C5:2 D5:2 E5:2 | "
                "F#5:2 E5:1 D5:1 C#5:2 D5:1 C#5:1 B4:2 C5:2 B4:2 A4:2 | "
                "G4:2 F#4:2 G4:1 A4:1 B4:6{vib} r:2 D5:1 E5:1"
            ),
            "tri": f"{_BA} | {_BB} | {_BC} | {_BD} | {_BA} | {_BB} | {_BC} | {_BD}",
            "noise": f"{_DRUM_MAIN} | {_DRUM_OPEN} | {_DRUM_MAIN} | {_DRUM_OPEN} | "
                     f"{_DRUM_MAIN} | {_DRUM_OPEN} | {_DRUM_MAIN} | {_DRUM_FILL}",
        },
        "B": {
            "pulse1": (
                "E5:2 C5:2 A4:2 C5:2 E5:4 D5:2 C5:2 | "
                "D5:2 C5:2 B4:2 A4:2 G4:4 A4:2 B4:2 | "
                "D#5:2 B4:2 F#4:2 B4:2 D#5:4 C#5:2 B4:2 | "
                "C#5:2 B4:2 A4:2 F#4:2 D#4:4 F#4:2 A4:2 | "
                "E5:2 C5:2 A4:2 C5:2 E5:4 D5:2 C5:2 | "
                "D5:2 C5:2 B4:2 A4:2 G4:4 A4:2 B4:2 | "
                "D#5:2 B4:2 F#4:2 B4:2 D#5:4 C#5:2 B4:2 | "
                "B4:2 A4:2 G4:2 F#4:2 E4:2 D#4:2 E4:2 F#4:2"
            ),
            # Explicit pulse2 harmony (a third-ish below) suppresses the echo here.
            "pulse2": (
                "C5:2 A4:2 E4:2 A4:2 C5:4 B4:2 A4:2 | "
                "B4:2 A4:2 G4:2 E4:2 E4:4 F#4:2 G4:2 | "
                "B4:2 F#4:2 D#4:2 F#4:2 B4:4 A4:2 F#4:2 | "
                "A4:2 F#4:2 E4:2 D#4:2 B3:4 D#4:2 F#4:2 | "
                "C5:2 A4:2 E4:2 A4:2 C5:4 B4:2 A4:2 | "
                "B4:2 A4:2 G4:2 E4:2 E4:4 F#4:2 G4:2 | "
                "B4:2 F#4:2 D#4:2 F#4:2 B4:4 A4:2 F#4:2 | "
                "G4:2 F#4:2 E4:2 D#4:2 C#4:2 B3:2 C#4:2 D#4:2"
            ),
            "tri": (
                "A2:2 A2:1 A3:1 r:2 A2:1 A3:1 r:1 A2:2 C3:1 D3:2 E3:2 | "
                "A2:2 A3:1 A2:1 r:1 G2:1 F2:2 E2:2 F2:1 E2:1 D2:2 C2:2 | "
                "B2:2 B2:1 B3:1 r:2 B2:1 B3:1 r:1 B2:2 D#3:1 F#3:2 A3:2 | "
                "A3:2 G3:1 F#3:1 E3:2 D#3:2 D3:2 C#3:2 C3:2 B2:2 | "
                "A2:2 A2:1 A3:1 r:2 A2:1 A3:1 r:1 A2:2 C3:1 D3:2 E3:2 | "
                "A2:2 A3:1 A2:1 r:1 G2:1 F2:2 E2:2 F2:1 E2:1 D2:2 C2:2 | "
                "B2:2 B2:1 B3:1 r:2 B2:1 B3:1 r:1 B2:2 D#3:1 F#3:2 A3:2 | "
                "B2:2 B3:2 A2:1 A3:1 G2:1 G3:1 F#2:1 F#3:1 F#2:2 D#2:2 B1:2"
            ),
            "noise": f"{_DRUM_MAIN} | {_DRUM_OPEN} | {_DRUM_MAIN} | {_DRUM_OPEN} | "
                     f"{_DRUM_MAIN} | {_DRUM_OPEN} | {_DRUM_MAIN} | {_DRUM_FILL}",
        },
        "break": {
            "tri": (
                "E2:1 r:1 E2:1 E3:1 r:2 E2:1 r:1 E3:1 r:2 D3:1 r:1 E3:1 r:2 | "
                "E2:1 r:1 E2:1 E3:1 r:2 G2:1 r:1 A2:1 r:2 B2:1 r:1 D3:1 r:2 | "
                "E2:1 r:1 E2:1 E3:1 r:2 E2:1 r:1 E3:1 r:2 D3:1 r:1 E3:1 r:2 | "
                "E2:1 r:1 E3:1 r:1 D3:1 r:1 C3:1 r:1 B2:1 r:1 A2:1 r:1 G2:1 F#2:1 D#2:1 E2:1"
            ),
            "noise": "K..KS..K..KKS.S. | K..KS..K..KKS.S. | K..KS..K..KKS.S. | K.KKS.KKSS.SSSHh",
        },
    },
    arrangement=["intro", "A", "A2", "B", "break", "A"],
)
