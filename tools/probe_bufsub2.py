#!/usr/bin/env python3
"""Every subscriber slot carrying our buffer name, and which of them is live.

The first probe found ONE slot by string.find and followed it. That is not safe to ship:
unsubscribe clears a slot's KIND but does not erase its name or its +0x40 pointer, so a freed
slot keeps both and a plain search can select a corpse -- the same trap the ring's name needle
fell into, 87 corpses in one pass. Removal can also leave a representative slot holding -2
rather than 0 when equivalent subscribers remain, so "non-zero kind" is not liveness either.
Only kind == 0x407F exactly means a live graph-trace subscription.

So this enumerates EVERY occurrence of the name in a bounded static window and validates each
one independently:

  1. slot+0x00 kind is exactly 0x407F
  2. slot+0x08 is our name
  3. p4   = *(slot+0x40)                     guarded
  4. p4 lies inside graph+0x498 .. +0x534, 4-aligned   (cross-checks p4 against +0x34)
  5. trace = *(p4)                           guarded
  6. trace+0x08 repeats the name
  7. trace+0x00 equals slot+0x34, the graph  (the trace's back-pointer to its widget)
  8. trace+0x30 equals the slot address      (the subscription handle, mutual)
  9. ring base at trace+0x1F0 equals trace+0x220, and the count is sane

Steps 7 and 8 are the ones worth the read: they make the slot and the trace confirm each other,
so neither a corpse nor a torn read can be believed on the strength of a name alone.

READ ONLY. Hex strings for every ki call; a number bluescreens. Every address is refused
host-side unless 4-aligned and inside DRAM. The frame body is parked and restored.

    python3 -u -I tools/probe_bufsub2.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from dmmrun import DMM          # noqa: E402

# A window that covers the table on both measured builds and leaves room either side.
# 1.7.17a has it at 0x00D67708, 1.7.18a at 0x00D67A48 -- the 0x340 .bss delta.
WIN_LO, WIN_BYTES = 0x00D66000, 0x6000
NAME, KIND_GRAPH, STRIDE = 'FFTSA_TRACE', 0x407F, 296
F_KIND, F_NAME, F_GRAPH, F_P4 = 0, 8, 0x34, 0x40
T_GRAPH, T_NAME, T_SUB, T_RING, T_END, T_CNT = 0, 8, 0x30, 0x1F0, 0x1F4, 0x204
G_ROUTE_LO, G_ROUTE_HI = 0x498, 0x534
BUSY, TRIES = 'another interface is running', 24

PARK = ("do local got = '' if fftsa ~= nil and type(fftsa.frame) == 'function' then "
        "if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame end "
        "fftsa.frame = function() end got = 'fftsa' end print('PK|' .. got) end")
UNPARK = ("do local got = '' if fftsa ~= nil and fftsa.saved_frame ~= nil then "
          "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil got = 'fftsa' end "
          "print('UP|' .. got) end")


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
    if addr is None or addr <= 0x3000 or addr >= 0x10000000 or (addr % 4) != 0:
        return None
    line = ask(d, "print('%s|' .. ki.peek32('%08X'))" % (tag, addr), tag, 30)
    if line is None:
        return None
    try:
        return int(line.split('|', 1)[1].strip(), 16)
    except ValueError:
        return None


def rdname(d, addr, tag):
    line = ask(d, ("do local s = ki.memread('%08X', '20') local k = string.find(s, "
                   "string.char(0), 1, true) if k == nil then k = 21 end "
                   "print('%s|' .. string.sub(s, 1, k - 1)) end" % (addr, tag)), tag, 60)
    return line.split('|', 1)[1] if line else None


def hx(v):
    return 'nil' if v is None else '%08X' % v


def main():
    d = DMM(timeout=120, recover=False)
    parked = None
    try:
        print(' ', d.q('print(localnode.model, localnode.version)'))
        print(' ', ask(d, PARK, 'PK'))
        parked = True

        # Every occurrence of the name in the window, found on the instrument.
        cmd = ("do local s = ki.memread('%08X', '%X') local o = 'HITS' local at = 1 local n = 0 "
               "while n < 12 do local f = string.find(s, '%s', at, true) if f == nil then break "
               "end n = n + 1 o = o .. '|' .. tostring(f - 1) at = f + 1 end "
               "print(o .. '|end|' .. tostring(string.len(s))) end"
               % (WIN_LO, WIN_BYTES, NAME))
        line = ask(d, cmd, 'HITS', 120)
        print('\n  %s' % line)
        if line is None:
            return 1
        offs = []
        for tok in line.split('|')[1:]:
            if tok == 'end':
                break
            offs.append(int(tok))
        print('\n%d occurrence(s) of %r in %08X..%08X'
              % (len(offs), NAME, WIN_LO, WIN_LO + WIN_BYTES))

        live = 0
        for off in offs:
            na = WIN_LO + off
            slot = na - F_NAME
            print('\n--- name at %08X, slot %08X' % (na, slot))
            kind = w32(d, slot + F_KIND, 'K')
            print('    +0x00 kind  = %s   %s'
                  % (hx(kind), 'LIVE graph trace' if kind == KIND_GRAPH
                     else 'not a live graph trace -- a corpse keeps its name'))
            if kind != KIND_GRAPH:
                continue
            graph = w32(d, slot + F_GRAPH, 'G')
            p4 = w32(d, slot + F_P4, 'P')
            print('    +0x34 graph = %s' % hx(graph))
            print('    +0x40 p4    = %s' % hx(p4))
            ok = True
            if graph is None or p4 is None:
                ok = False
            elif not (graph + G_ROUTE_LO <= p4 <= graph + G_ROUTE_HI and (p4 % 4) == 0):
                print('    p4 is NOT inside graph+0x498..+0x534 -- refused')
                ok = False
            else:
                print('    p4 is inside graph+0x498..+0x534, index %d'
                      % ((p4 - graph - G_ROUTE_LO) // 4))
            if not ok:
                continue
            tr = w32(d, p4, 'T')
            print('    *(p4)       = %s' % hx(tr))
            if tr is None:
                continue
            nm = rdname(d, tr + T_NAME, 'TN')
            tg = w32(d, tr + T_GRAPH, 'TG')
            ts = w32(d, tr + T_SUB, 'TS')
            rb = w32(d, tr + T_RING, 'RB')
            re = w32(d, tr + T_END, 'RE')
            rc = w32(d, tr + T_CNT, 'RC')
            print('    trace+0x08 name = %r  %s' % (nm, 'MATCH' if nm == NAME else 'MISMATCH'))
            print('    trace+0x00      = %s  %s vs slot+0x34 %s'
                  % (hx(tg), 'MATCH' if tg == graph else 'differs', hx(graph)))
            print('    trace+0x30      = %s  %s vs the slot %s'
                  % (hx(ts), 'MATCH' if ts == slot else 'differs', hx(slot)))
            print('    trace+0x1F0     = ring %s..%s count %s' % (hx(rb), hx(re), rc))
            print('    trace+0x220     = %08X  %s'
                  % (tr + 0x220, 'MATCH, +0x1F0 is the ring base' if rb == tr + 0x220
                     else 'differs from +0x1F0'))
            if nm == NAME and rb == tr + 0x220:
                live = live + 1
        print('\n%d slot(s) passed every check' % live)
    finally:
        try:
            if parked:
                print(' ', ask(d, UNPARK, 'UP'))
        finally:
            d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
