#!/usr/bin/env python3
"""Find the display task's trace ring from the app's own appends, then ask whether writing it draws.

This is the bypass the graph investigation exists for. Every other route is closed, each
measured: no bulk write is registered, display.setvalue refuses a graph with event 1717, the
buffer-side staging ring's pending count cannot be pre-loaded because the push SETS it, and an
in-place buffer write draws nothing because the display task works from its own copy. That copy
is a ring of records, and nothing has ever written it.

Three phases, deliberately separated, each answering one thing.

READ ONLY, the default. Appends four sentinel readings through the sanctioned path, then calls
fftsa.nl.find_ring_records and find_ring_header on the instrument and prints what they found.
Nothing is written. It answers: can the ring be found at all, is the stride what a 6500 showed,
and is the header identified uniquely.

    python3 -u -I tools/probe_ringfind.py

THE WRITE EXPERIMENT, --write. Saves a run of records, writes an unmistakable dB into them,
fires one append to provoke a repaint, and compares a checksum of the plot interior. It answers
the one question the whole design rests on: does the widget draw from these records, or does it
redraw from something else and leave them as a cache nobody reads.

    python3 -u -I tools/probe_ringfind.py --write
    python3 -u -I tools/probe_ringfind.py --write --nrec 64 --db -20

Only the two float32 fields of a record are touched: no pointer, no cursor, no count, so the
worst case is a wrong value drawn rather than a freed-widget fault.

THE WHOLE PASS, --pass. The per-frame path, prototyped here rather than in the app. It writes
every record of one pass from the app's own trace shifted in dB, sets the count and both
cursors so the geometry is the same every pass, fires one append, times the write on the
instrument's clock and compares the plot. One run then answers all three questions the app
cannot be written without: do the records draw, is the cursor convention right, and what does a
pass cost -- which is what decides whether the Lua form is worth shipping or whether the write
has to be native.

    python3 -u -I tools/probe_ringfind.py --pass
    python3 -u -I tools/probe_ringfind.py --pass --shift 20 --hold 8

Everything written is restored first in the finally block, before anything else that can fail
-- the 2350 lesson -- and the header goes back before the records, because an inconsistent
cursor is the part that cannot be left behind.

THE PIXEL TRIPLES, --pixel. The experiment that matters, the float-value route being closed. A
record's first 0x20 bytes are two int32 TRIPLES, and the hypothesis is that they are the pixel
coordinates the widget draws its polyline from.

Which triple is which is identified FROM THE DATA and not from the axis arithmetic: the
sentinels step 1024, 2048, 4096, 8192 Hz, so the x pixel's successive differences come out in
the ratio 1:2:4 while the y pixel's are equal, the dB step being constant. Then one record's y
triple is moved off the trace and the glass is grabbed.

    python3 -u -I tools/probe_ringfind.py --pixel
    python3 -u -I tools/probe_ringfind.py --pixel --dy 60

One point 40 px clear of the curve is unmistakable and no append can produce it. Nothing but
the three words of one triple is written: no pointer, no cursor, no count.

PARKING. A socket session does NOT stop the app's frame timer. Measured 2026-11-09: sg_stamp
advanced 82,110 counts with a probe connected, so every sentinel appended here is overwritten
within about 100 ms, long before a sweep reaches it. Two runs of this probe were invalidated
that way and reported a desync that looked like a refusal.

Parking FROM the socket DOES work, which an earlier note denied -- 4.2 s and 6 refusals of
persistent retrying, then sg_stamp froze. This parks on the way in, CONFIRMS it by reading
sg_stamp twice rather than by the assignment's own reply, and unparks in the finally: a probe
that dies mid-run otherwise leaves the trace frozen on the glass until something unparks it.

THE FLOAT-VALUE QUESTION IS ANSWERED AND IT IS NO. Writing the float value of a record inside
the drawn window changes nothing on the glass: writes read back present, repaint confirmed by
the triggering append's own point appearing, values absent, twice. See docs/PERFORMANCE.md.
"""
import os
import struct
import sys
import time

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
sys.path.insert(0, os.path.join(SIB, 'notes', 'firmware'))
from dmmrun import DMM                                                   # noqa: E402
from fwguard import Guard                                                # noqa: E402

IMAGE = '/tmp/fw1717a/flash17.bin'
PLOT = (100, 60, 780, 340)

