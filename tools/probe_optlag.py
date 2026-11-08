#!/usr/bin/env python3
"""Where the Options first-press lag is: the form fill, or the display task's first layout.

Measured on the glass across several builds: the first open takes seconds and later ones are
much quicker. That rules out press dispatch AND the form fill, because both cost the same
every time, and points at work the display task does once per screen -- laying out a screen it
has built but never shown.

8.51 fixed two of the three causes. `options()` now switches screen BEFORE filling the form,
so the six setvalue calls land on an idle display task instead of queueing behind a trace
paint, and `options_preview` takes the values it needs rather than reading them back. The
first press is still slow, and this times the two halves separately to say why.

    python3 -u -I tools/probe_optlag.py

NO PARKING, AND NONE IS ATTEMPTED. A socket session suppresses display event dispatch, so the
app's frame timer stops the moment this connects and the spectrum screen stays on the glass.
Parking the frame loop over the socket was tried four times and cannot win: the frame loop
holds the interpreter, so the very statement that would stop it is refused.

THE PRECONDITION IS CHECKED, NOT ASSUMED. Only the first open is slow, so this measures
nothing on an app whose Options screen has already been shown. `fftsa.opt_opens` counts them
and has to read 0 or nil. If it does not, End App and launch again.

NOTE THE CONFOUND: with a socket open, press-to-screen latency cannot be measured at all --
only the work after the press. That is deliberate; the press half was already ruled out by the
first-open-only behaviour.
"""
import os
import sys
import time

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
from dmmrun import DMM                                                   # noqa: E402

ROUNDS = 3


def ask(d, cmd, tag, tries=16, timeout=200):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1.3)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def require_cold(d):
    """The app live, on the spectrum screen, with Options never shown this launch."""
    for _ in range(20):
        r = d.q(one("do local f = fftsa",
                    "print('A|' .. tostring(f ~= nil and f.optscr ~= nil)",
                    ".. '|' .. tostring(f ~= nil and (f.opt_opens or 0))",
                    ".. '|' .. tostring(f ~= nil and f.n)) end"), timeout=30)
        if r is not None and str(r).startswith('A|'):
            parts = str(r)[2:].split('|')
            if parts[0] != 'true':
                raise SystemExit('no Options screen: is the app running?')
            if parts[1] not in ('0', 'nil'):
                raise SystemExit('Options has been opened %s times this launch, so the cold '
                                 'measurement is gone. End App, launch again, and do not '
                                 'press the cog.' % parts[1])
            return parts[2]
        time.sleep(1.5)
    raise SystemExit('the app is not answering')


def main():
    d = DMM(recover=False, timeout=200)
    try:
        d.drain()
        n = require_cold(d)
        print('state : cold, Options never shown, %s samples' % n)
        print('        frames are already stopped -- a socket session kills event dispatch')

        # The sequence the app actually runs, in the order it runs it: switch, yield, fill.
        # Measuring the fill alone would miss the layout, which is the whole hypothesis.
        print()
        print('%-7s %-14s %-12s %-14s %s'
              % ('round', 'show options', 'yield', 'opt_fill', 'show main'))
        rows = []
        for k in range(ROUNDS):
            r = ask(d, one("do local c = os.clock",
                           "local a = c() display.changescreen(fftsa.optscr)",
                           "local b = c() delay(fftsa.sg_yield)",
                           "local e = c()",
                           "fftsa.opt_fill(fftsa.flo, fftsa.fhi, fftsa.range, fftsa.win_i,",
                           "fftsa.kbeta_i, fftsa.n)",
                           "local f = c() display.changescreen(fftsa.sg_scr)",
                           "local g = c()",
                           "print(string.format('T|%.1f|%.1f|%.1f|%.1f',",
                           "(b-a)*1000, (e-b)*1000, (f-e)*1000, (g-f)*1000)) end"),
                    'T|', timeout=200)
            show, yld, fill, back = (float(x) for x in r[2:].split('|'))
            rows.append((show, yld, fill, back))
            print('%-7d %-14s %-12s %-14s %s'
                  % (k + 1, '%.1f ms' % show, '%.1f ms' % yld,
                     '%.1f ms' % fill, '%.1f ms' % back))

        print()
        cold, warm = rows[0], rows[-1]
        names = ('show options', 'the yield', 'opt_fill', 'show main')
        worst, widx = 0.0, None
        for i in range(4):
            dlt = cold[i] - warm[i]
            if dlt > worst:
                worst, widx = dlt, i
        print('first round costs %.1f ms more than the last, and %.1f ms of that is %s'
              % (sum(cold) - sum(warm), worst, names[widx] if widx is not None else 'nothing'))
        print()
        if widx == 0 and worst > 100:
            print('THE LAYOUT IS THE COST. Showing the Options screen once during start(),')
            print('before the spectrum screen goes up, moves it to launch where the loading')
            print('screen is already on the glass. Expect a flash of the form at launch.')
        elif widx == 2 and worst > 100:
            print('THE FILL IS THE COST, which contradicts the first-open-only behaviour --')
            print('six setvalue calls cost the same every time. Check whether the trace was')
            print('still painting through round 1.')
        elif sum(cold) - sum(warm) < 100:
            print('No cold penalty here at all, which means the lag is NOT after the press.')
            print('With a socket open the press half cannot be measured, so the remaining')
            print('candidate is dispatch of the press itself -- and that needs the panel, not')
            print('this probe: time the operator pressing the cog with nothing connected.')
        else:
            print('No single half dominates. The numbers above are the measurement; do not')
            print('pick a fix from a split verdict.')
    finally:
        # Back to the spectrum screen whatever happened, so the app is where the operator
        # left it rather than sitting on a form.
        d.q('do display.changescreen(fftsa.sg_scr) end', timeout=30)
        d.close()


if __name__ == '__main__':
    main()
