#!/usr/bin/env python3
"""Where does the trace the graph paints actually live, and what does an append change?

The graph does not paint from the bound buffer: native code once wrote all 255 (dB, Hz) pairs
into its chunk storage, rewound every descriptor cursor, and the glass drew nothing while the
buffer read back correct from Lua. So either there is a second copy of the points that only
buffer.write.reading feeds, or there is a field the append path moves that an in-place write
does not. This probe looks for both, from the same setup.

  find    from fftsa.sg_buf to its native instance, column descriptors, chunk and element 0.
          Reuses the walk in notes/firmware/probe_coldesc.py: the instance header is a
          NUL-terminated list of 16-byte (prev_id, id, ptrA, ptrB) records, and a 32 KB
          allocator payload is recognised by W(p-12)==0x8010 and W(p-8)==0x8000, with no
          reference to any address.

  needle  fill the bound buffer through the sanctioned path with 255 readings on one binade,
          then sweep the heap for one of those values' eight bytes. The chunk is one hit and
          the statistics records are others; any further hit is a second copy of the points.

  diff    three identical sanctioned fills, snapshotting the descriptor neighbourhood after
          each, then the same elements laid down by memwrite. A counter is identifiable by
          its arithmetic, so the report is which words stepped by a constant -- not merely
          which differ, because the Welford accumulator at +0x160, the two iterators at +0x4C
          and +0x5C and the last-written pair at +0x6C all differ on every fill.

Reads go through the KG guard. Writes stay off unless --arm is given.

    python3 -u -I tools/probe_tracecopy.py --stage find
    python3 -u -I tools/probe_tracecopy.py --stage needle
    python3 -u -I tools/probe_tracecopy.py --stage diff
"""
import argparse
import os
import re
import struct
import sys

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
sys.path.insert(0, os.path.join(SIB, 'notes', 'firmware'))
from dmmrun import DMM                                                   # noqa: E402
from fwguard import Guard                                                # noqa: E402

BLK_TOTAL, BLK_PAYLOAD = 0x8010, 0x8000
IMAGE = '/tmp/fw1717a/flash17.bin'
HEAP = (0, 0)                  # filled from the guard's section table, never hardcoded
NEEDLE_BASE = 1000000          # one binade: high word steps by 2, low word stays 0
NPTS = 255


def hexaddr(s):
    m = re.search(r'[:=]\s*(?:0x)?([0-9A-Fa-f]{5,8})', s or '')
    if m:
        return int(m.group(1), 16)
    m = re.search(r'\b(?:0x)?([0-9A-Fa-f]{5,8})\b', s or '')
    return int(m.group(1), 16) if m else None


def ask(d, cmd, tag, tries=3, timeout=60):
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def install_guard(g, d):
    """Guard.install reads one reply per block, and a volunteered event line shifts them, so
    the blocks go in through the tagged retry instead. Redefining KG.* is idempotent."""
    d.drain()
    for i, stmt in enumerate(g.tsp()):
        ask(d, stmt, 'KG|%d' % (i + 1), timeout=30)
    hlo = g.named['.heap'][0]
    r = ask(d, "print('KGV|'..tostring(KG.rd(%d,4))..'|'..tostring(KG.hp(%d,4))..'|'"
               "..tostring(KG.wr(%d,4)))" % (hlo, hlo, hlo), 'KGV|')
    want = 'KGV|true|true|false'
    if r.strip() != want:
        raise SystemExit('guard self-test: got %r, wanted %r' % (r.strip(), want))
    print('guard  : installed, heap readable, write refused while unarmed')


def helpers(d):
    """IS32K recognises a 32 KB allocator payload; WD returns a run of words in one reply."""
    ask(d, "do function IS32K(p) if p == nil then return false end "
           "local t = KG.w(p-12) local y = KG.w(p-8) "
           "return t == %d and y == %d end "
           "function WD(a,n) local s = '' local i for i = 0, n-1 do "
           "s = s..KG.hx(a+i*4)..' ' end return s end "
           "print('HLP|ok') end" % (BLK_TOTAL, BLK_PAYLOAD), 'HLP|')
    r = ask(d, "do function B32(a,n) local s = '' local i for i = 0, n-1 do "
               "local v = KG.w(a+i*4) if v ~= nil and IS32K(v) then "
               "s = s..string.format('%X:%08X ', i*4, v) end end return s end "
               "print('HL2|ok') end", 'HL2|')
    return r.strip() == 'HL2|ok'


