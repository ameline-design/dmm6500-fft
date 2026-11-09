#!/usr/bin/env python3
"""Arm the app's pixel fill, watch it engage, and measure what it bought.

The pixel path ships switched off: it writes 40 KB into an address it derived at runtime, so
it is turned on deliberately. This turns it on in a live app, follows the state machine
through seek, map and on, and reports the frame cost either side with a grab of each.

Nothing here does the work. Every byte of it is fftsa.nl.px_* on the instrument, which is
what has to be right -- the probe only reads state, flips one flag, and photographs the glass.

    python3 -u -I tools/probe_pixapp.py
    python3 -u -I tools/probe_pixapp.py --off          # back to appends, and prove it
    python3 -u -I tools/probe_pixapp.py --budget 524288
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SIB = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import dmmrun  # noqa: E402


def opt(flag, default, cast=int):
    if flag in sys.argv:
        return cast(sys.argv[sys.argv.index(flag) + 1])
    return default


OFF = '--off' in sys.argv
DRIVE = '--drive' in sys.argv
# --live lets go of the socket between polls, for an app launched OVER the socket: its
# frame timer never fires while a control session is open. An app launched from the KEY
# keeps its timer, so the default path -- poll while frames run -- is the one to use there.
LIVE = '--live' in sys.argv
POLL = opt('--poll', 8, float)
BUDGET = opt('--budget', 0)
WAIT = opt('--wait', 180, float)
SETTLE = opt('--settle', 12, float)
MAXFRAMES = opt('--frames', 400)
TIMED = opt('--timed', 15)


def ask(d, cmd, tag, timeout=600):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    d.drain()
    d.send(cmd)
    t_end = time.time() + timeout
    last, resends = None, 0
    while time.time() < t_end:
        t_read = time.time()
        r = d.line(min(20.0, t_end - time.time()))
        if r is None:
            if time.time() - t_read < 0.05:
                time.sleep(0.25)
            continue
        last = str(r)
        if last.startswith(tag):
            return last
        if 'another interface' in last:
            resends += 1
            if resends > 400:
                break
            d.drain()
            d.send(cmd)
    raise SystemExit('DESYNC(%s) last=%r after %d refusals' % (tag, last, resends))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def shot(d, path):
    rc = subprocess.call([sys.executable, '-I',
                          os.path.join(SIB, 'tools', 'screenshot.py'), path])
    print('grab    : %s%s' % (path, '' if rc == 0 else '  (FAILED rc=%d)' % rc))
    return rc == 0


def require_app(d):
    for _ in range(30):
        r = d.q(one("print('A|' .. tostring(fftsa ~= nil and fftsa.nl ~= nil",
                    "and type(fftsa.nl.px_try) == 'function')",
                    ".. '|' .. tostring(fftsa ~= nil and fftsa.VERSION)",
                    ".. '|' .. tostring(fftsa ~= nil and fftsa.halted))"), timeout=30)
        if r is not None and str(r).startswith('A|true'):
            f = str(r).split('|')
            if f[3] == 'true':
                raise SystemExit('the app is HALTED; relaunch before measuring anything')
            return f[2]
        if r is not None and str(r).startswith('A|false'):
            raise SystemExit('this build has no fftsa.nl.px_try')
        time.sleep(1.0)
    raise SystemExit('the app is not answering')


def state(d):
    return ask(d, "print('PX|' .. tostring(fftsa.nl.px_str()))", 'PX|', timeout=120)[3:]


def phases(d):
    return ask(d, "print('PH|' .. tostring(fftsa.phases()))", 'PH|', timeout=120)[3:]


def rate(d, seconds):
    """Frames a second, counted by the one thing only the frame body moves.

    sg_stamp climbs by the points a pass reserves, and a pass reserves the same number every
    frame in either path -- so the DIVISOR differs between them and the raw figure cannot be
    compared. What is compared is fftsa.frame_work, which is the frame's own measurement, and
    this is the independent check that frames are running at all.
    """
    a = int(ask(d, "print('SP|' .. tostring(fftsa.sg_stamp or -1))", 'SP|', timeout=60)[3:])
    t0 = time.time()
    ask(d, "do delay(%.2f) print('DL|1') end" % seconds, 'DL|1', timeout=120)
    b = int(ask(d, "print('SP|' .. tostring(fftsa.sg_stamp or -1))", 'SP|', timeout=60)[3:])
    return (b - a) / max(0.001, time.time() - t0)


# ONE FRAME PER STATEMENT, on the instrument's own clock.
#
# The frame timer is a display event, and a control socket kills display event dispatch -- so
# while this probe is connected the timer never fires and nothing advances on its own. Driving
# the frame body by hand runs exactly the code the timer would, which is what is under test;
# what it does not reproduce is the timer's period, so the figure below is the frame's cost and
# not the frame rate.
#
# One frame per statement, never a loop over frames: a loop inside one statement cannot be
# interrupted from the panel, and an open-loop batch from a frame callback is its own hazard.
FRAME = ("do local t0 = os.clock() fftsa.frame() local t1 = os.clock() "
         "print('FR|' .. string.format('%.2f', (t1 - t0) * 1000)) end")


def drive(d):
    return float(ask(d, FRAME, 'FR|', timeout=300)[3:])


def median(v):
    s = sorted(v)
    return s[len(s) // 2]


def driven(d):
    """Arm, drive frames until the path engages, and time both sides of the switch."""
    if BUDGET:
        ask(d, "do fftsa.nl.PX_BUDGET = %d print('BG|' .. tostring(fftsa.nl.PX_BUDGET)) end"
            % BUDGET, 'BG|', timeout=120)
        print('budget  : %d bytes a frame' % BUDGET)

    ask(d, one("do fftsa.sg_pix = false",
               "if fftsa.nl.px_restart ~= nil then fftsa.nl.px_restart('probe baseline') end",
               "print('OF|' .. tostring(fftsa.sg_pix)) end"), 'OF|', timeout=120)
    base = [drive(d) for _ in range(TIMED)]
    print('appends : %.1f ms a frame, median of %d  (%s)'
          % (median(base), len(base), ' '.join('%.0f' % v for v in base)))
    shot(d, '/tmp/pix_before.png')

    ask(d, "do fftsa.sg_pix = true print('ON|' .. tostring(fftsa.sg_pix)) end",
        'ON|', timeout=120)
    print('armed   : fftsa.sg_pix = true')

    seek, last, engaged = [], None, False
    for k in range(MAXFRAMES):
        seek.append(drive(d))
        s = state(d)
        if s != last:
            print('  frame %3d  %s' % (k + 1, s))
            last = s
        if s.startswith('px=on'):
            engaged = True
            break
        if s.startswith('px=off'):
            break
    if seek:
        print('seeking : %.1f ms a frame while it searched, over %d frames'
              % (median(seek), len(seek)))
    if not engaged:
        print('result  : did not engage in %d frames. Still drawing by appending.' % len(seek))
        shot(d, '/tmp/pix_failed.png')
        return 1

    pix = [drive(d) for _ in range(TIMED)]
    print('pixels  : %.1f ms a frame, median of %d  (%s)'
          % (median(pix), len(pix), ' '.join('%.0f' % v for v in pix)))
    print('state   : %s' % state(d))
    print('phases  : %s' % phases(d))
    shot(d, '/tmp/pix_after.png')
    b, p = median(base), median(pix)
    print()
    print('result  : %.1f ms -> %.1f ms a frame, %.1f ms saved (%.0f%%)'
          % (b, p, b - p, 100.0 * (b - p) / max(0.001, b)))
    print('Compare /tmp/pix_before.png with /tmp/pix_after.png. The trace has to be the SAME')
    print('spectrum, not merely a trace: a wrong slot map draws the right points at the wrong')
    print('frequencies and still looks like a spectrum.')
    return 0


# THE SOCKET HAS TO BE LET GO OF, and that is not a convenience.
#
# A control socket kills display event dispatch, so while this probe is connected the frame
# timer never fires -- AND THE DISPLAY TASK NEVER DRAINS. An append posts a message the task
# picks up only when it runs, so with the socket held the records the search is looking for are
# never written: measured on 2026-11-09, 99 MB swept over 400 hand-driven frames with nothing
# found, and a full-ladder find from the same state ran past ten minutes. The appends were
# real, the buffer read back correctly, and the ring was empty of them.
#
# So the only honest test is the shipped one: arm it, close the socket, and let the instrument
# run on its own timer. The glass is still readable over HTTP, which needs no control socket,
# and the state is read by reconnecting for a second at a time -- each reconnection stops
# frames while it lasts, which costs progress but not correctness.
def live(d):
    if BUDGET:
        ask(d, "do fftsa.nl.PX_BUDGET = %d print('BG|' .. tostring(fftsa.nl.PX_BUDGET)) end"
            % BUDGET, 'BG|', timeout=120)
        print('budget  : %d bytes a frame' % BUDGET)
    print('before  : %s' % phases(d))
    shot(d, '/tmp/pix_before.png')
    ask(d, one("do fftsa.sg_pix = true",
               "if fftsa.nl.px_restart ~= nil then fftsa.nl.px_restart('probe armed') end",
               "print('ON|' .. tostring(fftsa.sg_pix)) end"), 'ON|', timeout=120)
    print('armed   : fftsa.sg_pix = true, letting go of the socket so frames can run')

    t0, last, engaged, prev = time.time(), None, False, None
    while time.time() - t0 < WAIT:
        d.close()
        time.sleep(POLL)
        d._open()
        st = int(ask(d, "print('SP|' .. tostring(fftsa.sg_stamp or -1))", 'SP|',
                     timeout=60)[3:])
        s = state(d)
        moved = '' if prev is None else '  (+%d stamps)' % (st - prev)
        prev = st
        if s != last:
            print('  %6.1fs  %s%s' % (time.time() - t0, s, moved))
            last = s
        if s.startswith('px=on'):
            engaged = True
            break
        if s.startswith('px=off'):
            break
    if not engaged:
        print('state   : %s' % state(d))
        print('result  : did not engage in %gs. Still drawing by appending.'
              % (time.time() - t0))
        shot(d, '/tmp/pix_failed.png')
        return 1

    # Let it run on its own for a while before asking what a frame costs, because the frames
    # right after the switch still carry the search in their average.
    d.close()
    time.sleep(SETTLE)
    d._open()
    print()
    print('state   : %s' % state(d))
    print('after   : %s' % phases(d))
    shot(d, '/tmp/pix_after.png')
    print()
    print('Compare /tmp/pix_before.png with /tmp/pix_after.png. The trace has to be the SAME')
    print('spectrum, not merely a trace: a wrong slot map draws the right points at the wrong')
    print('frequencies and still looks like a spectrum.')
    return 0


def main():
    d = dmmrun.DMM(timeout=180, recover=False)
    ver = require_app(d)
    print('app     : v%s' % ver)
    if DRIVE:
        return driven(d)
    if LIVE:
        return live(d)

    if OFF:
        ask(d, one("do fftsa.sg_pix = false",
                   "if fftsa.nl.px_off ~= nil then fftsa.nl.px_off('switched off by probe') end",
                   "print('OF|' .. tostring(fftsa.sg_pix)) end"), 'OF|', timeout=120)
        time.sleep(SETTLE)
        print('state   : %s' % state(d))
        print('phases  : %s' % phases(d))
        shot(d, '/tmp/pix_off.png')
        return 0

    if BUDGET:
        ask(d, "do fftsa.nl.PX_BUDGET = %d print('BG|' .. tostring(fftsa.nl.PX_BUDGET)) end"
            % BUDGET, 'BG|', timeout=120)
        print('budget  : %d bytes a frame' % BUDGET)

    print('before  : %s' % phases(d))
    shot(d, '/tmp/pix_before.png')

    ask(d, "do fftsa.sg_pix = true print('ON|' .. tostring(fftsa.sg_pix)) end",
        'ON|', timeout=120)
    print('armed   : fftsa.sg_pix = true, watching the state machine')

    t0 = time.time()
    last, engaged = None, False
    while time.time() - t0 < WAIT:
        s = state(d)
        if s != last:
            print('  %6.1fs  %s' % (time.time() - t0, s))
            last = s
        if s.startswith('px=on'):
            engaged = True
            break
        if s.startswith('px=off'):
            print('  the path switched itself off; nothing further to measure')
            break
        time.sleep(1.5)

    if not engaged:
        print('state   : %s' % state(d))
        print('result  : did not engage within %gs. The app is still drawing by appending.'
              % WAIT)
        shot(d, '/tmp/pix_failed.png')
        return 1

    # Settle, because the frame timer re-arms itself off measured work and the first frames
    # after a switch still carry the search's cost in their average.
    time.sleep(SETTLE)
    print()
    print('state   : %s' % state(d))
    print('after   : %s' % phases(d))
    print('rate    : %.2f sg_stamp/s (frames are running)' % rate(d, 4.0))
    shot(d, '/tmp/pix_after.png')
    print()
    print('Compare /tmp/pix_before.png with /tmp/pix_after.png. The trace has to be the SAME')
    print('spectrum, not merely a trace: a wrong slot map draws the right points at the wrong')
    print('frequencies and still looks like a spectrum.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