# A FRESH SET EVERY RUN, and exactly representable in float32 so the needle is the bit
# pattern the firmware stored rather than a rounding of it.
#
# A fixed set does not work twice. Each run leaves four records in every ring it reached and
# nothing clears them while frames are parked, so the next run's needle matched the last run's
# leftovers as well: needle hits went 370 then 1243, record candidates 5 then 10, and the
# search 41 s then 46 s -- and the header search over ten candidates is one TSP statement,
# which cannot be interrupted.
#
# The offset is k/64 of a decibel, which is a dyadic rational and so exact in float32, and 64
# runs apart before a value repeats. The frequencies stay 1024, 2048, 4096, 8192: their 1:2:4
# spacing is what identifies the x pixel in classify().
_RUN = int(time.time() // 7) % 64
SENTINELS = [(-100.0 - i + _RUN / 64.0, 1024.0 * (2 ** i)) for i in range(4)]


def opt(flag, default, cast=int):
    return cast(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else default


DO_WRITE = '--write' in sys.argv
DO_PASS = '--pass' in sys.argv
DO_PIXEL = '--pixel' in sys.argv
# A whole pass of pixels, timed. Needs everything --pixel establishes, so it runs the same
# analysis and then writes every drawn record instead of one.
DO_PASSPIX = '--pixelpass' in sys.argv
# The same pass, written as ONE memwrite of the whole block instead of one a record. That is
# the shape a frame would use, and the 510 small calls are what it is measured against.
DO_BULK = '--pixelbulk' in sys.argv
# --pass writes a widget's cursors, which is the one step here that is not just a value.
# Requiring the word is not ceremony: the nearest thing to it, leaving a SUBSCRIPTION ring's
# cursors advanced, ended in a modal 2350 that only a power cycle cleared.
SAY_YES = '--yes' in sys.argv
NREC = opt('--nrec', 32)
WDB = opt('--db', -20.0, float)
SHIFT = opt('--shift', 20.0, float)
HOLD = opt('--hold', 0.0, float)
# How far to move the point. Big enough that nothing on the trace can be mistaken for it, and
# inside the plot either way so the widget has no reason to clip rather than draw.
DY = opt('--dy', 40)
# How long to block the Lua thread after the sentinels, which is the only way the display task
# gets to run. Generous: the cost is paid once and the alternative is a 41 s sweep for records
# that are not there yet.
DRAIN = opt('--drain', 1.5, float)
# How many record candidates to look for a header near. The trace ring is one of them and the
# rest are staging rings and lookalikes; a run that produces a dozen has stale sentinels in it,
# which the per-run dB offset above is there to prevent.
HDR_MAX = opt('--hdrmax', 6)
# Records to write in the whole-pass prototype. The drawn window is one capacity of the trace
# buffer, 510 with the fold on.
PASSN = opt('--passn', 510)
# How many times a REFUSED statement may be sent again. Generous, because a refusal means the
# statement never ran: with frames at 9.5 fps and ~80 ms of work each, landing one between
# frames takes several tries. Still bounded, so a permanent refusal ends in a message rather
# than a loop.
RESEND_MAX = opt('--resends', 200)

# A ring already measured this boot, re-confirmed rather than re-found.
#
# The search is 41 s and the header walk is minutes when the candidate list is long, and the
# answer has been bit-identical on every run of this boot. So --ring takes the geometry as six
# numbers and CONFIRMS it: the four sentinel records must hold the four sentinel decibels as
# float32 pairs at that stride. That is the same discipline the descriptor cache uses -- a
# cached address is re-validated against content, never trusted -- and it is what makes the
# experiment cheap enough to iterate on.
#
#   --ring val0,stride,ov,ox,lo,hi,hdr      all hex, no 0x
#
# hdr is in the list because ring_header() answers nil without it, and the caller then indexes
# nil -- which prints an error the probe reads as "no reply" and waits the whole timeout for.
RING = None
if '--ring' in sys.argv:
    RING = [int(x, 16) for x in sys.argv[sys.argv.index('--ring') + 1].split(',')]
    if len(RING) != 7:
        raise SystemExit('--ring wants val0,stride,ov,ox,lo,hi,hdr in hex')

PARK = ("do if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame "
        "fftsa.frame = function() end end print('PK|' .. tostring(fftsa.saved_frame ~= nil)) end")
UNPARK = ("do if fftsa.saved_frame ~= nil then fftsa.frame = fftsa.saved_frame "
          "fftsa.saved_frame = nil end print('UP|' .. tostring(fftsa.saved_frame == nil)) end")


def ask(d, cmd, tag, timeout=600):
    """Send ONCE, then wait for a reply whose first field is tag.

    RE-SENDING IS THE BUG THIS REPLACES. The old form re-sent the statement up to fourteen
    times, 1.3 s apart, whenever a reply had not arrived yet -- so a statement that merely
    took longer than one timeout was queued fourteen times over, and each copy re-ran the
    memory sweep behind it. One run left the instrument a quarter of an hour of backlog to
    work through: its replies arrived one per connection long after the probe had gone, the
    control socket answered nothing in between, and the HTTP grab timed out too, which reads
    exactly like a wedged instrument. It was not wedged. It was busy doing the same work
    fourteen times because this function asked it to.

    A statement is sent once. If it is slow, that is what the timeout is for. The queue is
    drained first so a stale reply from an earlier statement cannot be read as this one's.
    """
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    d.drain()
    d.send(cmd)
    t_end = time.time() + timeout
    last = None
    resends = 0
    while True:
        left = t_end - time.time()
        if left <= 0:
            break
        t_read = time.time()
        r = d.line(min(20.0, left))
        if r is None:
            # None is "nothing arrived". It does NOT say whether the read waited: a socket
            # whose peer has gone returns immediately, and so does a stub, and this loop then
            # spins at full tilt for the whole deadline. Pace it when the read came back
            # faster than a read that actually waited could have.
            if time.time() - t_read < 0.05:
                time.sleep(0.25)
            continue
        last = str(r)
        if last.startswith(tag):
            return last
        # A REFUSAL IS NOT A SLOW REPLY, AND THE TWO NEED OPPOSITE HANDLING.
        #
        #   "a command from another interface is running"  -> it never ran. Re-send.
        #   silence                                        -> it IS running. Never re-send.
        #
        # The other interface is usually the app's own frame timer: at 9.5 fps and ~80 ms of
        # work a frame, three statements in four arrive while a frame holds the interpreter.
        # That is why park() retries and why this does too -- a refused statement costs
        # nothing to send again.
        #
        # AND NOT WITH ABORT. ABORT aborts the running script, which here is a frame, and a
        # frame cut in half leaves sg_stamp behind the ring: event 4924, a modal dialog over
        # the app, and a socket that then refuses everything. One version of this function
        # sent ABORT on every refusal and did exactly that.
        if 'another interface' in last:
            resends += 1
            if resends <= RESEND_MAX:
                d.drain()
                d.send(cmd)
                continue
            break
    raise SystemExit('DESYNC(%s) after %ds, last=%r -- sent once%s. A refusal means the app '
                     'is holding the interpreter: park the frames first.'
                     % (tag, timeout, last,
                        ', re-sent %d times after refusals' % resends if resends else ''))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def luachars(b):
    """Bytes as a string.char(...) call, so nothing binary crosses the wire."""
    return 'string.char(' + ','.join(str(x) for x in b) + ')'


def f32(v):
    return struct.pack('>f', v)


def require_app(d):
    """The app has to be live AND new enough to carry the finder, or this measures nothing."""
    for _ in range(20):
        r = d.q(one("print('A|' .. tostring(fftsa ~= nil and fftsa.nl ~= nil",
                    "and type(fftsa.nl.find_ring_records) == 'function')",
                    ".. '|' .. tostring(fftsa ~= nil and fftsa.sg_buf ~= nil))"), timeout=30)
        if r is not None and str(r).startswith('A|true|true'):
            return True
        if r is not None and str(r).startswith('A|false'):
            raise SystemExit('this build has no fftsa.nl.find_ring_records -- needs 8.53 or later')
        time.sleep(1.5)
    raise SystemExit('the app is not answering; is it running on the spectrum screen?')


def sumplot(d):
    x1, y1, x2, y2 = PLOT
    return ask(d, "print('C|' .. tostring(ki.display.getchecksum(%d,%d,%d,%d)))"
               % (x1, y1, x2, y2), 'C|', timeout=60)[2:].strip()


def shot(d, path):
    """A picture, because a checksum cannot separate my write from the append that provoked
    the repaint. Run out of process so a failure to grab is not a failure of the run."""
    import subprocess
    rc = subprocess.call([sys.executable, '-I',
                          os.path.join(SIB, 'tools', 'screenshot.py'), path])
    print('grab   : %s%s' % (path, '' if rc == 0 else '  (FAILED rc=%d)' % rc))
    return rc == 0


def append_sentinels(d):
    """Through buffer.write.reading, which is the only call the display task reads.

    AND THEN LET THE DISPLAY TASK RUN. An append pushes a record into the buffer-side staging
    ring and posts a message; the display task drains that into its own ring, and it only gets
    cycles while the Lua thread is blocked. Without the delay the first run of this phase found
    the 28-byte staging ring and the .bss lookalike and NOT the trace ring -- the sentinels
    were sitting undrained, so the records the sweep was looking for did not exist yet.
    """
    for i, (db, hz) in enumerate(SENTINELS):
        ask(d, one("do local b = fftsa.sg_buf",
                   "fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
                   # %.17g, NOT %.1f. The sentinel dB is a 64th of a decibel off a round
                   # number so that each run's set is its own, and %.1f would round that away
                   # -- the needle built on the instrument would then be the bit pattern of a
                   # value nobody appended, and nothing would be found.
                   "buffer.write.reading(b, %.17g, %.17g, fftsa.sg_stamp, 0)" % (db, hz),
                   "print('W|%d') end" % (i + 1)), 'W|%d' % (i + 1), timeout=120)
    ask(d, "do delay(%.2f) print('DR|1') end" % DRAIN, 'DR|1', timeout=120)


def stamp(d):
    # SP| and not T|: the whole-pass phase already prints T| with two fields, and ask()
    # matches on the prefix alone, so one tag for two shapes is a wrong unpack a long way
    # from the cause. The stub harness fails the build on a collision.
    return int(ask(d, "print('SP|' .. tostring(fftsa.sg_stamp or -1))", 'SP|',
                   timeout=60)[3:])


def park(d, tries=30):
    """Stop the frame loop, and prove it stopped.

    The assignment's own reply is not the proof: it says the field was set, and four earlier
    attempts reported exactly that while frames kept running. What proves it is sg_stamp
    sitting still across two reads, because the frame body is the only thing that moves it.
    """
    for k in range(tries):
        r = d.q(PARK, timeout=60)
        if r is not None and str(r).startswith('PK|true'):
            a = stamp(d)
            b = stamp(d)
            if a == b:
                print('park   : frames stopped after %d attempt%s, sg_stamp %d twice'
                      % (k + 1, '' if k == 0 else 's', a))
                return True
            print('park   : set but sg_stamp still moving (%d -> %d), retrying' % (a, b))
        time.sleep(0.7)
    raise SystemExit('could not park the frame loop; everything below would be overwritten')


def unpark(d):
    r = d.q(UNPARK, timeout=60)
    print('unpark : %s' % r)


def readrec(d, a, n):
    """n bytes at a, as bytes, through the plain read -- no guard needed to look."""
    r = ask(d, one("do local s = ki.memread('%X', '%X')" % (a, n),
                   "if s == nil then print('D|nil') return end",
                   "local o, i = '', nil",
                   "for i = 1, string.len(s) do",
                   "o = o .. string.format('%02X', string.byte(s, i)) end",
                   "print('D|' .. o) end"), 'D|', timeout=120)
    if r[2:].strip() == 'nil':
        return None
    return bytes.fromhex(r[2:].strip())


def triples(rec):
    """Offsets in a record where three consecutive words are equal.

    A triple is the only repeating shape in the 56 bytes -- the value and the x are PAIRS --
    so this identifies the two integer fields without being told where they are. Returns a
    list of (offset, value).
    """
    out = []
    w = [struct.unpack('>I', rec[i:i + 4])[0] for i in range(0, len(rec) - 3, 4)]
    i = 0
    while i + 2 < len(w):
        if w[i] == w[i + 1] and w[i + 1] == w[i + 2] and w[i] != 0:
            out.append((i * 4, w[i]))
            i += 3
        else:
            i += 1
    return out


def classify(d, ring):
    """Which triple is the x pixel and which the y, from the sentinels' own spacing.

    The sentinels step 1024, 2048, 4096, 8192 Hz against a constant 1 dB, so across the four
    records the x pixel's successive differences are in the ratio 1:2:4 and the y pixel's are
    equal. That is a property of what was appended, not of the axis arithmetic, so it holds
    whatever the span is set to and on a model whose plot rectangle has never been measured.

    Returns (off_x, off_y, rows) or (None, None, rows).
    """
    base = ring['val0'] - ring['ov']
    rows = []
    for k in range(len(SENTINELS)):
        rec = readrec(d, base + k * ring['stride'], ring['stride'])
        if rec is None:
            return None, None, rows
        rows.append((base + k * ring['stride'], rec, triples(rec)))
    offs = [o for o, _ in rows[0][2]]
    if len(offs) != 2:
        return None, None, rows
    series = {}
    for o in offs:
        vals = []
        for _, rec, ts in rows:
            got = [v for oo, v in ts if oo == o]
            if not got:
                return None, None, rows
            vals.append(got[0])
        series[o] = vals
    # Equal differences is the dB axis; doubling differences is the frequency axis. Judged on
    # the ratio of the last gap to the first, which is 4 for x and 1 for y, with a wide band
    # because a pixel is an integer and a 1 dB step is only about 2 of them.
    verdict = {}
    for o, vals in series.items():
        dif = [vals[i + 1] - vals[i] for i in range(len(vals) - 1)]
        if dif[0] == 0:
            verdict[o] = ('flat', dif)
            continue
        verdict[o] = ('x' if abs(dif[-1]) >= 2.5 * abs(dif[0]) else 'y', dif)
    xs = [o for o, (k, _) in verdict.items() if k == 'x']
    ys = [o for o, (k, _) in verdict.items() if k == 'y']
    print('triples: %s'
          % '  '.join('+0x%02X %s diffs %s' % (o, verdict[o][0], verdict[o][1]) for o in offs))
    for o in offs:
        print('         +0x%02X across the four sentinels: %s' % (o, series[o]))
    if len(xs) == 1 and len(ys) == 1:
        return xs[0], ys[0], rows
    return None, None, rows



# The per-frame path, as it would run on the instrument: compute a pixel, write a triple, and
# do it for every drawn record. Installed as one statement and called by another, so the timed
# call carries no argument marshalling.
#
# The sawtooth is deliberate. A flat shift would also prove "something changed", but not that
# the RIGHT thing changed in the RIGHT place -- a repeating ramp across the band is wrong in a
# way no append could produce and shows immediately whether the x order survived.
ZP_INSTALL = (
    "do function ZP(b,s,n,oy,ay,by,d0,dk) "
    "local mw,c,fl,md,sf = ki.memwrite,string.char,math.floor,math.mod,string.format "
    "local i local t0 = os.clock() "
    "for i = 0, n - 1 do local db = d0 + dk * md(i, 37) "
    "local y = fl(by + ay * db + 0.5) if y < 0 then y = 0 end if y > 479 then y = 479 end "
    "local w = c(md(fl(y/16777216),256),md(fl(y/65536),256),md(fl(y/256),256),md(y,256)) "
    # SINGLE %, not %%: this string is never handed to Python's % operator, so a doubled
    # one would reach Lua literally and string.format would be asked for a "%X" of nothing.
    "mw(sf('%X', b + i*s + oy), w..w..w) end "
    "local t1 = os.clock() print('ZT|' .. sf('%.3f', (t1-t0)*1000)) end print('ZI|ok') end")


def pixel_pass(d, ring, plan):
    """One whole pass written as pixels, timed on the instrument's own clock.

    The two maps are solved from the SENTINEL RECORDS, not from the app's plot rectangle: four
    records whose decibels and frequencies are known, and whose pixels the firmware computed,
    give both affine maps directly. A map derived that way is right on a model whose plot
    geometry has never been measured, which is the whole reason the pixel route is worth
    having.
    """
    rows = plan['rows']
    off_x, off_y = plan['off_x'], plan['off_y']
    pts = []
    for k, (addr, rec, ts) in enumerate(rows):
        got = dict(ts)
        pts.append((SENTINELS[k][0], SENTINELS[k][1], got[off_x], got[off_y]))
    (db1, hz1, x1, y1), (db4, hz4, x4, y4) = pts[0], pts[-1]
    if db4 == db1 or hz4 == hz1:
        print('pass   : the sentinels do not span either axis; nothing to solve.')
        return
    ay = (y4 - y1) / float(db4 - db1)
    by = y1 - ay * db1
    ax = (x4 - x1) / float(hz4 - hz1)
    bx = x1 - ax * hz1
    print('maps   : y = %.4f*db %+.3f   x = %.6f*hz %+.3f' % (ay, by, ax, bx))
    # CHECKED, not assumed: the two sentinels the fit did not use have to come back within a
    # pixel, or the field is not an affine function of what was appended and the rest is void.
    worst = 0.0
    for db, hz, xp, yp in pts[1:-1]:
        worst = max(worst, abs(ay * db + by - yp), abs(ax * hz + bx - xp))
    print('       : the two sentinels not fitted predict within %.2f px' % worst)
    if worst > 1.5:
        print('pass   : %.2f px is not an affine fit. Refusing to write a whole pass.' % worst)
        return

    oldest, count = plan['oldest'], plan['count']
    n = min(count, PASSN)
    base, s = oldest, ring['stride']
    span = n * s
    if base < ring['lo'] or base + span > ring['hi']:
        print('pass   : %d records from 0x%08X leaves the ring. Refusing.' % (n, base))
        return
    print('pass   : %d of %d drawn records from 0x%08X, %d bytes' % (n, count, base, span))

    # Saved ON THE INSTRUMENT, as a Lua string: 28 KB of hex across the socket would take
    # longer than the whole experiment, and the restore has to be one statement.
    ask(d, "print('O|' .. tostring(KG.own(%d,%d)))" % (base, span), 'O|')
    ask(d, one("do ZS = ki.memread('%X', '%X')" % (base, span),
               "print('S2|' .. tostring(ZS ~= nil and string.len(ZS) or 0)) end"), 'S2|')
    print('saved  : %d bytes held on the instrument' % span)

    before = sumplot(d)
    shot(d, '/tmp/pass_before.png')
    ask(d, ZP_INSTALL, 'ZI|')
    # The decibel sawtooth spans most of the window, so every column moves and the shape is
    # unmistakable at a glance.
    d0, dk = -110.0, 2.5
    t = ask(d, "print('ZC|' .. tostring(ZP(%d,%d,%d,%d,%.9g,%.9g,%.9g,%.9g) or 'done'))"
            % (base, s, n, off_y, ay, by, d0, dk), 'ZT|', timeout=300)
    print('timing : %s ms on the instrument clock for %d records (%.1f us each)'
          % (t[3:], n, float(t[3:]) * 1000.0 / n))
    ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
               "buffer.write.reading(fftsa.sg_buf, -105.0, 32768.0, fftsa.sg_stamp, 0)",
               "delay(0.5) print('P4|1') end"), 'P4|1', timeout=120)
    after = sumplot(d)
    shot(d, '/tmp/pass_after.png')
    print('plot   : before %s  after %s  -> %s'
          % (before, after, 'CHANGED' if after != before else 'same'))
    ask(d, "print('Z3|' .. tostring(KG.write(%d, ZS)))" % base, 'Z3|', timeout=120)
    print('restore: %d bytes put back from the instrument-side copy' % span)
    print()
    print('Compare /tmp/pass_before.png with /tmp/pass_after.png. A repeating ramp across')
    print('the band means a whole pass can be drawn by writing pixels, and the figure above')
    print('is what it costs against 39 ms of appends.')