def words(d, addr, n):
    q = ask(d, "print('W|'..WD(%d,%d))" % (addr, n), 'W|')
    return [None if t.startswith('-') else int(t, 16) for t in q[2:].split()]


def find_descriptor(d, expr='fftsa.sg_buf'):
    """A buffer handle -> native instance -> the column whose pointers reach a 32 KB block."""
    mt = ask(d, "do local m = getmetatable(%s) "
                "print('M|'..tostring(m.CClassRef)) end" % expr, 'M|')
    uda = hexaddr(mt.split('|', 1)[1])
    inst = hexaddr(ask(d, "print('U|'..KG.hx(%d))" % uda, 'U|'))
    print('userdata payload 0x%08X   native instance 0x%08X' % (uda, inst))
    hdr = words(d, inst, 16)
    for r in range(0, len(hdr), 4):
        print('  inst +%03X  %s' % (r * 4, ' '.join(
            '--------' if x is None else '%08X' % x for x in hdr[r:r + 4])))

    roots = []
    for r in range(1, 4):
        if r * 4 + 3 >= len(hdr) or not hdr[r * 4 + 1]:
            break
        cid, pa, pb = hdr[r * 4 + 1], hdr[r * 4 + 2], hdr[r * 4 + 3]
        print('  column id %d -> (0x%08X, 0x%08X)' % (cid, pa or 0, pb or 0))
        for p in (pa, pb):
            if p:
                roots.append((p, 'id%d' % cid))

    # A directed walk, as in notes/firmware/probe_coldesc.py: children are taken only from
    # the structured head of a block, which keeps stale heap text out of the frontier, and a
    # 32 KB allocator payload is recognised by its header rather than by any address.
    hlo, hhi = HEAP
    seen = {inst: True}
    work = [(p, 1, path) for p, path in roots]
    for p, _ in roots:
        seen[p] = True
    found = []
    while work:
        addr, depth, path = work.pop(0)
        hits = blocks32(d, addr, 36)
        w = words(d, addr, 36)
        if w is None:
            continue
        if hits:
            found.append((addr, path, hits, w))
        if depth < 4:
            for i in range(min(12, len(w))):
                v = w[i]
                if v and v not in seen and hlo <= v < hhi:
                    seen[v] = True
                    work.append((v, depth + 1, path + '+0x%X' % (i * 4)))

    for addr, path, hits, w in found:
        vec, first = w[0x44 // 4], w[0x48 // 4]
        elemsize, perchunk = w[0x08 // 4], w[0x0C // 4]
        cap, n = w[0x74 // 4], w[0x78 // 4]
        geom = (elemsize and perchunk and elemsize * perchunk == 32768)
        print('  via %-22s 0x%08X  elemsize %-6s perchunk %-5s cap %-6s n %-6s  %s'
              % (path, addr, elemsize, perchunk, cap, n,
                 ' '.join('+0x%X->0x%08X' % h for h in hits)))
        if geom and vec and first:
            print('  -> descriptor 0x%08X, chunk vector 0x%08X, first chunk 0x%08X'
                  % (addr, vec, first))
            return addr, vec, first, cap, n
    return None, None, None, None, None


def blocks32(d, addr, n):
    q = ask(d, "print('B|'..B32(%d,%d))" % (addr, n), 'B|', timeout=60)
    out = []
    for t in q[2:].split():
        off, val = t.split(':')
        out.append((int(off, 16), int(val, 16)))
    return out


def park(d):
    """Stop frames without touching a display object.

    The timer's event command is "if fftsa ~= nil and fftsa.frame ~= nil then fftsa.frame()
    end", so replacing fftsa.frame with an empty function stops all frame work and nothing
    else. This matters: the timer DOES fire between a probe's queries, which is how a needle
    fill came to be overwritten in the middle of the sweep looking for it.
    """
    return ask(d, "do if FFTSA_SAVEFRAME == nil then FFTSA_SAVEFRAME = fftsa.frame end "
                  "fftsa.frame = function() end print('PK|parked') end", 'PK|')


def unpark(d):
    return ask(d, "do if FFTSA_SAVEFRAME ~= nil then fftsa.frame = FFTSA_SAVEFRAME "
                  "FFTSA_SAVEFRAME = nil end print('UP|'..tostring(fftsa.frame ~= nil)) end",
               'UP|')


def sweep(d, pat, note='', window=None):
    """Every address holding these bytes. memread runs at 48 MB/s and string.find at 44, so
    214 MB in 4 MB slices is seconds; slices overlap by the needle length so a hit
    straddling a boundary is not lost. A window narrows it when the target's neighbourhood
    is known, which it is -- the descriptor and its chunks sit near the native instance."""
    lo, hi = window if window else HEAP
    lo, hi = max(lo, HEAP[0]), min(hi, HEAP[1])
    step = 0x400000
    pat_lua = ''.join('\\%d' % b for b in pat)
    hits, a = [], lo
    while a < hi:
        ln = min(step + len(pat), hi - a)
        q = ask(d, "do local s = KG.read(%d, %d) local o = '' local p = 1 "
                   "if s ~= nil then while true do local f = string.find(s, '%s', p, 1) "
                   "if f == nil then break end o = o..string.format('%%X ', %d + f - 1) "
                   "p = f + 1 end end print('S|'..o) end" % (a, ln, pat_lua, a),
                'S|', timeout=120)
        for t in q[2:].split():
            v = int(t, 16)
            if v not in hits:
                hits.append(v)
        a += step
    hits.sort()
    print('sweep  : %-28s %d hit(s)%s'
          % (pat.hex(), len(hits), (' ' + note) if note else ''))
    return hits


def find_by_geometry(d, expr):
    """The descriptor, found by its capacity and n -- which is what the notes recommend and
    what works. A content sweep is the wrong tool twice over: the readings may repeat, and
    a 680-element buffer is one 21,760-byte allocator block rather than a 32 KB chunk, so
    the block-header recogniser finds nothing either.

    capacity sits at descriptor +0x74 and n at +0x78, adjacent, so u32(cap)..u32(n) is a
    specific big-endian needle. Candidates are then held to the two owner self-pointers.
    """
    cn = ask(d, "do local b = %s print('CN|'..tostring(b.capacity)..'|'..tostring(b.n)..'|'"
                "..tostring(getmetatable(b).CClassRef)) end" % expr, 'CN|').split('|')
    cap, n = int(cn[1]), int(cn[2])
    uda = hexaddr(cn[3])
    inst = hexaddr(ask(d, "print('U|'..KG.hx(%d))" % uda, 'U|')) if uda else None
    pat = struct.pack('>II', cap, n)
    hits = []
    if inst:
        near = (inst - 0x800000, inst + 0x800000)
        print('       : native instance 0x%08X, trying 0x%08X..0x%08X first'
              % (inst, max(near[0], HEAP[0]), min(near[1], HEAP[1])))
        hits = sweep(d, pat, 'for capacity %d, n %d (near)' % (cap, n), window=near)
    if not hits:
        hits = sweep(d, pat, 'for capacity %d, n %d (whole heap)' % (cap, n))
    for h in hits:
        b = h - 0x74
        w = words(d, b, 32)
        if len(w) < 32:
            continue
        own1, own2 = w[0x54 // 4], w[0x64 // 4]
        if own1 != b or own2 != b:
            continue
        elemsize, perchunk = w[0x08 // 4], w[0x0C // 4]
        vec, first = w[0x44 // 4], w[0x48 // 4]
        print('  descriptor 0x%08X: elemsize %s perchunk %s vector 0x%08X first 0x%08X'
              % (b, elemsize, perchunk, vec or 0, first or 0))
        e0 = words(d, first, 10) if first else None
        if e0:
            v = struct.unpack('>d', struct.pack('>II', e0[0] or 0, e0[1] or 0))[0]
            x = struct.unpack('>d', struct.pack('>II', e0[5] or 0, e0[6] or 0))[0]
            print('  element 0: reading %.17g  ts %s/%s  status %08X  extra %.17g'
                  % (v, e0[2], e0[3], e0[4] or 0, x))
        return b, vec, first, cap, n, elemsize
    print('  no candidate held both owner self-pointers')
    return None, None, None, cap, n, None


def find_array(d, expr, base):
    """The element array, found by its contents rather than by a block shape.

    A 680-element buffer is 21,760 bytes, so it is ONE allocator block and not a 32 KB
    chunk -- which is why the block-header recogniser in probe_coldesc.py finds nothing
    here. A fill on one binade is unmistakable instead: every value shares an exponent, so
    the high word steps by a constant and the low word stays zero.
    """
    print('fill   : %s <- %d..%d  %s'
          % (expr, base + 1, base + NPTS,
             ask(d, "do local b = %s local wr = buffer.write.reading local i "
                    "b.clear() for i = 1, %d do wr(b, %d + i, 3000000 + i, i, 0) end "
                    "print('F|'..tostring(b.n)) end" % (expr, NPTS, base), 'F|', timeout=120)))
    mid = 128
    # The needle is the value the buffer says it HOLDS, not the one that was written. The
    # format carries DIGITS_4_5, and a stored reading quantised to five significant digits
    # is not the double that went in -- a sweep for the written value finds nothing and
    # looks like "there is no array", which is how an hour goes missing.
    rb = ask(d, "do local b = %s print('RB|'..string.format('%%.17g', b.readings[%d])"
                "..'|'..string.format('%%.17g', b.readings[%d])"
                "..'|'..string.format('%%.17g', b.readings[%d])) end"
             % (expr, mid - 1, mid, mid + 1), 'RB|')
    prev_v, mid_v, next_v = [float(x) for x in rb.split('|')[1:4]]
    print('stored : %.17g  %.17g  %.17g   (wrote %d %d %d)'
          % (prev_v, mid_v, next_v, base + mid - 1, base + mid, base + mid + 1))
    hits = sweep(d, struct.pack('>d', mid_v), 'for stored value %.17g' % mid_v)
    arrays, others = [], []
    for h in hits:
        w = words(d, h - 32, 24)
        prev = struct.unpack('>d', struct.pack('>II', w[0] or 0, w[1] or 0))[0]
        nxt = struct.unpack('>d', struct.pack('>II', w[16] or 0, w[17] or 0))[0]
        if prev == prev_v and nxt == next_v:
            arrays.append(h)
            print('  0x%08X  stride 32, neighbours %.0f and %.0f -> element %d of an array'
                  % (h, prev, nxt, mid))
        else:
            others.append(h)
            print('  0x%08X  not a stride-32 run (prev %.6g next %.6g)' % (h, prev, nxt))
    if not arrays:
        return None, others
    e0 = arrays[0] - (mid - 1) * 32
    print('  -> element 0 at 0x%08X, %d bytes for %d points' % (e0, NPTS * 32, NPTS))
    return e0, others


def sanctioned_fill(d, base=NEEDLE_BASE):
    """255 readings through buffer.write.reading on the bound buffer, one binade apart."""
    return ask(d, "do local b = fftsa.sg_buf local wr = buffer.write.reading local i "
                  "b.clear() for i = 1, %d do wr(b, %d + i, 3000000 + i, i, 0) end "
                  "print('F|'..tostring(b.n)) end" % (NPTS, base), 'F|', timeout=120)


def stage_find(d):
    print('A:')
    find_by_geometry(d, 'fftsa.sg_buf')


def stage_needle(d):
    """Is there a second copy of the points anywhere in the heap?

    Parked first. The frame timer fires between a probe's queries, so an unparked sweep
    looks for a needle the app has already overwritten -- which is exactly what happened on
    the first attempt and reported a single unrelated hit.
    """
    print('park   :', park(d))
    e0, others = find_array(d, 'fftsa.sg_buf', NEEDLE_BASE)
    print('\n%d hit(s) that are not the element array: %s'
          % (len(others), ' '.join('0x%08X' % h for h in others) or 'none'))
    for h in others:
        w = words(d, h - 64, 40)
        print('\n  around 0x%08X' % h)
        for r in range(0, len(w), 4):
            print('   %+05X  %s' % (r * 4 - 64, ' '.join(
                '--------' if x is None else '%08X' % x for x in w[r:r + 4])))
    if not others:
        print('\nThe value exists in exactly one place: the buffer itself. Whatever the'
              '\ndisplay task paints from, it is not a plain double copy of the readings.')
    # A float32 copy would not match the double needle, and a scaled or pixel-space copy
    # would not match either -- so the cheap second representation is checked before any
    # conclusion is drawn about there being no copy at all.
    rb = ask(d, "do print('R2|'..string.format('%.17g', fftsa.sg_buf.readings[128])) end",
             'R2|')
    v = float(rb.split('|')[1])
    f32 = sweep(d, struct.pack('>f', v), 'for the same value as float32')
    print('float32 hits: %s' % (' '.join('0x%08X' % h for h in f32) or 'none'))
    print('unpark :', unpark(d))


def stage_diff(d):
    desc, vec, first, cap, n = find_descriptor(d)
    if desc is None:
        return
    lo = desc - 0x100
    nw = 0x300 // 4
    snaps = []
    for k in range(3):
        print('fill %d: %s' % (k + 1, sanctioned_fill(d)))
        snaps.append(words(d, lo, nw))
    print('\n=== words in descriptor -0x100 .. +0x200 across three identical fills ===')
    print('%-10s %-10s %-10s %-10s  %s' % ('offset', 'fill1', 'fill2', 'fill3', 'reading'))
    for i in range(nw):
        a, b, c = snaps[0][i], snaps[1][i], snaps[2][i]
        if a == b == c:
            continue
        off = lo + i * 4 - desc
        note = ''
        if b is not None and a is not None and c is not None:
            d1, d2 = (b - a) & 0xFFFFFFFF, (c - b) & 0xFFFFFFFF
            if d1 == d2 and d1 != 0:
                note = 'STEPS BY %d EVERY FILL' % d1
            else:
                note = 'varies'
        print('desc%+#07x %-10s %-10s %-10s  %s'
              % (off,
                 '%08X' % a if a is not None else '--',
                 '%08X' % b if b is not None else '--',
                 '%08X' % c if c is not None else '--', note))


def grab(tag):
    """A front-panel capture over HTTP. Touches no Lua state, so it cannot perturb the test."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
    import screenshot                                                    # noqa: E402
    path = '/tmp/tracecopy_%s.png' % tag
    screenshot.capture(path)
    print('grab   : %s' % path)
    return path


RAMPS = {
    # (first dB, last dB) -- two shapes nobody could confuse on the glass.
    'up': (-120.0, -20.0),
    'down': (-20.0, -120.0),
}


def shaped_fill(d, expr, shape, pts=NPTS):
    """A sanctioned clear-and-append of a straight dB ramp across the plotted span."""
    lo, hi = RAMPS[shape]
    return ask(d, "do local b = %s local wr = buffer.write.reading local i "
                  "b.clear() for i = 1, %d do "
                  "wr(b, %f + (%f - %f) * (i - 1) / %d, fftsa.sg_flo_hz + "
                  "(fftsa.sg_fhi_hz - fftsa.sg_flo_hz) * (i - 1) / %d, i, 0) end "
                  "print('F|'..tostring(b.n)) end"
               % (expr, pts, lo, hi, lo, pts - 1, pts - 1), 'F|', timeout=120)


def readback(d, expr):
    return ask(d, "do local b = %s print('V|'..tostring(b.n)..'|'"
                  "..tostring(b.readings[1])..'|'..tostring(b.readings[128])..'|'"
                  "..tostring(b.readings[255])) end" % expr, 'V|')


def stage_copy(d, arm, last_append=False):
    """The operator's two-buffer test. A is graphed and never cleared or appended; B is
    filled the ordinary way and its element payload is copied over A's.

    A's descriptor is never touched, so n stays 255 and both iterators stay valid -- which
    is the one thing the 2026-11-04 in-place test could not say, having rewound all twelve
    cursor fields to fake the count.
    """
    print('park   :', park(d))
    # A: the graphed buffer. Filled through the sanctioned path first, which is both the
    # control and what gives the display task 255 points after it subscribed -- the thing
    # the 2026-11-04 test could not say it had done.
    print('A up   :', shaped_fill(d, 'fftsa.sg_buf', 'up'))
    print('A read :', readback(d, 'fftsa.sg_buf'))
    grab('1_control_up')
    print('A:')
    adesc, avec, achunk, acap, an, aes = find_by_geometry(d, 'fftsa.sg_buf')
    if achunk is None:
        raise SystemExit('A: no candidate held both owner self-pointers')

    # B's capacity is deliberately NOT A's: the needle is capacity||n, so an identical
    # capacity would match both buffers and the disambiguation would be guesswork.
    npts = NPTS
    ask(d, "do if ZB ~= nil then pcall(function() buffer.delete(ZB) end) end "
           "ZB = buffer.make(%d, buffer.STYLE_WRITABLE_FULL) "
           "buffer.unit(buffer.UNIT_CUSTOM1, 'dB') "
           "buffer.write.format(ZB, buffer.UNIT_CUSTOM1, buffer.DIGITS_4_5, "
           "buffer.UNIT_HERTZ, buffer.DIGITS_6_5) print('MK|'..tostring(ZB.capacity)) end"
        % (acap + 13), 'MK|', timeout=60)
    print('B down :', shaped_fill(d, 'ZB', 'down', npts))
    print('B:')
    bdesc, bvec, bchunk, bcap, bn, bes = find_by_geometry(d, 'ZB')
    if bchunk is None:
        raise SystemExit('B: no candidate held both owner self-pointers')
    print('\nA elements 0x%08X   B elements 0x%08X   %d points fit one chunk of %d'
          % (achunk, bchunk, npts, 32768 // (aes or 32)))

    nbytes = npts * 32
    if not arm:
        print('\nnot armed: would copy %d bytes 0x%08X -> 0x%08X. Re-run with --arm.'
              % (nbytes, bchunk, achunk))
        return
    # Values only. Element layout is reading at +00 (double), timestamp at +08/+12, status
    # and unit and digits at +16, extra value at +20 (double, 4-aligned), and a word at +28
    # that varies per element. A's status word is 8A910000 against B's 8A890000 even with
    # identical format calls, and that word is what labels the axis -- so the merge takes
    # the two value fields from B and leaves everything else of A's in place.
    r = ask(d, "do local sb = KG.read(%d, %d) local sa = KG.read(%d, %d) "
               "if sb == nil or sa == nil then print('C|read|nil') return end "
               "local t = {} local i "
               "for i = 0, %d do local o = i * 32 "
               "t[i+1] = string.sub(sb, o+1, o+8)..string.sub(sa, o+9, o+20)"
               "..string.sub(sb, o+21, o+28)..string.sub(sa, o+29, o+32) end "
               "local out = table.concat(t) "
               "KG.armed = false local ow = KG.own(%d, %d) KG.armed = true "
               "local w = KG.write(%d, out) KG.armed = false "
               "print('C|'..tostring(ow)..'|'..tostring(w)..'|'..tostring(string.len(out))) end"
            % (bchunk, nbytes, achunk, nbytes, npts - 1, achunk, nbytes, achunk),
            'C|', timeout=120)
    print('copy   : own|write|len = %s' % r[2:])
    print('A read :', readback(d, 'fftsa.sg_buf'))

    # A paint has to have had the chance to happen, or an unchanged grab proves nothing.
    ask(d, "do delay(0.5) print('DL|idle') end", 'DL|', timeout=60)
    grab('2_after_copy')

    if last_append:
        # A was never cleared, so n is already 255 and this lands in element 256 rather than
        # overwriting 255. That does not weaken the test: the question is whether ANY
        # sanctioned append makes the task re-read the buffer, not which slot it writes.
        print('append :', ask(d, "do local b = fftsa.sg_buf "
                                 "buffer.write.reading(b, -120, fftsa.sg_fhi_hz, 256, 0) "
                                 "delay(0.5) print('A1|'..tostring(b.n)) end", 'A1|'))
        print('A read :', readback(d, 'fftsa.sg_buf'))
        grab('3_after_append')
    ask(d, "do pcall(function() buffer.delete(ZB) end) ZB = nil print('ZD|done') end", 'ZD|')
    print('unpark :', unpark(d))
    print('\nIf the second grab shows the DOWN ramp, the display task re-reads the buffer and'
          '\nin-place updates are the whole fix. If it still shows the UP ramp, the task holds'
          '\nits own copy and only the append path feeds it.')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stage', required=True,
                    choices=('find', 'needle', 'diff', 'copy', 'copy1'))
    ap.add_argument('--arm', action='store_true',
                    help='permit the guarded write into the graphed buffer chunk')
    a = ap.parse_args()
    g = Guard(IMAGE)
    global HEAP
    HEAP = g.named['.heap']
    print('heap   : 0x%08X..0x%08X (from the section table)' % HEAP)
    d = DMM(recover=False, timeout=180)
    try:
        install_guard(g, d)
        if not helpers(d):
            raise SystemExit('helpers did not install')
        if a.stage == 'copy':
            stage_copy(d, a.arm)
        elif a.stage == 'copy1':
            stage_copy(d, a.arm, last_append=True)
        else:
            {'find': stage_find, 'needle': stage_needle, 'diff': stage_diff}[a.stage](d)
    finally:
        d.close()


if __name__ == '__main__':
    main()
