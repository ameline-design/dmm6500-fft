#!/usr/bin/env python3
"""What the trace fill costs, and whether it can be made one call.

The trace flickers because a FILL_ONCE buffer is cleared and refilled with 255 points every
frame, and the display task -- which runs only while Lua is blocked, and an append blocks it
for ~55 us -- can paint inside that window and draw a truncated trace. This probe measures
the window, then tests the two ways out that cost nothing: a bulk write, and a shorter
truncated-state lifetime.

The bulk-write lead is from the registration table rather than the manual.
buffer.write.reading is command 226, min_args 2, max_args 7, specified
(readingbuffer, double, [double], [double], [double], [table], [string]) -- the only one of
137 registered functions whose argument list ends in a table. If argument 6 takes a table of
readings, one call replaces 255.

Every stage is read back and tagged. The instrument volunteers event lines, so a reply that
does not carry its tag is a desync and is retried rather than believed.

    python3 -I tools/probe_flicker.py --stage state
    python3 -I tools/probe_flicker.py --stage table
    python3 -I tools/probe_flicker.py --stage window
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..',
                                'dmm6500-serial-decode', 'tools'))
from dmmrun import DMM          # noqa: E402


def ask(d, cmd, tag, tries=4, timeout=60):
    """A tagged read, checked against an event line arriving mid-exchange."""
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
    return 'DESYNC(%s) last=%r' % (tag, r)


def show(label, r):
    print('%-22s %s' % (label, r))


def stage_state(d):
    """Is the app live, and with what geometry? Nothing here writes anything."""
    show('app', ask(d, 'print("A|"..tostring(fftsa ~= nil).."|"'
                       '..tostring(fftsa and fftsa.sg_ncol).."|"'
                       '..tostring(fftsa and fftsa.n))', 'A|'))
    show('trace buffer', ask(d, 'print("B|"..tostring(fftsa.sg_buf ~= nil).."|"'
                                '..tostring(fftsa.sg_buf and fftsa.sg_buf.capacity).."|"'
                                '..tostring(fftsa.sg_buf and fftsa.sg_buf.n).."|"'
                                '..tostring(fftsa.sg_buf and fftsa.sg_buf.fillmode))', 'B|'))
    show('native', ask(d, 'print("C|"..tostring(fftsa.nl and fftsa.nl.ready).."|"'
                          '..tostring(fftsa.nl_frame).."|"..tostring(fftsa.fps))', 'C|'))
    show('checksum api', ask(d, 'print("D|"..tostring(ki ~= nil).."|"'
                                '..tostring(ki and ki.display ~= nil).."|"'
                                '..tostring(ki and ki.display and '
                                'ki.display.getchecksum ~= nil))', 'D|'))


def stage_table(d):
    """Does argument 6 take a table? A scratch buffer, never the bound one."""
    show('make', ask(d, 'ZB = buffer.make(300, buffer.STYLE_WRITABLE_FULL) '
                        'buffer.write.format(ZB, buffer.UNIT_CUSTOM1, buffer.DIGITS_4_5, '
                        'buffer.UNIT_HERTZ, buffer.DIGITS_6_5) '
                        'print("M|"..tostring(ZB ~= nil).."|"..tostring(ZB.capacity))', 'M|'))
    # The baseline: the form the app uses, so a later n is read against a known good one.
    show('plain 5-arg', ask(d, 'local o,e = pcall(function() '
                               'buffer.write.reading(ZB, -40.0, 1000.0, 1, 0) end) '
                               'print("P|"..tostring(o).."|"..tostring(e).."|"'
                               '..tostring(ZB.n))', 'P|'))
    probes = [
        ('empty table  a6', 'buffer.write.reading(ZB, -41.0, 2000.0, 2, 0, {})'),
        ('num table    a6', 'buffer.write.reading(ZB, -42.0, 3000.0, 3, 0, {1,2,3})'),
        ('row table    a6', 'buffer.write.reading(ZB, -43.0, 4000.0, 4, 0, '
                            '{{-50,100,5,0},{-51,200,6,0},{-52,300,7,0}})'),
        ('table as a2   ', 'buffer.write.reading(ZB, {-60,-61,-62})'),
        ('table a2 + a3 ', 'buffer.write.reading(ZB, {-70,-71,-72}, {500,600,700})'),
        ('status a6 str a7', 'buffer.write.reading(ZB, -44.0, 5000.0, 8, 0, {}, "dB")'),
    ]
    for label, call in probes:
        q = ('local n0 = ZB.n local o,e = pcall(function() %s end) '
             'print("Q|"..tostring(o).."|"..tostring(e).."|"..tostring(n0)'
             '.."|"..tostring(ZB.n))' % call)
        show(label, ask(d, q, 'Q|'))
    show('drop', ask(d, 'buffer.delete(ZB) ZB = nil print("Z|done")', 'Z|'))


def stage_window(d):
    """The fill window and the frame period, from the app's own clock."""
    show('phases', ask(d, 'local p = fftsa.ph print("W|"..tostring(p and p.acq).."|"'
                          '..tostring(p and p.fft).."|"..tostring(p and p.disp))', 'W|'))
    show('fill cost', ask(d, 'local b = fftsa.sg_buf local t0 = os.clock() b.clear() '
                             'local i local wr = buffer.write.reading '
                             'for i = 1, 255 do wr(b, -100, i * 100, i, 0) end '
                             'local t1 = os.clock() '
                             'print("F|"..string.format("%.6f", t1 - t0).."|"..tostring(b.n))',
                         'F|'))
    show('one append', ask(d, 'local b = fftsa.sg_buf local t0 = os.clock() '
                              'buffer.write.reading(b, -100, 1e5, 256, 0) '
                              'local t1 = os.clock() '
                              'print("O|"..string.format("%.6f", t1 - t0).."|"'
                              '..tostring(b.n))', 'O|'))
    show('clear cost', ask(d, 'local b = fftsa.sg_buf local t0 = os.clock() b.clear() '
                              'local t1 = os.clock() '
                              'print("K|"..string.format("%.6f", t1 - t0).."|"'
                              '..tostring(b.n))', 'K|'))