# ONE memwrite for the whole drawn window, which is the form a frame would use.
#
# 510 separate 12-byte writes measured 19.3 ms, and most of that is per-call overhead: a
# string.format of the address and four string.char calls a record. Both go away if the block
# is assembled once and written once:
#
#   ZY[y]  the twelve bytes of a y triple, for every y a 480-pixel panel has. Built once.
#   ZT     the block as three pieces a record -- everything below the y triple, the y triple,
#          everything above it -- sliced out of the records THE APP ITSELF WROTE, so the x
#          pixels, the value, the x float and the 2.0f are its own and stay correct.
#
# A frame then stores 510 table entries, concatenates once and writes once. No string is built
# per record and nothing is formatted.
BULK_YS = (
    "do ZY = {} local c, fl, md = string.char, math.floor, math.mod local y "
    "for y = 0, 479 do local w = c(0, 0, md(fl(y/256), 256), md(y, 256)) ZY[y] = w..w..w end "
    "print('ZY|' .. tostring(table.getn(ZY) + 1)) end")


def pixel_bulk(d, ring, plan):
    rows, off_y = plan['rows'], plan['off_y']
    pts = [(SENTINELS[k][0], dict(ts)[off_y]) for k, (a, rec, ts) in enumerate(rows)]
    (db1, y1), (dbn, yn) = pts[0], pts[-1]
    if dbn == db1:
        print('bulk   : the sentinels do not span the decibel axis.')
        return
    ay = (yn - y1) / float(dbn - db1)
    by = y1 - ay * db1
    print('bulk   : y = %.4f*db %+.3f' % (ay, by))

    oldest, count = plan['oldest'], plan['count']
    n = min(count, PASSN)
    base, s = oldest, ring['stride']
    span = n * s
    if base < ring['lo'] or base + span > ring['hi']:
        print('bulk   : %d records from 0x%08X leaves the ring. Refusing.' % (n, base))
        return

    ask(d, "print('O|' .. tostring(KG.own(%d,%d)))" % (base, span), 'O|')
    ask(d, one("do ZS = ki.memread('%X', '%X')" % (base, span),
               "print('S2|' .. tostring(ZS ~= nil and string.len(ZS) or 0)) end"), 'S2|')
    print('saved  : %d bytes held on the instrument' % span)

    t = ask(d, BULK_YS, 'ZY|', timeout=120)
    print('table  : %s y-triple strings built once' % t[3:])
    r = ask(d, one("do ZB = ki.memread('%X', '%X')" % (base, span),
                   "if ZB == nil then print('ZB|nil') return end",
                   "ZT = {} local sub = string.sub local i",
                   "for i = 1, %d do local o = (i - 1) * %d" % (n, s),
                   "ZT[3*i-2] = sub(ZB, o + 1, o + %d)" % off_y,
                   "ZT[3*i-1] = sub(ZB, o + %d, o + %d)" % (off_y + 1, off_y + 12),
                   "ZT[3*i] = sub(ZB, o + %d, o + %d) end" % (off_y + 13, s),
                   "print('ZB|' .. tostring(string.len(ZB)) .. ','",
                   ".. tostring(table.getn(ZT))) end"), 'ZB|', timeout=180)
    if 'nil' in r:
        print('bulk   : the block could not be read. Nothing written.')
        return
    print('slices : %s bytes in %s pieces' % tuple(r[3:].split(',')))

    before = sumplot(d)
    shot(d, '/tmp/bulk_before.png')
    ask(d, "do KG.armed = true print('M|' .. tostring(KG.armed)) end", 'M|')
    # KG is bypassed for the one bulk write on purpose and the range was owned above: the
    # guard writes a record at a time, which is the cost being measured away.
    t = ask(d, one("do local t0 = os.clock()",
                   "local cc, mw, fl, md = table.concat, ki.memwrite, math.floor, math.mod",
                   "local i local ay, by = %.9g, %.9g" % (ay, by),
                   "for i = 1, %d do local db = -110.0 + 2.5 * md(i - 1, 37)" % n,
                   "local y = fl(ay * db + by + 0.5)",
                   "if y < 0 then y = 0 end if y > 479 then y = 479 end",
                   "ZT[3*i-1] = ZY[y] end",
                   "local img = cc(ZT) mw('%X', img)" % base,
                   "local t1 = os.clock()",
                   "print('ZQ|' .. string.format('%.3f', (t1 - t0) * 1000)",
                   ".. ',' .. tostring(string.len(img))) end"), 'ZQ|', timeout=300)
    ms, nb = t[3:].split(',')
    print('timing : %s ms for %d records in ONE memwrite of %s bytes (%.1f us each)'
          % (ms, n, nb, float(ms) * 1000.0 / n))
    print('         against 19.3 ms for the same pass written a record at a time,')
    print('         and 39 ms for the 510 appends it replaces.')
    ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
               "buffer.write.reading(fftsa.sg_buf, -105.0, 32768.0, fftsa.sg_stamp, 0)",
               "delay(0.5) print('P5|1') end"), 'P5|1', timeout=120)
    after = sumplot(d)
    shot(d, '/tmp/bulk_after.png')
    print('plot   : before %s  after %s  -> %s'
          % (before, after, 'CHANGED' if after != before else 'same'))
    ask(d, "print('Z3|' .. tostring(KG.write(%d, ZS)))" % base, 'Z3|', timeout=120)
    print('restore: %d bytes put back from the instrument-side copy' % span)


