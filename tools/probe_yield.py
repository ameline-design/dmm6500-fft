#!/usr/bin/env python3
"""Measure what fftsa.sg_yield costs the frame rate, on the running app.

sg_yield is the in-frame delay that lets the display task paint after both the trace and
the marker buffers are complete. It is 10 ms, which is a sixth of the non-acquisition
budget at the short counts, and those sit just above a tick boundary -- so a few
milliseconds either way may be a whole tick of displayed rate.

A live knob, so this needs no reinstall and no Apply. It is also the constant that stops a
torn trace being painted, so the point of measuring rather than just lowering it is to see
whether the rate even moves before trading that away.

The app must already be running and on its main screen. Nothing here writes a setting that
survives: --restore puts the shipped value back, and the script restores on its own way out
unless --keep is given.

    python3 -I tools/probe_yield.py                 # baseline, then 5 ms, then restore
    python3 -I tools/probe_yield.py --yield-ms 2
    python3 -I tools/probe_yield.py --restore       # put 10 ms back and stop
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..',
                                'dmm6500-serial-decode', 'tools'))
from dmmrun import DMM          # noqa: E402

SHIPPED_MS = 10.0
# Two fps windows plus a peak window of eight frames at the slowest count this is worth
# running at, so the figure read back is the one the new yield produced and not a blend.
SETTLE_S = 5.0


def live_fps(d, tag, timeout=30):
    """One tagged line: the count, the fps, the yield, and the in-window frame count.

    A sequence of separate queries would let the app move between them; and a probe that
    does not prove the app is live reports a stale fps as a result. fps_n is the counter
    that proves it -- it is the frames the open window has seen, so it moves between two
    reads of a running app and does not move for a stopped one. sg_nwrote is the point
    count and is constant whether the app runs or not, which is no proof at all.
    """
    r = d.q('print(string.format("%s|%%s|%%s|%%s|%%s|%%s", tostring(fftsa.n), '
            'tostring(fftsa.fps), tostring(fftsa.sg_yield), '
            'tostring(fftsa.fps_n), tostring(fftsa.errrun)))' % tag, timeout=timeout)
    return r


def ask(d, tag, timeout=30):
    """A tagged read, checked against its own tag.

    The instrument volunteers event lines, and one arriving between a statement and its
    reply shifts every response after it by one -- which reads as a plausible figure
    belonging to the wrong question. The tag is in the reply, so a shift is visible rather
    than silent; one re-read resynchronises, and a second mismatch is reported as itself.
    """
    want = tag + '|'
    i = 0
    while i < 3:
        r = live_fps(d, tag, timeout)
        if r is not None and r[:len(want)] == want:
            return r
        i = i + 1
    return 'DESYNC(%s) last=%r' % (tag, r)


def set_count(d, n):
    """The form run_app.py uses: the count, then the app's own Apply.

    exec and not a printing query, so Apply's own output cannot be mistaken for a reply.
    The interpreter is single-threaded, so this runs between frames and not inside one.
    """
    d.exec('fftsa.n = %d fftsa.apply()' % n, timeout=300)


def read_settled(d, tag):
    a = ask(d, tag)
    time.sleep(SETTLE_S)
    b = ask(d, tag)
    return a, b


def show(label, a, b):
    print('  %-10s %s' % (label, a))
    print('  %-10s %s' % ('', b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--yield-ms', type=float, default=5.0,
                    help='the value to try, in milliseconds')
    ap.add_argument('--restore', action='store_true',
                    help='write the shipped value back and stop')
    ap.add_argument('--keep', action='store_true',
                    help='leave the trial value in place')
    ap.add_argument('--count', type=int, default=None,
                    help='sample count to measure at; left alone if omitted')
    a = ap.parse_args()

    d = DMM(timeout=60)
    try:
        alive = d.q('print(tostring(fftsa ~= nil and fftsa.timer ~= nil))', timeout=30)
        if alive != 'true':
            raise SystemExit('the app is not running (fftsa.timer is %r)' % alive)

        if a.restore:
            d.exec('fftsa.sg_yield = %g' % (SHIPPED_MS / 1000.0), timeout=30)
            print(ask(d, 'restored'))
            return

        if a.count is not None:
            set_count(d, a.count)
            time.sleep(SETTLE_S)
        print('n|fps|sg_yield|fps_n|errrun')
        before = read_settled(d, 'before')
        show('before', *before)

        d.exec('fftsa.sg_yield = %g' % (a.yield_ms / 1000.0), timeout=30)
        after = read_settled(d, 'after')
        show('after', *after)

        if not a.keep:
            d.exec('fftsa.sg_yield = %g' % (SHIPPED_MS / 1000.0), timeout=30)
            print('  restored  sg_yield = %g s' % (SHIPPED_MS / 1000.0))
        else:
            print('  kept      sg_yield = %g s' % (a.yield_ms / 1000.0))
    finally:
        d.close()


if __name__ == '__main__':
    main()
