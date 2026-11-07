#!/usr/bin/env python3
"""Does a COUNT_INFINITE digitize stream keep filling while Lua is busy?

The FFT frame spends its acquisition time blocked in dmm.digitize.read -- 164 ms of the
~310 ms frame at 16,384 samples, with the processor idle. If the converter can instead run
continuously into a FILL_CONTINUOUS ring, the frame stops waiting for an acquisition
altogether: it takes the newest n samples already in the ring. That removes the wait rather
than overlapping it.

notes/DESIGN-double-buffer.md proposes the block structure below but states plainly that
nothing in it has been run on hardware. This runs it, and measures the one thing that
decides the design: the delivered sample rate WHILE Lua holds the interpreter. If the stream
stalls whenever Lua is busy, the ring is worthless and the two-buffer ping-pong is the
fallback.

Also measured here, because both are cheap once the model is up and both are unknowns the
design rests on:
  * buffer.clear() against capacity -- 6.0 made the capture buffer eight times larger at
    the short counts, and if clear is O(capacity) that was a regression
  * trigger.model.load + initiate from Lua -- the per-frame tax the ping-pong would pay

Leaves nothing behind: the model is aborted, the buffer deleted, and the event log reported
so an out-of-band trigger refusal is visible rather than silent.

Measured on 1.7.17a, and the answer is no:

    delay(0.2), processor yielded     20 073 in 200.4 ms   100 164 S/s
    non-yielding Lua, 1204 ms         20 480                17 004 S/s
    non-yielding Lua, 2424 ms         42 473                17 519 S/s

While Lua holds the processor, delivery collapses to 17% of the configured rate, and the
samples are dropped rather than queued: the delay() window advanced at exactly the
configured rate with no catch-up surplus, which a flushed backlog would have shown. So the
acquisition needs the processor, and the time dmm.digitize.read appears to spend waiting is
not reclaimable idle -- there is nothing to overlap it with.

That kills the ring, and the arithmetic kills the ping-pong too even though arming is cheap
at 9.07 ms: processing 140 ms accrues only ~2 400 of 16 384 samples at 17 kS/s, the
remaining ~14 000 then need ~140 ms at full rate, so a frame is ~289 ms against ~304 ms --
5%, and both round to the same seven ticks.

Also measured: buffer.clear() on 100 000 readings is 0.129 ms, so it is O(1) and not
O(capacity). Making the capture buffer eight times larger at the short counts cost nothing.

    python3 -I tools/probe_ring.py
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..',
                                'dmm6500-serial-decode', 'tools'))
from dmmrun import DMM          # noqa: E402

CAP = 100000          # readings in the ring; 2.4 MB at 24 bytes an element
FS = 100000           # the rate the app uses at its floor
RANGE = 10


def q(d, cmd, timeout=60):
    return d.q(cmd, timeout=timeout)


def main():
    d = DMM(timeout=90)
    try:
        # A refusal from trigger.* is posted, not raised, so the log is the only witness.
        d.exec('eventlog.clear()', timeout=30)

        print(q(d, 'rb = buffer.make(%d, buffer.STYLE_STANDARD) '
                   'rb.fillmode = buffer.FILL_CONTINUOUS '
                   'print(string.format("buf|cap=%%d|fill=%%s", rb.capacity, '
                   'tostring(rb.fillmode == buffer.FILL_CONTINUOUS)))' % CAP))

        # buffer.clear() against capacity, before anything is acquiring. Ten clears, so the
        # figure is not one socket round trip's worth of noise.
        print(q(d, 'local t0 = os.clock() local i '
                   'for i = 1, 10 do rb.clear() end '
                   'print(string.format("clear|%d|%%.3f ms each", (os.clock() - t0) * 100))'
                   % CAP))

        print(q(d, 'dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE '
                   'dmm.digitize.range = %d '
                   'dmm.digitize.samplerate = %d '
                   'dmm.digitize.aperture = 1e-6 '
                   'print(string.format("cfg|range=%%s|sr=%%s", '
                   'tostring(dmm.digitize.range), tostring(dmm.digitize.samplerate)))'
                   % (RANGE, FS)))

        # The three blocks the design note proposes. Each in a pcall, because a setblock the
        # firmware will not take reports out of band and the next line would build on it.
        print(q(d, 'local ok1 = pcall(trigger.model.setblock, 1, '
                   'trigger.BLOCK_MEASURE_DIGITIZE, rb, trigger.COUNT_INFINITE) '
                   'local ok2 = pcall(trigger.model.setblock, 2, '
                   'trigger.BLOCK_WAIT, trigger.EVENT_DISPLAY) '
                   'local ok3 = pcall(trigger.model.setblock, 3, '
                   'trigger.BLOCK_MEASURE_DIGITIZE, rb, trigger.COUNT_STOP) '
                   'print(string.format("blocks|%s|%s|%s", tostring(ok1), tostring(ok2), '
                   'tostring(ok3)))'))

        print(q(d, 'local t0 = os.clock() local ok = pcall(trigger.model.initiate) '
                   'print(string.format("initiate|%s|%.2f ms|state=%s", tostring(ok), '
                   '(os.clock() - t0) * 1000, tostring(trigger.model.state())))'))

        time.sleep(0.5)
        print(q(d, 'print(string.format("running|n=%s|start=%s|end=%s|state=%s", '
                   'tostring(rb.n), tostring(rb.startindex), tostring(rb.endindex), '
                   'tostring(trigger.model.state())))'))

        # THE MEASUREMENT. A compute loop, not delay(): delay yields to other tasks, which
        # is the opposite of the question. The loop is bounded, so it cannot run away, and
        # the elapsed time is measured rather than assumed because Lua's speed here is not
        # known. Delivered rate is the index the ring advanced divided by that time.
        for n in (200000, 400000):
            print(q(d, 'local a = rb.endindex local t0 = os.clock() '
                       'local i local x = 0 '
                       'for i = 1, %d do x = x + i end '
                       'local el = os.clock() - t0 local b = rb.endindex '
                       'local adv = b - a if adv < 0 then adv = adv + rb.capacity end '
                       'print(string.format("busy|%%.1f ms|advanced %%d|%%.0f S/s|x=%%d", '
                       'el * 1000, adv, adv / el, x))' % n, timeout=120))

        # And the same window spent in delay(), for the comparison: if the ring advances in
        # both, delivery is hardware-driven and independent of what Lua is doing.
        print(q(d, 'local a = rb.endindex local t0 = os.clock() '
                   'delay(0.2) '
                   'local el = os.clock() - t0 local b = rb.endindex '
                   'local adv = b - a if adv < 0 then adv = adv + rb.capacity end '
                   'print(string.format("delay|%.1f ms|advanced %d|%.0f S/s", '
                   'el * 1000, adv, adv / el))'))

        # Does it keep going, and does n pin at capacity as the rotation note says?
        print(q(d, 'print(string.format("lapped|n=%s|cap=%s|start=%s|end=%s", '
                   'tostring(rb.n), tostring(rb.capacity), tostring(rb.startindex), '
                   'tostring(rb.endindex)))'))

        # The ping-pong's per-frame tax, for the comparison. Aborts the ring first.
        print(q(d, 'trigger.model.abort() '
                   'local t0 = os.clock() local i '
                   'for i = 1, 5 do '
                   '  trigger.model.abort() rb.clear() '
                   '  trigger.model.load("SimpleLoop", 2048, 0, rb) '
                   '  trigger.model.initiate() '
                   'end '
                   'local el = os.clock() - t0 trigger.model.abort() '
                   'print(string.format("arm|%.2f ms each", el * 1000 / 5))',
               timeout=120))
    finally:
        try:
            d.exec('pcall(trigger.model.abort)', timeout=30)
            print(q(d, 'local ev = "" local n = eventlog.getcount() '
                       'if n > 0 then ev = eventlog.next() end '
                       'print(string.format("events|%s|%s", tostring(n), tostring(ev)))'))
            d.exec('if rb ~= nil then pcall(function() rb.clear() end) '
                   'pcall(buffer.delete, rb) rb = nil end', timeout=30)
            print('  cleaned up')
        except Exception as e:                       # noqa: BLE001
            print('  cleanup reported: %r' % (e,))
        d.close()


if __name__ == '__main__':
    main()
