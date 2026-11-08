#!/usr/bin/env python3
"""display.setvalue and display.getvalue: the last untried bulk path.

Of 1376 registered functions exactly five take a table. Three are accounted for
(buffer.channelmath, buffer.write.reading, display.graph.add) and setpixel's table form is the
documented resampling path. display.setvalue -- command 36, descriptor 0x00EB2418, signature
(int32, table, [enum]), min_args 2 so THE TABLE IS MANDATORY -- is undocumented and has never
been called or disassembled.

If it sets a graph's points from a table, the per-frame fill stops being 510 blocking IPC
round trips at ~54 us each and becomes one call. That is the only remaining way under the
~27 ms floor those round trips impose, because every other bulk path is closed: removeall+add
blanks the trace, and a scale-triggered re-burst costs 121 ms with visible axis flicker.

getvalue goes first. It takes one argument and writes nothing, so whatever it answers for a
graph says what "value" means for this object type before anything is set.

Each call is pcall'ed and the event log is read immediately after, because a refused display
call reports out of band rather than raising -- and the plot interior is checksummed around
each one, since hashing the whole screen is useless when the THD line and frame rate move on
their own.

EVERY STATEMENT IS ONE LINE and under 1000 bytes.

    python3 -u -I tools/probe_setvalue.py
"""
import os
import sys
import time

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
from dmmrun import DMM                                                   # noqa: E402

PLOT = (100, 60, 780, 340)


def ask(d, cmd, tag, tries=12, timeout=120):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1.5)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def park(d):
    """A running frame loop holds the interpreter and swallows replies; confirm by state."""
    stmt = ("do if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame "
            "fftsa.frame = function() end end end")
    for _ in range(30):
        d.drain()
        d.send(stmt)
        time.sleep(0.4)
        r = d.q("print('K|' .. tostring(fftsa.saved_frame ~= nil))", timeout=20)
        if r is not None and str(r).startswith('K|true'):
            return True
        time.sleep(1)
    raise SystemExit('could not park the frame loop; is the app running?')


def unpark(d):
    stmt = ("do if fftsa.saved_frame ~= nil then fftsa.frame = fftsa.saved_frame "
            "fftsa.saved_frame = nil end end")
    for _ in range(30):
        d.drain()
        d.send(stmt)
        time.sleep(0.4)
        r = d.q("print('K|' .. tostring(fftsa.saved_frame == nil))", timeout=20)
        if r is not None and str(r).startswith('K|true'):
            return True
        time.sleep(1)
    return False


def sum_plot(d):
    x1, y1, x2, y2 = PLOT
    return ask(d, "print('C|' .. tostring(ki.display.getchecksum(%d,%d,%d,%d)))"
               % (x1, y1, x2, y2), 'C|')[2:].strip()


def drain_events(d):
    """Whatever is in the log, as text, so a refusal is attributed to the call that caused
    it. showevents empties the log, which is what makes the next reading clean."""
    # eventlog.getevent does not exist on this firmware -- measured, it is nil. eventlog.next()
    # pops one event and answers its number, so the log is drained a number at a time and the
    # loop is bounded, because an unbounded one inside a single TSP statement cannot be
    # interrupted.
    r = ask(d, "do local n = eventlog.getcount() local o, i = '', nil "
               "if n > 24 then n = 24 end "
               "for i = 1, n do local ok, v = pcall(eventlog.next) "
               "if ok then o = o .. tostring(v) .. ' ' else o = o .. '?' end end "
               "print('E|' .. tostring(n) .. '|' .. o) end", 'E|', timeout=60)
    return r[2:].strip()


CASES = [
    # (label, the Lua expression for argument 2, optional third argument)
    ('empty table',              '{}',                                None),
    ('one number',               '{-20}',                             None),
    ('two numbers',              '{-20, -21}',                        None),
    ('x,y pair',                 '{1000, -20}',                       None),
    ('ten dB values',            'ZT10',                              None),
    ('ten dB values, ELEMENT_DATA', 'ZT10',                           'display.ELEMENT_DATA'),
    ('ten {x,y} rows',           'ZTR',                               None),
    ('255 dB values',            'ZT255',                             None),
]


def main():
    d = DMM(recover=False, timeout=240)
    try:
        d.drain()
        park(d)
        print('park  : parked')
        st = ask(d, one_line("do local b = fftsa.sg_buf",
                             "print('S|' .. tostring(fftsa.sg_graph) .. ',' .. tostring(b.n)",
                             ".. ',' .. tostring(fftsa.sg_flo_hz) .. ',' .. tostring(fftsa.sg_fhi_hz)) end"),
                  'S|')
        gid, n, flo, fhi = st[2:].split(',')
        print('state : graph id %s, trace %s points, span %s..%s Hz' % (gid, n, flo, fhi))
        print('events: %s' % drain_events(d))

        # getvalue first: one argument, writes nothing.
        for target, label in ((gid, 'the graph'), ('fftsa.sg_scr', 'its screen')):
            r = ask(d, "do local ok, v = pcall(display.getvalue, %s) "
                       "print('G|' .. tostring(ok) .. '|' .. tostring(v)) end" % target, 'G|')
            print('getvalue(%-12s): %s' % (label, r[2:]))
            print('  events: %s' % drain_events(d))

        # Tables built once, so a timing or a refusal is about the call and not the build.
        ask(d, "do ZT10, ZT255, ZTR = {}, {}, {} local i "
               "for i = 1, 10 do ZT10[i] = -100 + i end "
               "for i = 1, 255 do ZT255[i] = -120 + i / 4 end "
               "for i = 1, 10 do ZTR[i] = {1000 * i, -100 + i} end print('T|built') end", 'T|')

        print()
        print('%-32s %-26s %s' % ('setvalue case', 'result', 'plot'))
        for label, arg2, arg3 in CASES:
            before = sum_plot(d)
            call = ("pcall(display.setvalue, %s, %s%s)"
                    % (gid, arg2, (', ' + arg3) if arg3 else ''))
            r = ask(d, "do local ok, e = %s print('V|' .. tostring(ok) .. '|' .. tostring(e)) end"
                    % call, 'V|')
            ev = drain_events(d)
            after = sum_plot(d)
            print('%-32s %-26s %s' % (label, r[2:][:26],
                                      'CHANGED' if after != before else 'same'))
            if ev and not ev.startswith('0|'):
                print('    events: %s' % ev[:150])
    finally:
        d.drain()
        d.send('ZT10, ZT255, ZTR = nil, nil, nil')
        time.sleep(0.3)
        print()
        print('unpark: %s' % ('running' if unpark(d) else 'COULD NOT RESTORE THE FRAME LOOP'))
        d.close()


def one_line(*parts):
    return ' '.join(p.strip() for p in parts)


if __name__ == '__main__':
    main()
