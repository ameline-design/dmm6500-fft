#!/usr/bin/env python3
"""Does the static buffer-subscriber table name our trace, and does it reach the trace object?

THE QUESTION. The pixel path finds the display task's trace ring by scanning DRAM for the buffer
name -- 27 MB and 3.1 s on a clean boot. The firmware subscribes a graph trace BY NAME into a
static table, so the same answer may be two reads away.

Read off the decompiled 1.7.17a firmware, not guessed:

  bufsub_subscribe(kind, param_2, name, param_4)    entry 0x000B4708, fns8.c:1
  graph_trace_add calls (0x407F, graph, trace+0x08, &trace_array_element)
                                                    entry 0x0002D3C4, fns6.c:792-798
  table 0x00D67A48  stride 0x128 (296)  count at 0x00D679F8
    +0x00 kind    +0x08 name    +0x34 graph widget    +0x40 address of the array element

So the chain under test is  trace = *(*(slot+0x40)),  confirmed by trace+0x08 carrying the same
name. It also settles a second question the app has been getting wrong: it walks graph+0x3EC for
the trace array on the authority of a prose note, while graph_trace_add stores the trace at
graph+0x498 indexed by graph+0x538. Both offsets are real in the code, and the instrument has
reported "trace slot 3 of the widget is 0, and none before it carried the name" every launch.

READ ONLY, and bounded. The name search runs ON the instrument: 8 KB of slot bytes carries NUL
and CR, and printing that through the socket would corrupt the line protocol -- so only indices
and values come back. Every address is checked for 4-alignment and DRAM range before it is read,
because ki.peek32 is an lwz with no validation and a bad address bluescreens, which ki.reboot
cannot recover. ki.memread/peek32 take HEX STRINGS; a number bluescreens.

Nothing is written. recover=False, so clear_dead_sockets() cannot abort the running app. The one
global it defines on the instrument is set back to nil in the finally.

    python3 -u -I tools/probe_bufsub.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from dmmrun import DMM          # noqa: E402

TABLE, COUNT, STRIDE = 0x00D67A48, 0x00D679F8, 296
KIND_GRAPH, NAME = 0x407F, 'FFTSA_TRACE'
MAXSLOTS = 64

PARK = ("do local got = '' if fftsa ~= nil and type(fftsa.frame) == 'function' then "
        "if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame end "
        "fftsa.frame = function() end got = 'fftsa' end print('PK|' .. got) end")
UNPARK = ("do local got = '' if fftsa ~= nil and fftsa.saved_frame ~= nil then "
          "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil got = 'fftsa' end "
          "print('UP|' .. got) end")

# Lua 5.0.2: no hex literals anywhere below, and no adjacent string-literal concatenation.
HELPER = ("do _bsw = function(s, o) return string.byte(s, o + 1) * 16777216 "
          "+ string.byte(s, o + 2) * 65536 + string.byte(s, o + 3) * 256 "
          "+ string.byte(s, o + 4) end print('HELP|ok') end")


# A key-launched app owns the interpreter, and a socket statement is refused with
# "A command from another interface is running" until it yields. Parking the frame function is
# itself such a statement, so the refusals have to be ridden out rather than treated as an
# error -- and ABORT is NOT the answer: it would stop the app, which is the thing under test.
BUSY = 'another interface is running'
TRIES = 24


def ask(d, cmd, tag, timeout=90):
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    i = 0
    while i < TRIES:
        i = i + 1
        r = str(d.q(cmd, timeout=timeout))
        for line in r.splitlines():
            if line.startswith(tag + '|'):
                return line
        if BUSY not in r:
            return None
    print('    %s: still refused after %d tries' % (tag, TRIES))
    return None


def w32(d, addr, tag):
    """One guarded word. Refused rather than read if it is not a 4-aligned DRAM address."""
    if addr is None or addr <= 0x3000 or addr >= 0x10000000 or (addr % 4) != 0:
        print('    refused %s: %s is not a 4-aligned DRAM address'
              % (tag, 'nil' if addr is None else '%08X' % addr))
        return None
    line = ask(d, "print('%s|' .. ki.peek32('%08X'))" % (tag, addr), tag, 30)
    if line is None:
        return None
    try:
        return int(line.split('|', 1)[1].strip(), 16)
    except ValueError:
        return None


def main():
    d = DMM(timeout=120, recover=False)
    parked = None
    try:
        print(' ', d.q('print(localnode.model, localnode.version)'))
        # Park the frame body, the same way push_tspa does: the app drives frames from a display
        # timer that resolves fftsa.frame by name, so emptying the field stops the body without
        # touching the timer. Restored in the finally -- an app left parked stops drawing.
        print(' ', ask(d, PARK, 'PK'))
        parked = True
        print(' ', d.q("print('APP|' .. tostring(fftsa ~= nil) .. '|' .. "
                       "tostring((fftsa ~= nil) and fftsa.VERSION or '-'))"))
        print(' ', ask(d, HELPER, 'HELP'))

        n = w32(d, COUNT, 'N')
        print('\nslot count at %08X: %s' % (COUNT, n))
        if n is None or n < 1 or n > MAXSLOTS:
            print('  not a plausible count, walking %d slots' % MAXSLOTS)
            n = MAXSLOTS

        # The name search, on the instrument. One read of the whole table, one string.find.
        cmd = ("do local n = %d local s = ki.memread('%08X', string.format('%%X', n * %d)) "
               "local at = string.find(s, '%s', 1, true) local o = 'FIND|' .. tostring(n) "
               ".. '|' .. tostring(string.len(s)) .. '|' .. tostring(at) "
               "if at ~= nil then o = o .. '|' .. tostring(math.floor((at - 9) / %d)) "
               ".. '|' .. tostring(math.mod(at - 9, %d)) end print(o) end"
               % (n, TABLE, STRIDE, NAME, STRIDE, STRIDE))
        line = ask(d, cmd, 'FIND', 120)
        print('  %s' % line)
        if line is None:
            print('\nthe table read was refused; nothing further is safe to try')
            return 1
        f = line.split('|')
        if len(f) < 5 or f[3] == 'nil':
            print('\nNO SLOT CARRIES %r in %s bytes. The chain does not start here.'
                  % (NAME, f[2] if len(f) > 2 else '?'))
            return 0
        # THE SLOT COMES FROM THE NAME, NOT FROM THE TABLE BASE, and that is what makes this
        # build-independent. bufsub_subscribe copies the name to slot+0x08, so a hit anywhere in
        # the window names its own slot. Measured: the decompiled base is 0x00D67A48 and the hit
        # sat 648 bytes past it -- 2.19 strides, impossible -- while against 0x00D67708 it is
        # exactly 5 strides plus 8. That 0x340 is the .bss delta already measured between
        # 1.7.17a and 1.7.18a, the same delta between the two PX_OBJTAB_HINTS entries. So the
        # decompilation is the later build and the instrument is the earlier one. Deriving the
        # slot from the hit makes which build it is stop mattering.
        name_addr = TABLE + int(f[3]) - 1
        base = name_addr - 8
        print('\n%r at %08X, so its slot is %08X' % (NAME, name_addr, base))
        print('  against the decompiled base %08X that is %d bytes, %.2f strides'
              % (TABLE, base - TABLE, (base - TABLE) / float(STRIDE)))
        for guess, why in ((TABLE, 'as decompiled'), (TABLE - 0x340, 'less the 0x340 .bss delta')):
            off = base - guess
            if off >= 0 and (off % STRIDE) == 0:
                print('  against %08X (%s): slot %d exactly' % (guess, why, off // STRIDE))
        # The slot's fields, read out of the one copy already on the instrument.
        cmd2 = ("do local s = ki.memread('%08X', '128') "
                "print('SLOT|' .. string.format('%%X', _bsw(s, 0)) .. '|' .. "
                "string.format('%%X', _bsw(s, 52)) .. '|' .. "
                "string.format('%%X', _bsw(s, 64)) .. '|' .. "
                "string.format('%%X', _bsw(s, 72)) .. '|' .. "
                "string.format('%%X', _bsw(s, 76))) end" % base)
        line2 = ask(d, cmd2, 'SLOT', 60)
        print('  %s' % line2)
        if line2 is None:
            return 1
        g = line2.split('|')
        kind = int(g[1], 16)
        graph = int(g[2], 16)
        p4 = int(g[3], 16)
        print('\n  slot at %08X' % base)
        print('    +0x00 kind  = %06X   %s'
              % (kind, 'a graph trace' if kind == KIND_GRAPH
                 else 'NOT a graph trace (wanted %06X)' % KIND_GRAPH))
        print('    +0x34 graph = %08X' % graph)
        print('    +0x40 p4    = %08X' % p4)

        print('\n  the chain: trace = *(*(slot+0x40))')
        tr = w32(d, p4, 'P4')
        print('    *(slot+0x40) = %s' % ('nil' if tr is None else '%08X' % tr))
        if tr is not None:
            ln = ask(d, ("do local s = ki.memread('%08X', '20') local k = string.find(s, "
                         "string.char(0), 1, true) if k == nil then k = 21 end "
                         "print('TN|' .. string.sub(s, 1, k - 1)) end" % (tr + 8)), 'TN', 60)
            got = ln.split('|', 1)[1] if ln else '<refused>'
            print('    trace+0x08   = %r   %s'
                  % (got, 'MATCH -- the chain reaches the trace object'
                     if got == NAME else 'does NOT match'))
            rb = w32(d, tr + 0x1F0, 'RB')
            re = w32(d, tr + 0x1F4, 'RE')
            rc = w32(d, tr + 0x204, 'RC')
            print('    trace+0x1F0  ring %s..%s  count %s'
                  % ('nil' if rb is None else '%08X' % rb,
                     'nil' if re is None else '%08X' % re, rc))
            print('    trace+0x220  %08X   (where the records start)' % (tr + 0x220))

        # And the two candidate arrays in the widget, side by side.
        if graph > 0x3000:
            idx = w32(d, graph + 0x538, 'IX')
            print('\n  graph+0x538 index = %s' % idx)
            for off, label in ((0x3EC, '0x3EC  the app walks this'),
                               (0x498, '0x498  graph_trace_add writes this')):
                vals = []
                for k in range(0, 6):
                    v = w32(d, graph + off + k * 4, 'A')
                    vals.append('nil' if v is None else '%08X' % v)
                    if v == 0:
                        break
                hit = ''
                if tr is not None and ('%08X' % tr) in vals:
                    hit = '   <-- holds the trace'
                print('  graph+%s = %s%s' % (label, ' '.join(vals), hit))
    finally:
        try:
            ask(d, 'do _bsw = nil print("CLEAN|ok") end', 'CLEAN', 30)
        finally:
            try:
                if parked:
                    print(' ', ask(d, UNPARK, 'UP'))
            finally:
                d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
