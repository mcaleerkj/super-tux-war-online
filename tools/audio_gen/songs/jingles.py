"""Victory and defeat stingers -- short non-looping songs.

Victory: surf IV-V-I fanfare in A with a chromatic triangle walkup.
Defeat: E-minor chromatic descent with a semitone slide-down "wilt".
"""

from sequencer import Channel, Song
from songs.instruments import BASS, LEAD25, LEAD50, SOFT125

VICTORY = Song(
    name="victory",
    tempo=152,
    loop=False,
    channels={
        "pulse1": Channel(LEAD50),
        "pulse2": Channel(SOFT125),
        "tri": Channel(BASS),
        "noise": Channel(),
    },
    sections={
        "all": {
            "pulse1": (
                "A4:2 E5:2 C#5:1 A4:1 E5:2 A5:2 C#6:6{vib} | "
                "D6:2 C#6:2 B5:2 C#6:10{vib}"
            ),
            "pulse2": (
                "E4:2 C#5:2 A4:1 E4:1 C#5:2 E5:2 A5:6 | "
                "F#5:2 A5:2 G#5:2 A5:10"
            ),
            "tri": (
                "A2:1 A2:1 B2:1 C#3:1 D3:1 D#3:1 E3:2 E2:2 A2:2 E2:2 A1:2 | "
                "A2:2 E2:2 A2:2 E2:2 A2:8"
            ),
            "noise": "K.S.K.S.KKSSK... | K...S...K.S.K...",
        },
    },
    arrangement=["all"],
)

DEFEAT = Song(
    name="defeat",
    tempo=126,
    loop=False,
    channels={
        "pulse1": Channel(LEAD25),
        "pulse2": Channel(SOFT125, echo_of="pulse1", echo_16ths=3, echo_vol=-7),
        "tri": Channel(BASS),
        "noise": Channel(),
    },
    sections={
        "all": {
            "pulse1": (
                "B4:3 A4:1 G4:3 F#4:1 E4:4 D#4:2 E4:2 | "
                "F4:2 E4:2 D#4:2 D4:2 C4:2 B3:6{slide=A#3}"
            ),
            "tri": (
                "E2:2 Eb2:2 D2:2 Db2:2 C2:2 B1:2 Bb1:2 A1:2 | "
                "E2:4 B1:4 E1:8"
            ),
            "noise": "T............... | T.......T.......",
        },
    },
    arrangement=["all"],
)
