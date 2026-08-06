"""Shared instrument palette for all songs."""

from nes_synth import Env, Instrument

# Main melodic voice: bright 50% pulse, pluck attack into a twangy sustain.
LEAD50 = Instrument(0.5, Env([15, 13, 12, 11, 10, 9, 9, 8, 8, 8, 7, 7, 7, 7,
                              6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 4]))
# Same envelope, hollower 25% duty.
LEAD25 = Instrument(0.25, Env([15, 13, 12, 11, 10, 9, 9, 8, 8, 8, 7, 7, 7, 7,
                               6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 4]))
# Short stab for funk comping.
STAB125 = Instrument(0.125, Env([13, 11, 9, 7, 5, 4, 3, 2, 1, 0]))
# Steady 16th-note arpeggio voice (Ice Paradise).
ARP125 = Instrument(0.125, Env([10, 8, 7, 6, 5, 5, 4, 4]))
# Bell-ish sparse lead with slow built-in vibrato.
BELL50 = Instrument(0.5, Env([12, 10, 9, 8, 7, 7, 6, 6, 5, 5, 5, 4, 4, 4, 4, 3]),
                    vibrato=(10, 4.5, 0.10))
# Quiet 12.5% voice for explicit harmony/echo lines.
SOFT125 = Instrument(0.125, Env([10, 9, 8, 7, 7, 6, 6, 5, 5, 5, 4, 4, 4, 3, 3, 3]))
# Triangle bass (duty/env ignored by the triangle renderer).
BASS = Instrument()