def pixel_test(d, ring):
    """Does moving a record's y-pixel triple move the point on the glass?

    Everything in the pixel route rests on this and it is cheap. One record, one triple, three
    words, inside the drawn window, with the record saved first and put back after. No pointer,
    no cursor, no count -- the same risk class as the value write, which was harmless.

    The drawn window comes from the HEADER and not from the write cursor. Sentinel 1 lands AT
    the cursor, so writing forward from it goes into slots the ring has not reached yet, outside
    the drawn set -- which is why the first value-write attempt changed nothing visible and had
    to be repeated.
    """
    off_x, off_y, rows = classify(d, ring)
    if off_y is None:
        print('pixel  : could not tell the two triples apart, so nothing is written.')
        for a, rec, ts in rows:
            print('         0x%08X triples %s'
                  % (a, ['+0x%02X=%d' % (o, v) for o, v in ts]))
        return None
    print('pixel  : x at record +0x%02X, y at record +0x%02X -- derived, not assumed'
          % (off_x, off_y))

    hv = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                    "if v == nil then print('RW|nil,nil,nil') return end",
                    "print('RW|' .. tostring(v.oldest) .. ',' .. tostring(v.count)",
                    ".. ',' .. tostring(v.write)) end"), 'RW|', timeout=120)
    if 'nil' in hv:
        print('window : the ring header could not be read (%s). Nothing is written.' % hv[3:])
        return None
    oldest, count, wcur = (int(x) for x in hv[3:].split(','))
    print('window : oldest 0x%08X  count %d  write 0x%08X' % (oldest, count, wcur))
    if count < 16:
        print('pixel  : only %d records drawn, too few to pick one from. Refusing.' % count)
        return None
    k = count // 2
    rec_at = oldest + k * ring['stride']
    if rec_at < ring['lo'] or rec_at + ring['stride'] > ring['hi']:
        print('pixel  : record %d falls outside the ring, which cannot be right. Refusing.' % k)
        return None
    rec = readrec(d, rec_at, ring['stride'])
    if rec is None:
        print('pixel  : cannot read the target record, so it must not be written.')
        return None
    got = dict(triples(rec))
    if off_x not in got or off_y not in got:
        print('pixel  : the target record does not carry both triples at those offsets '
              '(%s). Refusing.' % ['+0x%02X' % o for o in sorted(got)])
        return None
    x_px, y_px = got[off_x], got[off_y]
    print('target : record %d of %d at 0x%08X, x=%d y=%d' % (k, count, rec_at, x_px, y_px))
    # A pixel pair outside the panel means the offsets are not pixels at all, whatever the
    # differencing said, and the write would be into a field of unknown meaning.
    if not (0 <= x_px <= 800 and 0 <= y_px <= 480):
        print('pixel  : (%d, %d) is not on an 800x480 panel. Refusing.' % (x_px, y_px))
        return None
    newy = y_px - DY
    if newy < 75:
        newy = y_px + DY
    if not (75 <= newy <= 345):
        print('pixel  : %d would land outside the plot, where a clip is indistinguishable '
              'from a refusal to draw. Refusing.' % newy)
        return None
    return dict(rec_at=rec_at, off_x=off_x, off_y=off_y, x_px=x_px, y_px=y_px, newy=newy,
                k=k, count=count, oldest=oldest, rows=rows, bytes=rec)


