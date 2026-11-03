#!/usr/bin/env python3
"""Where the frame's acquisition time goes, and what a higher sample rate would do to it.

fftsa.ph.acq brackets three statements of fftsa.frame_body: cap.clear(), the capture, and
the over-range read. At 16,384 samples it is two thirds of the frame, and 163.84 ms of it
is the record length itself -- 16384 / 100 kS/s, which is also the reciprocal of the 6.10 Hz
bin width and so not reducible at that resolution. What is left over is what this measures.

Two questions, one setup. No app and no heap code, so this costs no NLBOOT and can run on
any boot:

  * the three statements timed apart, over a grid of sample count against buffer capacity.
    The capture buffer is now allocated once at four times the longest record the app
    offers -- 65,536 elements for every count -- where it used to be four times 2048 at the
    small counts. If clear() or the capture scales with capacity rather than with the
    record, that change moved every count's acquisition and this grid shows it.
  * the same capture at 100 kS/s, 200 kS/s, 500 kS/s and 1 MS/s. Raising the rate at a
    fixed count shortens the record in proportion and widens the bins in proportion, so
    the question is whether the overhead above the record length is fixed per capture or
    paid per reading. Fixed would make a higher rate worth something; per reading would
    not.

The true sample interval comes off the buffer's own relative timestamps, because
digitize.samplerate reads back whatever was asked for rather than what the hardware did.

    python3 -I tools/probe_acq.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..',
                                'dmm6500-serial-decode', 'tools'))
from dmmrun import DMM          # noqa: E402

REPS = 8
# The app's own grid: the count it offers against the capacity it allocates. 8192 is four
# times 2048, which is what the capture buffer used to be floored at.
COUNTS = (2048, 16384)
CAPS = (8192, 65536)
RATES = (100000, 200000, 500000, 1000000)


def ask(d, cmd, tag, tries=5, timeout=300):
    """A tagged read, checked: the instrument volunteers event lines and one arriving
    mid-exchange shifts every reply after it."""
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
    return 'DESYNC(%s) last=%r' % (tag, r)


SETUP = """
if PB ~= nil then pcall(function() PB.clear() buffer.delete(PB) end) end
PB = buffer.make(%(cap)d, buffer.STYLE_STANDARD)
dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE
dmm.digitize.range = 10
dmm.digitize.samplerate = %(rate)d
dmm.digitize.count = %(count)d
PB.clear()
dmm.digitize.read(PB)
print("ready|" .. tostring(PB.n) .. "|" .. tostring(PB.capacity))
"""

# One timing pass. The three statements are timed apart and over the same number of
# repetitions, so a fixed per-call cost shows up in all three alike.
TIME = """
local i
local t0 = os.clock()
for i = 1, %(reps)d do PB.clear() dmm.digitize.read(PB) end
local t1 = os.clock()
for i = 1, %(reps)d do PB.clear() end
local t2 = os.clock()
for i = 1, %(reps)d do local lo, hi = PB.minreading, PB.maxreading end
local t3 = os.clock()
local n = PB.n
local span = (PB.relativetimestamps[n] - PB.relativetimestamps[1]) / (n - 1)
print(string.format("t|%%.3f|%%.3f|%%.3f|%%.4f|%%d",
      (t1 - t0) * 1000 / %(reps)d, (t2 - t1) * 1000 / %(reps)d,
      (t3 - t2) * 1000 / %(reps)d, span * 1000000, n))
"""


def one(d, count, cap, rate):
    r = ask(d, SETUP % {'cap': cap, 'rate': rate, 'count': count}, 'ready|', timeout=600)
    if not r.startswith('ready|'):
        return None, r
    r = ask(d, TIME % {'reps': REPS}, 't|', timeout=600)
    if not r.startswith('t|'):
        return None, r
    f = r.split('|')
    both, clear, over, interval, n = (float(f[1]), float(f[2]), float(f[3]),
                                      float(f[4]), int(f[5]))
    return {'both': both, 'clear': clear, 'over': over, 'interval': interval,
            'n': n, 'read': both - clear,
            'record': count * 1000.0 / rate}, None


def main():
    d = DMM(timeout=600)
    try:
        live = ask(d, 'print("app|" .. tostring(fftsa ~= nil))', 'app|')
        print('app loaded:', live)

        print('\n=== the three statements, by count and capacity, at 100 kS/s ===')
        print('%7s %8s %10s %9s %9s %9s %9s %9s'
              % ('count', 'capacity', 'clear+read', 'clear', 'read', 'overrange',
                 'record', 'overhead'))
        for count in COUNTS:
            for cap in CAPS:
                if cap < count:
                    continue
                m, err = one(d, count, cap, 100000)
                if m is None:
                    print('%7d %8d  %s' % (count, cap, err))
                    continue
                print('%7d %8d %10.2f %9.3f %9.2f %9.3f %9.2f %9.2f'
                      % (count, cap, m['both'], m['clear'], m['read'], m['over'],
                         m['record'], m['both'] - m['record']))
                print('%7s %8s  sample interval %.4f us, so %.1f S/s over %d readings'
                      % ('', '', m['interval'], 1e6 / m['interval'], m['n']))

        print('\n=== 16,384 samples at four rates ===')
        print('%9s %9s %10s %9s %9s %9s %11s'
              % ('rate', 'bin', 'clear+read', 'read', 'record', 'overhead', 'us/reading'))
        for rate in RATES:
            m, err = one(d, 16384, 65536, rate)
            if m is None:
                print('%9d  %s' % (rate, err))
                continue
            print('%9d %9.2f %10.2f %9.2f %9.2f %9.2f %11.4f'
                  % (rate, rate / 16384.0, m['both'], m['read'], m['record'],
                     m['both'] - m['record'], m['interval']))
    finally:
        try:
            d.exec('if PB ~= nil then PB.clear() buffer.delete(PB) PB = nil end',
                   timeout=60)
        except Exception as exc:                    # noqa: BLE001
            print('cleanup reported: %r' % (exc,))
        d.close()


if __name__ == '__main__':
    main()
