#!/usr/bin/env python3
"""Does the display task fall behind now that nothing in the frame waits for it?

The HELP-key poll blocked on ki.display.getchecksum, which returns glass-derived data, so
every frame waited for the display task to answer. Measured at 16,384 samples it waited
46.1 ms -- and that was AFTER the frame's own 10 ms yield, so the task was 46 ms in arrears
with 76 ms of post-frame idle still to come. The poll now runs once a second and the
recogniser ships off, and fftsa.tick_idle reserves a flat 20 ms whatever the count.

So the task has about 30 ms of Lua-blocked time a frame against 46 ms of measured
outstanding work. If that deficit is real it accumulates, and the symptom is not a slow app:
it is event 1706, dropped display messages, and a trace that updates at a fraction of the
rate the settings line reports. docs/PERFORMANCE.md records exactly that at a 5 ms yield --
35.6 Hz in Lua, 194 instances of 1706, and a trace moving about three times a second.

NOTHING IN THE APP CAN SEE THIS. There is no eventlog reader in tsp/, getchecksum is behind
a false help_ok, and fftsa.fps counts completed Lua frames against the wall clock, so it
reports the rate Lua achieved while the glass falls behind. The event log is the only
witness, which is why this probe exists.

Frames are driven by hand at the cadence the timer would use -- one frame, then a delay of
the period's idle -- because the timer does not fire reliably under the socket harness. The
duty cycle is what matters to the question and it is reproduced exactly: delay() blocks Lua,
which is the only time the display task runs, so this gives the task the same budget the
armed timer would.

Sliced into batches rather than one long statement: a single call running for a minute could
not be interrupted, and the reply would land while the next query was waiting.

    python3 -I tools/probe_drain.py --count 16384 --seconds 60
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..',
                                'dmm6500-serial-decode', 'tools'))
from dmmrun import DMM          # noqa: E402

BATCH = 8          # frames a statement; at 16,384 that is about two seconds


def ask(d, cmd, tag, tries=5, timeout=120):
    """A tagged read, checked. The instrument volunteers event lines, and one arriving
    mid-exchange shifts every reply after it."""
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return r
    return 'DESYNC(%s) last=%r' % (tag, r)


def events(d):
    """Every event in the log, drained. getevent does not exist on this firmware; next does."""
    out = []
    n = ask(d, 'print("n|" .. tostring(eventlog.getcount()))', 'n|')
    try:
        count = int(str(n).split('|')[1])
    except (IndexError, ValueError):
        return out, n
    for _ in range(min(count, 60)):
        line = d.q('print(eventlog.next())', timeout=60)
        if line is None or line == '':
            break
        out.append(str(line))
    return out, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--count', type=int, default=16384)
    ap.add_argument('--seconds', type=float, default=60.0)
    ap.add_argument('--idle-ms', type=float, default=None,
                    help='Lua-blocked time between frames; default is the armed period '
                         'less the measured frame, which is what the timer would leave')
    a = ap.parse_args()

    d = DMM(timeout=300)
    try:
        if ask(d, 'print("live|" .. tostring(fftsa ~= nil))', 'live|') != 'live|true':
            raise SystemExit('the app is not loaded')

        # Frames by hand from here. Parked the way run_app.py parks them, so the armed timer
        # cannot also fire one and double the rate.
        d.exec('if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame end '
               'fftsa.frame = function() end', timeout=60)
        d.exec('fftsa.n = %d fftsa.apply()' % a.count, timeout=900)
        d.exec('fftsa.ph_peak = {}', timeout=60)

        # One frame to measure, and to fill ph so the cadence can be derived from it.
        d.exec('fftsa.saved_frame()', timeout=300)
        print(' ', ask(d, 'local p = fftsa.ph '
                          'print(string.format("frame|%.1f|acq %.1f|spec %.1f|show %.1f|yld %.1f|per %s",'
                          ' (fftsa.frame_work or 0)*1000, (p.acq or 0)*1000, (p.spec or 0)*1000,'
                          ' (p.show or 0)*1000, (p.yld or 0)*1000, tostring(fftsa.period)))',
                      'frame|'))

        if a.idle_ms is None:
            r = ask(d, 'print(string.format("idle|%.1f", (fftsa.period - '
                       '(fftsa.frame_work or 0)) * 1000))', 'idle|')
            try:
                a.idle_ms = max(1.0, float(str(r).split('|')[1]))
            except (IndexError, ValueError):
                a.idle_ms = 20.0
        print('  driving frames with %.1f ms of Lua-blocked idle between them'
              % a.idle_ms)

        d.exec('eventlog.clear()', timeout=60)
        t0 = time.time()
        frames = 0
        while time.time() - t0 < a.seconds:
            d.exec('local i for i = 1, %d do fftsa.saved_frame() delay(%g) end'
                   % (BATCH, a.idle_ms / 1000.0), timeout=300)
            frames += BATCH
        wall = time.time() - t0
        print('  %d frames in %.1f s -- %.2f a second of Lua frames'
              % (frames, wall, frames / wall))

        print(' ', ask(d, 'local p, k = fftsa.ph, fftsa.ph_peak '
                          'print(string.format("after|frame %.1f|acq %.1f/%.1f|show %.1f/%.1f|err %s",'
                          ' (fftsa.frame_work or 0)*1000, (p.acq or 0)*1000, (k.acq or 0)*1000,'
                          ' (p.show or 0)*1000, (k.show or 0)*1000, tostring(fftsa.errrun)))',
                      'after|'))

        log, n = events(d)
        print('  event count:', n)
        hits = [l for l in log if '1706' in l]
        for line in log[:12]:
            print('   ', line)
        print('  --> 1706 instances in the drained log: %d' % len(hits))
        if not hits:
            print('      No dropped-message events. The task kept up at this cadence.')
    finally:
        # Frames back under the timer, and the count left where it was found.
        try:
            d.exec('if fftsa.saved_frame ~= nil then fftsa.frame = fftsa.saved_frame '
                   'fftsa.saved_frame = nil end', timeout=60)
        except Exception as e:                      # noqa: BLE001
            print('  restore reported: %r' % (e,))
        d.close()


if __name__ == '__main__':
    main()