def whole_pass(d, ring):
    """One pass written the way a frame would write it, timed and then undone.

    This is the prototype for the app's per-frame path, and it is here rather than in the app
    because three things have to be true before that code is worth writing and none of them is
    knowable offline: that the records are what the widget draws, that resetting the count and
    both cursors every pass keeps the geometry fixed, and that the write is cheap enough to be
    worth doing in Lua at all.

    The values come off the app's own trace shifted in dB, so the picture should be the same
    curve lifted bodily. A synthetic shape would also answer "did anything change", but not
    "did the RIGHT thing change", and a shift is the one change that is unmistakable at a
    glance and impossible to produce by accident.
    """
    lo, hi, s, hdr = ring['lo'], ring['hi'], ring['stride'], ring['hdr']
    ov, ox, nrec = ring['ov'], ring['ox'], ring['nrec']
    # One pass is what the app plots, bounded by the ring and leaving the slot the triggering
    # append will take.
    r = ask(d, one("do print('N|' .. tostring(fftsa.sg_ncol) .. ',' .. tostring(fftsa.sg_buf.n)",
                   ".. ',' .. tostring(fftsa.sg_buf.capacity)) end"), 'N|')
    ncol, bn, bcap = (int(x) for x in r[2:].split(','))
    n = min(ncol, nrec - 1, bn)
    if n < 8:
        print('pass   : only %d points available, not enough to judge' % n)
        return
    # A ring this short is not the one the display task draws a spectrum from, and the thing
    # it is most likely to be instead is the buffer-side staging ring -- whose cursors are
    # the ones that must never be left moved. The header test already separates them; this is
    # the second lock on the same door.
    if nrec < 64:
        print('pass   : the ring holds only %d records, which is too few to be the trace '
              'ring. Refusing to write it.' % nrec)
        return
    # Fused or split. On a 6500 the value pair, the flags and the x pair are 20 contiguous
    # bytes, so one write a record does it; anywhere else it is two. Halving the call count
    # matters because the calls are the cost.
    fuse = (ox == ov + 12)
    print('pass   : %d records, %s write a record, span 0x%X..0x%X'
          % (n, 'one fused 20-byte' if fuse else 'two 8-byte', lo, hi))

    # THE CURSOR CONVENTION, DERIVED. The measured header had write = lo + 254*stride with
    # count = 255, so the cursor points at the LAST written record and not one past it -- but
    # that is one observation on one build. Taking the offset between the live cursor and the
    # live count and preserving it means the convention never has to be assumed.
    lv = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                    "print('L|' .. tostring(v.count) .. ',' .. tostring(v.write)) end"), 'L|')
    c0, w0 = (int(x) for x in lv[2:].split(','))
    coff = (w0 - lo) // s - c0
    print('cursor : live count %d, write at record %d, so the cursor sits %+d from the count'
          % (c0, (w0 - lo) // s, coff))

    ask(d, "print('O|' .. tostring(KG.own(%d,%d)))" % (hdr, hi - hdr), 'O|')
    # SAVED ON THE INSTRUMENT, not over the wire: the records are 14 kB and the socket moves
    # 110 kB/s, so a host-side copy would cost a second each way and a restore that slow is a
    # restore that might not happen.
    # The addresses are formatted HERE, not on the instrument: a string.format('%X', ...)
    # inside a Python %-formatted fragment has its escape eaten before Lua sees it, which
    # audit_probe.py exists to catch and did.
    ask(d, one("do ZS = ki.memread('%X', '%X')" % (lo, hi - lo),
               "ZH = {KG.w(%d), KG.w(%d), KG.w(%d), KG.w(%d), KG.w(%d)}"
               % (hdr, hdr + 4, hdr + 8, hdr + 12, hdr + 20),
               "print('S|' .. tostring(string.len(ZS)) .. ',' .. tostring(ZH[5])) end"), 'S|')
    print('saved  : the whole ring and five header words, on the instrument')

    # The writer, defined once so the timing is of the loop and not of the definition.
    if fuse:
        body = ("local fl = string.sub(ki.memread(string.format('%X', lo + ov + 8), '4'), 1, 4) "
                "for i = 1, n do local a = lo + (i - 1) * s "
                "local v = P(b.readings[i] + dsh) local x = P(b.extravalues[i]) "
                "KG.write(a + ov, v .. v .. fl .. x .. x) end")
    else:
        body = ("for i = 1, n do local a = lo + (i - 1) * s "
                "local v = P(b.readings[i] + dsh) local x = P(b.extravalues[i]) "
                "KG.write(a + ov, v .. v) KG.write(a + ox, x .. x) end")
    ask(d, one("do function ZW(lo, s, ov, ox, n, dsh)",
               "local b, P, i = fftsa.sg_buf, fftsa.nl._f32_pack, nil",
               body,
               "end print('F|1') end"), 'F|1')

    before = sumplot(d)
    ask(d, "do KG.armed = true print('M|' .. tostring(KG.armed)) end", 'M|')
    t = ask(d, one("do local c = os.clock local t0 = c()",
                   "ZW(%d, %d, %d, %d, %d, %.1f)" % (lo, s, ov, ox, n, SHIFT),
                   "local t1 = c()",
                   "KG.p32(%d, %d) KG.p32(%d, %d) KG.p32(%d, %d)"
                   % (hdr + 20, n, hdr + 8, lo, hdr + 12, lo + (n + coff) * s),
                   "local t2 = c()",
                   "print(string.format('T|%.2f|%.2f', (t1-t0)*1000, (t2-t1)*1000)) end"),
            'T|', timeout=300)
    wms, hms = (float(x) for x in t[2:].split('|'))
    print('timing : %d records in %.2f ms, header in %.2f ms -- %.1f us a record'
          % (n, wms, hms, wms * 1000.0 / n))

    ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
               "buffer.write.reading(fftsa.sg_buf, -105.0, 32768.0, fftsa.sg_stamp, 0)",
               "delay(0.4) print('P|3') end"), 'P|3', timeout=120)
    after = sumplot(d)
    print('plot   : before %s  after %s  -> %s'
          % (before, after, 'CHANGED' if after != before else 'same'))
    hv = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                    "print('A2|' .. tostring(v.count) .. ',' .. tostring(v.write)",
                    ".. ',' .. tostring(v.oldest)) end"), 'A2|')
    print('header : after the triggering append, count,write,oldest = %s'
          % hv.split('|', 1)[1])
    if after != before:
        print()
        print('THE PER-FRAME PATH WORKS. %.2f ms a pass against about 39 ms for 510 appends.'
              % (wms + hms))
        print('Look at the glass: the curve should be the same shape lifted %.0f dB.' % SHIFT)
    else:
        print()
        print('The plot did not change. Before concluding the records are not what is drawn,')
        print('check that one ordinary append alone changes this checksum at all.')
    if HOLD > 0:
        print('hold   : %.0f s on the glass before the restore' % HOLD)
        ask(d, "do delay(%.1f) print('Y|1') end" % HOLD, 'Y|1', timeout=int(HOLD) + 60)

    # RESTORE: the header first, because an inconsistent cursor is the part that must not be
    # left behind, then the records. Each in its own statement so one failing does not skip
    # the other.
    # Each in its own call and each in its own try, so a failure in one does not skip the
    # rest. The header goes first: an inconsistent cursor is the part that must not be left
    # behind, and a stale record is only a wrong value drawn for one frame.
    for label, stmt, t in (
        ('header', one("do KG.p32(%d, ZH[1]) KG.p32(%d, ZH[2]) KG.p32(%d, ZH[3])"
                       % (hdr, hdr + 4, hdr + 8),
                       "KG.p32(%d, ZH[4]) KG.p32(%d, ZH[5])" % (hdr + 12, hdr + 20),
                       "print('Z2|1') end"), 60),
        ('records', "print('Z3|' .. tostring(KG.write(%d, ZS)))" % lo, 120),
        ('guard', 'do KG.armed = false KG.wb = nil ZS, ZH, ZW = nil, nil, nil end', 60),
    ):
        try:
            d.q(stmt, timeout=t)
        except Exception as e:                                       # noqa: BLE001
            print('restore: %s FAILED -- %s' % (label, e))
            print('         the app rewrites every record on its next frame, so closing this')
            print('         socket and letting frames resume recovers the picture.')
    print('restore: header and all %d bytes of records put back' % (hi - lo))



