"""Level 03 "Ice Paradise" -- brighter, colder. A major with lydian
shimmer (D# rubs), 132 BPM, 40 bars (~73 s). High 12.5%-duty broken-chord
16th arps, sparse bell lead with slow vibrato, light bass an octave up,
delicate closed hats.
"""

from sequencer import Channel, Song
from songs.instruments import ARP125, BASS, BELL50

_AR1 = "A4 C#5 E5 G#5 A5 G#5 E5 C#5 A4 C#5 E5 G#5 A5 G#5 E5 C#5"      # Amaj7
_AR2 = "G#4 B4 E5 G#5 B5 G#5 E5 B4 G#4 B4 E5 G#5 B5 G#5 E5 B4"        # E/G#
_AR3 = "F#4 A4 C#5 E5 F#5 E5 C#5 A4 F#4 A4 C#5 E5 F#5 E5 C#5 A4"      # F#m7
_AR4 = "D4 F#4 A4 C#5 D5 C#5 A4 F#4 D4 F#4 A4 C#5 D5 C#5 A4 F#4"      # Dmaj7
_AR4L = "D4 F#4 A4 D#5 E5 D#5 A4 F#4 D4 F#4 A4 D#5 E5 D#5 A4 F#4"     # lydian rub
_BR1 = "B4 D5 F#5 A5 B5 A5 F#5 D5 B4 D5 F#5 A5 B5 A5 F#5 D5"          # Bm7
_BR2 = "E4 G#4 B4 D5 E5 D5 B4 G#4 E4 G#4 B4 D5 E5 D5 B4 G#4"          # E9

_LB1 = "A2:2 r:2 E3:2 r:2 A3:2 r:2 E3:2 r:2"
_LB2 = "G#2:2 r:2 E3:2 r:2 B3:2 r:2 E3:2 r:2"
_LB3 = "F#2:2 r:2 C#3:2 r:2 F#3:2 r:2 C#3:2 r:2"
_LB4 = "D3:2 r:2 A2:2 r:2 D3:2 r:2 A3:2 r:2"
_LBB1 = "B2:2 r:2 F#3:2 r:2 B3:2 r:2 F#3:2 r:2"
_LBB2 = "E3:2 r:2 B2:2 r:2 E3:2 r:2 G#3:2 r:2"

_H1 = "h.h.h.h.h.h.h.h."
_H2 = "K.h.h.h.h.h.h.h."
_H3 = "h.h.h.h.S.h.h.h."

_ARPS_A = f"{_AR1} | {_AR2} | {_AR3} | {_AR4} | {_AR1} | {_AR2} | {_AR3} | {_AR4L}"
_BASS_A = f"{_LB1} | {_LB2} | {_LB3} | {_LB4} | {_LB1} | {_LB2} | {_LB3} | {_LB4}"
_HATS_8 = f"{_H2} | {_H1} | {_H3} | {_H1} | {_H2} | {_H1} | {_H3} | {_H1}"

SONG = Song(
    name="level03",
    tempo=132,
    channels={
        "pulse1": Channel(ARP125),
        "pulse2": Channel(BELL50),  # explicit sparse bell, no echo
        "tri": Channel(BASS),
        "noise": Channel(),
    },
    sections={
        "intro": {
            "pulse1": f"{_AR1} | {_AR2} | {_AR3} | {_AR4}",
            "noise": f"{_H1} | {_H1} | {_H1} | {_H1}",
        },
        "A": {
            "pulse1": _ARPS_A,
            "pulse2": (
                "E5:12 r:4 | r:8 C#5:4 B4:4 | A4:12 r:4 | r:16 | "
                "E5:12 r:4 | r:8 F#5:4 G#5:4 | A5:12 r:4 | r:16"
            ),
            "tri": _BASS_A,
            "noise": _HATS_8,
        },
        "B": {
            "pulse1": f"{_BR1} | {_BR2} | {_AR4} | {_AR2} | {_BR1} | {_BR2} | {_AR4L} | {_AR2}",
            "pulse2": (
                "F#5:12 r:4 | G#5:8 A5:8 | D5:12 r:4 | E5:16 | "
                "F#5:12 r:4 | G#5:8 A5:8 | D#5:12 r:4 | E5:16"
            ),
            "tri": f"{_LBB1} | {_LBB2} | {_LB4} | {_LB2} | {_LBB1} | {_LBB2} | {_LB4} | {_LB2}",
            "noise": _HATS_8,
        },
        "turn": {
            "pulse2": "A5:12 r:4 | G#5:8 E5:8 | F#5:12 r:4 | B4:16",
            "tri": f"{_LB1} | {_LB2} | {_LB3} | {_LB4}",
        },
    },
    arrangement=["intro", "A", "A", "B", "A", "turn"],
)
