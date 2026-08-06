"""Song registry. Each module exposes a SONG (jingles exposes two)."""

from songs.jingles import DEFEAT, VICTORY
from songs.level01 import SONG as _level01
from songs.level02 import SONG as _level02
from songs.level03 import SONG as _level03
from songs.menu import SONG as _menu

SONGS = {
    s.name: s
    for s in (_menu, _level01, _level02, _level03, VICTORY, DEFEAT)
}