def confirm_ring(d):
    """A geometry measured earlier this boot, re-CONFIRMED rather than re-found.

    The search is 41 s and the header walk can be minutes; the answer has been bit-identical
    on every run of this boot. So the six numbers are taken as given and then checked against
    content: each of the four sentinel records must hold its own decibel as a float32 pair at
    the stated value offset. Four independent confirmations of a cached address is the same
    discipline the descriptor cache uses, and it is what makes the experiment cheap enough to
    iterate on. A mismatch refuses and says to drop the flag.
    """
    val0, stride, ov, ox, rlo, rhi, hdr = RING
    base = val0 - ov
    for k, (db, hz) in enumerate(SENTINELS):
        rec = readrec(d, base + k * stride, stride)
        if rec is None:
            print('ring   : record %d unreadable; drop --ring and let it search.' % k)
            return None
        want = f32(db) * 2
        if rec[ov:ov + 8] != want:
            print('ring   : record %d holds %s at +0x%X, not %s -- this is not this run\'s '
                  'ring. Drop --ring.' % (k, rec[ov:ov + 8].hex(), ov, want.hex()))
            return None
    ring = dict(val0=val0, stride=stride, dx=ox - ov, hdr=hdr, lo=rlo, hi=rhi,
                nrec=(rhi - rlo) // stride, ov=ov, ox=ox)
    print('ring   : 0x%08X..0x%08X, %d records of %d, value +0x%X, x +0x%X'
          % (rlo, rhi, ring['nrec'], stride, ov, ox))
    print('         confirmed against all four of this run\'s sentinels')
    # ring_header() reads the geometry off RG on the instrument.
    ask(d, one("do RG = {val0 = %d, stride = %d, dx = %d, hdr = %d, lo = %d, hi = %d}"
               % (val0, stride, ox - ov, hdr, rlo, rhi),
               "print('RGK|' .. tostring(fftsa.nl.ring_header(RG) ~= nil)) end"), 'RGK|')
    return ring


def search_ring(d):
    """Find the ring from this run's sentinels, and report every step of it.

    Pulled out of main so the --ring path, which confirms a geometry already measured
    this boot instead of finding it again, is a branch and not an indentation.
    """
    ring = {}
    # COMMAS. A Lua table constructor separates entries with ',' or ';', and joining
    # these with a space built a statement that is not Lua at all -- the instrument
    # printed nothing, every retry, and the probe reported a desync with last=None. The
    # stub harness could not see it either, because it answered by tag without caring
    # whether the statement parsed. It runs luac -p over every statement now.
    sent = ', '.join("{db=%.17g,hz=%.17g}" % (db, hz) for db, hz in SENTINELS)
    t0 = time.time()
    # The records first, reported with how many candidates confirmed: the buffer-side
    # staging ring holds the same two float32 pairs in a 28-byte record and confirms at a
    # stride just as well, so a single candidate and a dozen are different situations.
    r = ask(d, one("do RS = {%s}" % sent,
                   "local g = fftsa.nl.find_ring_records(RS)",
                   "if g == nil then print('R|nil|' .. tostring(fftsa.nl.ring_why)) return end",
                   "local c, o, i = fftsa.nl.ring_cands, '', nil",
                   "for i = 1, table.getn(c) do",
                   "o = o .. ' ' .. string.format('%X', c[i].val0) .. '/' .. c[i].stride end",
                   "print('R|ok|' .. tostring(table.getn(c)) .. ','",
                   ".. tostring(fftsa.nl.ring_hits) .. ',' .. o) end"), 'R|')
    print('find  : %.1f s' % (time.time() - t0))
    if r.startswith('R|nil'):
        print('records: NOT FOUND -- %s' % r[6:])
        print()
        print('The value needle is the sentinel dB packed as float32 twice. Not finding it')
        print('means either the record does not hold two adjacent copies, or the windows')
        print('scan_windows chose do not reach the display task\'s allocation.')
        return
    ncand, hits, lst = r[5:].split(',', 2)
    print('records: %s candidate%s, needle hits %s --%s'
          % (ncand, '' if ncand == '1' else 's', hits, lst))

    # ONE CANDIDATE PER STATEMENT, and the loop on this side.
    #
    # fftsa.nl.find_ring does the whole walk inside a single statement, and a single
    # statement cannot be interrupted from the panel. It also re-runs find_ring_records
    # from scratch first, so calling it after the search above pays for the search twice.
    # With ten candidates that came to minutes under one tag, which is exactly the shape
    # that cost a window: nothing to see, nothing to stop, and no way to tell a slow
    # statement from a dead one.
    h = 'H|nil|no candidate was examined'
    for ci in range(1, min(int(ncand), HDR_MAX) + 1):
        h = ask(d, one("do local c = fftsa.nl.ring_cands[%d]" % ci,
                       "if c == nil then print('H|nil|no candidate %d') return end" % ci,
                       "local g = fftsa.nl.find_ring_header(c)",
                       "if g == nil then print('H|no|' .. string.format('%X', c.val0)",
                       ".. '/' .. tostring(c.stride) .. '|'",
                       ".. tostring(fftsa.nl.ring_why)) return end",
                       "RG = g",
                       "print('H|ok|' .. tostring(g.hdr) .. ',' .. tostring(g.lo)",
                       ".. ',' .. tostring(g.hi) .. ',' .. tostring(g.nrec)",
                       ".. ',' .. tostring(g.ov) .. ',' .. tostring(g.ox)",
                       ".. ',' .. tostring(g.val0) .. ',' .. tostring(g.stride)",
                       ".. ',' .. tostring(g.dx)) end"), 'H|', timeout=240)
        if h.startswith('H|ok'):
            print('header : candidate %d of %s carries one' % (ci, ncand))
            break
        print('       : candidate %d %s' % (ci, h[5:]))
    if h.startswith('H|nil'):
        print('header : NOT FOUND -- %s' % h[6:])
        print()
        print('Record candidates confirmed but none of them is a ring with a findable')
        print('header. The staging ring keeps its bounds at +0x8C and +0x94, which are not')
        print('adjacent, so a candidate with no header is very likely that one.')
    else:
        hdr, lo, hi, nrec, ov, ox, val0, stride, dx = (int(x) for x in h[5:].split(','))
        ring = dict(val0=val0, stride=stride, dx=dx, hdr=hdr, lo=lo, hi=hi, nrec=nrec,
                    ov=ov, ox=ox)
        print('records: val0 0x%08X  stride %d  value->x %+d' % (val0, stride, dx))
        print('header : 0x%08X  ring 0x%08X..0x%08X  %d records  value at +0x%X  x at +0x%X'
              % (hdr, lo, hi, nrec, ov, ox))
        print('        header sits 0x%X below the ring' % (lo - hdr))

        # THE FIELD ORDER BY CAUSE, NOT BY LAYOUT. One append has to raise the count by one
        # and advance the write cursor by exactly one stride. Nothing else in memory does.
        b = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                       "print('B|' .. tostring(v.count) .. ',' .. tostring(v.write)",
                       ".. ',' .. tostring(v.oldest)) end"), 'B|')
        c0, w0, o0 = (int(x) for x in b[2:].split(','))
        ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
                   "buffer.write.reading(fftsa.sg_buf, -104.0, 16384.0, fftsa.sg_stamp, 0)",
                   "print('P|1') end"), 'P|1', timeout=120)
        b = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                       "print('B|' .. tostring(v.count) .. ',' .. tostring(v.write)",
                       ".. ',' .. tostring(v.oldest)) end"), 'B|')
        c1, w1, o1 = (int(x) for x in b[2:].split(','))
        dc, dw = c1 - c0, (w1 - w0) % (hi - lo)
        print('cause  : one append moved count %+d and the write cursor %+d bytes (stride %d)'
              % (dc, dw, ring['stride']))
        if dw == ring['stride']:
            print('        the cursor field is confirmed by cause')
        else:
            print('        THE CURSOR FIELD IS NOT CONFIRMED -- do not write the header')
        if c1 == c0 and c0 == nrec:
            print('        the count is already at the ring size, so it has stopped moving')

    # THE WHOLE RECORD, both of the first two, as bytes and as decoded float32. The
    # question the write experiment cannot settle on its own is what the bytes outside the
    # two fields are for: if +0x00..0x1F holds pixel coordinates the widget computed at
    # append time, then writing the value and the x changes a cache nobody reads back, and
    # the bypass needs those recomputed too. Printing them is what makes that judgeable
    # instead of guessed.
    if 'lo' in ring:
        v0, s, dxv = ring['val0'], ring['stride'], ring['dx']
        base = v0 - ring['ov']
        print()
        print('the first two SENTINEL records in full, of %d in the ring. These are the'
              % ring['nrec'])
        print('ones whose contents are known, which is what makes the other bytes readable.')
        for k in range(2):
            a = base + k * s
            r = ask(d, one("do local s = ki.memread('%X', '%X')" % (a, s),
                           "if s == nil then print('D|nil') return end",
                           "local o, i = '', nil",
                           "for i = 1, string.len(s) do",
                           "o = o .. string.format('%02X', string.byte(s, i)) end",
                           "print('D|' .. o) end"), 'D|', timeout=120)
            if r[2:].strip() == 'nil':
                print('  rec %d  unreadable' % k)
                continue
            b = bytes.fromhex(r[2:].strip())
            print('  rec %d  0x%08X' % (k, a))
            for off in range(0, len(b), 16):
                print('    +0x%02X  %s' % (off, ' '.join('%02X' % x for x in b[off:off + 16])))
            for off in range(0, len(b) - 3, 4):
                f = struct.unpack('>f', b[off:off + 4])[0]
                tag = ''
                if off == ring['ov'] or off == ring['ov'] + 4:
                    tag = '  <- value'
                elif off == ring['ox'] or off == ring['ox'] + 4:
                    tag = '  <- x'
                if tag or (1e-6 < abs(f) < 1e9):
                    print('    +0x%02X  %-16.6g %08X%s'
                          % (off, f, struct.unpack('>I', b[off:off + 4])[0], tag))

    return ring


