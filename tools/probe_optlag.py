#!/usr/bin/env python3
"""Where the Options lag is: the form fill, or the display task's first layout of the screen.

Measured on the glass: the first open takes 2-4 seconds and later ones are much quicker. That
rules out press dispatch and the form fill, because both cost the same every time, and points
at work the display task does once per screen -- laying out a screen it has built but never
shown.

This times the two halves separately, on the instrument's own clock, with the frame loop
parked so the display task is not also painting a trace:

    opt_fill()                   six setvalue round trips plus options_preview()
    changescreen(optscr)         the first show, and the layout with it
    changescreen(sg_scr)         back
    then both again              the second show, for the difference

If the first changescreen dominates and the second is cheap, the fix is to show the screen
once during start() so the layout is paid at launch. If opt_fill dominates, the six setvalue
calls are the target. If neither is slow with frames parked, the cost is contention with the
trace painting and the fix is to pre-warm anyway.

NOTE THE CONFOUND: a socket session suppresses display event dispatch, so this cannot measure
press-to-screen latency -- only the work after the press. That is deliberate; the press half
was already ruled out by the first-open-only behaviour.

EVERY STATEMENT IS ONE LINE and under 1000 bytes.

    python3 -u -I tools/probe_optlag.py
"""
import os
import sys
import time

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
from dmmrun import DMM                                                   # noqa: E402


def ask(d, cmd, tag, tries=16, timeout=120):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1.3)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def park(d, on):
    st = ("do if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame "
          "fftsa.frame = function() end end end") if on else \
         ("do if fftsa.saved_frame ~= nil then fftsa.frame = fftsa.saved_frame "
          "fftsa.saved_frame = nil end end")
    probe = ("print('K|' .. tostring(fftsa.saved_frame ~= nil))" if on
             else "print('K|' .. tostring(fftsa.saved_frame == nil))")
    for _ in range(30):
        d.drain()
        d.send(st)
        time.sleep(0.5)
        r = d.q(probe, timeout=25)
        if r is not None and str(r).startswith('K|true'):
            return True
        time.sleep(1.2)
    raise SystemExit('park(%s) failed' % on)


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def main():
    d = DMM(recover=False, timeout=200)
    try:
        d.drain()
        park(d, True)
        print('park  : parked')
        print('state : %s' % ask(d, one("do print('S|opt=' .. tostring(fftsa.optscr)",
                                        ".. ' main=' .. tostring(fftsa.sg_scr)",
                                        ".. ' n=' .. tostring(fftsa.n)) end"), 'S|')[2:])

        # Three rounds. The first is the one the operator feels; the rest are the baseline.
        print()
        print('%-7s %-12s %-14s %-12s' % ('round', 'opt_fill', 'show options', 'show main'))
        for k in range(3):
            r = ask(d, one("do local c = os.clock",
                           "local a = c()",
                           "fftsa.opt_fill(fftsa.flo, fftsa.fhi, fftsa.range, fftsa.win_i,",
                           "fftsa.kbeta_i, fftsa.n)",
                           "local b = c()",
                           "display.changescreen(fftsa.optscr)",
                           "local e = c()",
                           "display.changescreen(fftsa.sg_scr)",
                           "local f = c()",
                           "print(string.format('T|%.1f|%.1f|%.1f',",
                           "(b - a) * 1000, (e - b) * 1000, (f - e) * 1000)) end"),
                    'T|', timeout=200)
            fill, show, back = r[2:].split('|')
            print('%-7d %-12s %-14s %-12s' % (k + 1, fill + ' ms', show + ' ms', back + ' ms'))
        print()
        print('If round 1 "show options" dwarfs rounds 2 and 3, the layout is the cost and')
        print('showing the screen once in start() moves it to launch. If opt_fill is the big')
        print('one, the six setvalue round trips are the target instead.')
    finally:
        park(d, False)
        print('unpark: running')
        d.close()


if __name__ == '__main__':
    main()