def stage_barrier(d):
    """What a display-task round trip costs, and whether one exists that is cheap.

    A barrier straight after the last append cannot stop a paint landing mid-fill, but it
    ends the truncated picture's life there rather than tens of ms later. Only worth having
    if it is cheap, so both candidates are measured against the fill they would follow.
    """
    # display.waitevent is NOT a poll. waitevent(0) blocks until a display event arrives,
    # and a socket session delivers none, so it wedged the interpreter until the socket was
    # dropped. It is not a barrier candidate; a key press is the only thing that releases it.
    show('checksum 1px', ask(d, 'local t0 = os.clock() '
                                'local c = ki.display.getchecksum(400, 200, 401, 201) '
                                'local t1 = os.clock() '
                                'print("G|"..string.format("%.6f", t1 - t0).."|"'
                                '..tostring(c))', 'G|'))
    show('fill then csum', ask(d, 'local b = fftsa.sg_buf local wr = buffer.write.reading '
                                  'local i local t0 = os.clock() b.clear() '
                                  'for i = 1, 255 do wr(b, -100, i * 100, i, 0) end '
                                  'local t1 = os.clock() '
                                  'local c = ki.display.getchecksum(400, 200, 401, 201) '
                                  'local t2 = os.clock() '
                                  'print("H|"..string.format("%.6f|%.6f", t1 - t0, t2 - t1))',
                              'H|'))


def stage_rects(d):
    """The three judging rectangles, with a full trace parked on the glass."""
    for name, box in (('AXIS label row', '8, 350, 792, 400'),
                      ('AXIS dB column', '8, 50, 100, 360'),
                      ('LEFT  plot', '100, 60, 180, 350'),
                      ('RIGHT plot', '700, 60, 780, 350'),
                      ('WHOLE plot', '100, 55, 780, 355')):
        show(name, ask(d, 'print("R|"..tostring(ki.display.getchecksum(%s)))' % box, 'R|'))


def stage_ncol(d, value):
    """Set the points a frame. FILL_ONCE and cleared, so n follows on the next frame."""
    show('before', ask(d, 'print("N|"..tostring(fftsa.sg_ncol).."|"'
                          '..tostring(fftsa.sg_buf.n))', 'N|'))
    show('set', ask(d, 'fftsa.sg_ncol = %d print("S|"..tostring(fftsa.sg_ncol))' % value,
                    'S|'))
    show('predicted window', '%.1f ms of a 105 ms frame -> %.2f flickers/s at 9.5 fps'
         % (value * 0.0804, 9.5 * value * 0.0804 / 105.0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stage', required=True,
                    choices=('state', 'table', 'window', 'barrier', 'rects', 'ncol'))
    ap.add_argument('--value', type=int, default=128)
    a = ap.parse_args()
    d = DMM(timeout=120)
    try:
        if a.stage == 'ncol':
            stage_ncol(d, a.value)
        else:
            {'state': stage_state, 'table': stage_table, 'window': stage_window,
             'barrier': stage_barrier, 'rects': stage_rects}[a.stage](d)
    finally:
        d.close()


if __name__ == '__main__':
    main()