def main():
    g = Guard(IMAGE)
    d = DMM(recover=False, timeout=600)
    saved = None
    ring = {}
    parked = False
    try:
        d.drain()
        require_app(d)
        st = ask(d, one("do local b = fftsa.sg_buf",
                        "print('S|' .. tostring(b.n) .. ',' .. tostring(b.capacity)",
                        ".. ',' .. tostring(fftsa.sg_ncol) .. ',' .. tostring(fftsa.sg_fold)",
                        ".. ',' .. tostring(fftsa.sg_flo_hz) .. ',' .. tostring(fftsa.sg_fhi_hz)",
                        ".. ',' .. tostring(fftsa.n)) end"), 'S|')
        print('state : %s' % st[2:])
        print('        n,capacity,ncol,fold,flo,fhi,fft')

        # BEFORE the sentinels, not after. A frame refills the whole trace, so a sentinel
        # appended with frames running is gone within about 100 ms -- long before a sweep for
        # it finishes.
        park(d)
        parked = True

        append_sentinels(d)
        print('seed  : four sentinels appended through buffer.write.reading')

        if RING is not None:
            ring = confirm_ring(d)
            if ring is None:
                return
        else:
            ring = search_ring(d)

        if not (DO_WRITE or DO_PASS or DO_PIXEL or DO_PASSPIX or DO_BULK):
            print()
            print('Read only. --pixel answers whether the widget draws from the int triples,')
            print('which is the only route left open. --write re-runs the float-value test,')
            print('whose answer is already no. --pass prototypes the whole per-frame path.')
            return

        # ---- the experiments ---------------------------------------------------------
        if 'lo' not in ring:
            print()
            print('No header, so nothing can be bounded inside the ring. Refusing to write.')
            return
        for i, stmt in enumerate(g.tsp()):
            ask(d, stmt.replace('\n', ' '), 'KG|%d' % (i + 1), timeout=60)
        print('guard  : installed')

        if DO_PIXEL or DO_PASSPIX or DO_BULK:
            print()
            plan = pixel_test(d, ring)
            if plan is None:
                return
        if DO_PASSPIX:
            pixel_pass(d, ring, plan)
            return
        if DO_BULK:
            pixel_bulk(d, ring, plan)
            return
        if DO_PIXEL:
            a = plan['rec_at'] + plan['off_y']
            ask(d, "print('O|' .. tostring(KG.own(%d,%d)))" % (a, 12), 'O|')
            saved = [(a, plan['bytes'][plan['off_y']:plan['off_y'] + 12])]
            before = sumplot(d)
            shot(d, '/tmp/pixel_before.png')
            ask(d, "do KG.armed = true print('M|' .. tostring(KG.armed)) end", 'M|')
            pat = struct.pack('>III', plan['newy'], plan['newy'], plan['newy'])
            r = ask(d, "print('V|' .. tostring(KG.write(%d, %s)))" % (a, luachars(pat)), 'V|')
            if not r.startswith('V|true'):
                raise SystemExit('the guard refused the triple write at 0x%08X: %s' % (a, r))
            back = readrec(d, a, 12)
            print('wrote  : y %d -> %d at 0x%08X, reads back %s'
                  % (plan['y_px'], plan['newy'], a,
                     'present' if back == pat else 'ABSENT (%s)' % (back and back.hex())))
            # One append to provoke the repaint. The display task only runs while Lua is
            # blocked, which is what delay() is for.
            ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
                       "buffer.write.reading(fftsa.sg_buf, -105.0, 32768.0, fftsa.sg_stamp, 0)",
                       "delay(0.5) print('P|3') end"), 'P|3', timeout=120)
            after = sumplot(d)
            shot(d, '/tmp/pixel_after.png')
            print('plot   : before %s  after %s  -> %s'
                  % (before, after, 'CHANGED' if after != before else 'same'))
            print()
            print('Compare /tmp/pixel_before.png with /tmp/pixel_after.png. ONE point %d px'
                  % DY)
            print('off the curve at x=%d means the widget draws from the triples, and the'
                  % plan['x_px'])
            print('whole bypass follows. A checksum change alone is not enough: the')
            print('triggering append draws a point of its own.')
            return

        if DO_PASS:
            if not SAY_YES:
                print()
                print('--pass writes %d records AND the ring header: the count and both'
                      % min(255, ring.get('nrec', 0)))
                print('cursors. Everything is saved on the instrument first and restored in')
                print('the finally, but a widget cursor is not a value -- add --yes to run it.')
                return
            whole_pass(d, ring)
            if not DO_WRITE:
                return

        v0, s, dxv = ring['val0'], ring['stride'], ring['dx']
        # How many records fit between val0 and the end of the ring, so no write leaves it.
        room = (ring['hi'] - max(v0, v0 + dxv) - 8) // s + 1
        n = min(NREC, room)
        if n < 1:
            print('no room above val0 inside the ring; rerun after the next frame')
            return
        print('write  : %d records from 0x%08X at %.1f dB (room for %d)' % (n, v0, WDB, room))

        lo8 = min(v0, v0 + dxv)
        span = max(v0, v0 + dxv) + 8 + (n - 1) * s - lo8
        ask(d, "print('O|' .. tostring(KG.own(%d,%d)))" % (lo8, span), 'O|')
        saved = []
        for k in range(n):
            a = v0 + k * s
            r = ask(d, one("do local s = KG.read(%d, 8)" % a,
                           "if s == nil then print('X|nil') return end",
                           "local o, i = '', nil",
                           "for i = 1, 8 do o = o .. string.format('%02X', string.byte(s, i)) end",
                           "print('X|' .. o) end"), 'X|', timeout=60)
            if r[2:].strip() == 'nil':
                raise SystemExit('cannot read record %d, so it must not be written' % k)
            saved.append((a, bytes.fromhex(r[2:].strip())))
        print('saved  : %d value fields read back for restore' % len(saved))

        before = sumplot(d)
        ask(d, "do KG.armed = true print('M|' .. tostring(KG.armed)) end", 'M|')
        pat = f32(WDB) * 2
        for a, _ in saved:
            r = ask(d, "print('V|' .. tostring(KG.write(%d, %s)))" % (a, luachars(pat)), 'V|')
            if not r.startswith('V|true'):
                raise SystemExit('the guard refused a write at 0x%08X: %s' % (a, r))
        print('wrote  : %d records' % len(saved))

        # One append to provoke the repaint, then let the display task run. It only runs while
        # Lua is blocked, which is what delay() is for.
        ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
                   "buffer.write.reading(fftsa.sg_buf, -105.0, 32768.0, fftsa.sg_stamp, 0)",
                   "delay(0.4) print('P|2') end"), 'P|2', timeout=120)
        after = sumplot(d)
        print()
        print('plot   : before %s  after %s  -> %s'
              % (before, after, 'CHANGED' if after != before else 'same'))
        if after != before:
            print('THE WIDGET DRAWS FROM THESE RECORDS. The bypass is real: one native write a')
            print('frame replaces 510 appends. Take a screenshot before the restore below.')
        else:
            print('No change. Either the widget recomputes from somewhere else, or the repaint')
            print('did not happen -- check that one append alone changes the plot at all before')
            print('concluding the records are not what is drawn.')
    finally:
        # EVERY STEP IN ITS OWN TRY, because this block itself gets interrupted.
        #
        # The first version chained the steps: a KeyboardInterrupt landed inside the second
        # one, so the third and the unpark never ran and the app was left with its frames
        # stopped. The operator's instrument then looked wedged -- and the socket genuinely
        # was unusable, for a different reason, which made the two indistinguishable.
        #
        # Restore first, because a widget cursor is not something the app rewrites. Unpark
        # last, because resuming frames is what repaints over anything a failed restore left,
        # and it has to be reached even if every step above it raised.
        def step(label, fn):
            try:
                fn()
            except BaseException as e:                                   # noqa: BLE001
                print('cleanup: %s FAILED -- %s: %s' % (label, type(e).__name__, e))

        if saved:
            def putback():
                for a, b in saved:
                    d.q("print('Z1|' .. tostring(KG.write(%d, %s)))" % (a, luachars(b)),
                        timeout=60)
                print('restore: %d field%s put back'
                      % (len(saved), '' if len(saved) == 1 else 's'))
            step('restore', putback)
        step('disarm',
             lambda: d.q('do if KG ~= nil then KG.armed = false KG.wb = nil end end',
                         timeout=30))
        step('globals', lambda: d.q('RS, RG = nil, nil', timeout=30))
        if parked:
            step('unpark', lambda: unpark(d))
            print('       : if the trace is still frozen, run on the instrument --')
            print('         fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil')
        step('close', d.close)


if __name__ == '__main__':
    main()
