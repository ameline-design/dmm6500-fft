#!/usr/bin/env python3
"""Does the frame loop need an accurate timer at all?

The app computes a period from measured work and re-arms a display timer whenever it moves.
That is a feedback loop, it churns a pool object on every re-arm, and it is what raises event
1727 -- a log line on a DMM6500 and a MODAL PROMPT on a DMM7510.

There is a second way to schedule the same work, and it needs no accurate period: ARM ONE FIXED
TIMER AT THE 0.05 s FLOOR AND LET THE FIRMWARE DROP THE TICKS THAT LAND MID-FRAME. A tick
arriving while the interpreter is busy is discarded, so the achieved period becomes
ceil(work / 0.05) * 0.05 all by itself. No arithmetic, no re-arming, and every armed period is a
multiple of 0.05 -- which is exactly when 1727 does not fire, on any model.

What that costs or buys is arithmetic nobody has measured:

  * at a work time just under a multiple of 0.05 it is FREE
  * at a work time just over one it loses up to 0.05 s
  * at the short counts it should WIN, because the adaptive period adds fftsa.tick_idle of
    slack -- 20 ms -- and the dropped-tick scheme adds none

So this measures the achieved frame rate both ways, at several sample counts, on the same boot
and the same signal. It changes nothing permanently: the timer is put back to the app's own
arithmetic at the end, and the app is left running.

THE APP MUST BE LAUNCHED FROM THE KEY. A control socket kills display event dispatch, so an app
launched over the socket has no timer firing at all and every figure here would be zero.

    python3 -u -I tools/probe_tickmode.py
    python3 -u -I tools/probe_tickmode.py --counts 512,2048,16384 --secs 12
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dmmrun  # noqa: E402


def opt(flag, default, cast=int):
    if flag in sys.argv:
        return cast(sys.argv[sys.argv.index(flag) + 1])
    return default


COUNTS = [int(x) for x in opt('--counts', '512,1024,2048,8192', str).split(',')]
# NOT ZERO BY DEFAULT, AND THE DEFAULT IS THE WHOLE POINT.
#
# A fixed tick with no slack starves the interpreter. Measured 2026-11-09 at 8192, where the
# frame is about 420 ms: the 50 ms tick coalesced into back-to-back frames with no gap at all,
# and since button handlers and setevent strings are Lua, NOTHING could get in -- 733 socket
# statements refused in four minutes, End App dead, hardware keys dead. Only ABORT recovered it,
# and that tore the app down with it.
#
# So this probe never runs the fixed mode without slack unless it is asked to in so many words,
# and --yield 0 is a deliberate act.
YIELD = opt('--yield', 0.020, float)
SECS = opt('--secs', 10, float)
FIXED = opt('--fixed', 0.05, float)


def ask(d, cmd, tag, timeout=600):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    d.drain()
    d.send(cmd)
    t_end = time.time() + timeout
    last, resends = None, 0
    while time.time() < t_end:
        t0 = time.time()
        r = d.line(min(20.0, t_end - time.time()))
        if r is None:
            if time.time() - t0 < 0.05:
                time.sleep(0.25)
            continue
        last = str(r)
        if last.startswith(tag):
            return last
        if 'another interface' in last:
            # A REFUSAL IS NOT A FAILURE, and at the long counts it is the normal answer: a
            # 420 ms frame holds the interpreter for most of every period, so a statement is
            # refused many times before it lands. Paced and bounded by the DEADLINE rather
            # than by a count of refusals -- counting them desynced the 8192 case while the
            # instrument was working perfectly.
            resends += 1
            time.sleep(0.2)
            d.drain()
            d.send(cmd)
    raise SystemExit('DESYNC(%s) last=%r after %d refusals' % (tag, last, resends))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


# The app has no monotonic frame counter, so one is WRAPPED round fftsa.frame rather than
# rebuilt into the app: the timer's handler calls it by name, so a wrapper is picked up on the
# next tick and taken off again by restoring the field. Counting frames and not sg_stamp
# matters because a pass reserves a different number of timestamps in each fill mode, and the
# divisor would then differ between the two cases being compared.
# ZY is the slack a self-pacing loop has to leave behind it, and the reason it is needed is
# not frame rate. The adaptive period arms work + tick_idle, so there is ALWAYS a gap in which
# the interpreter is free: button handlers are Lua, and so is every socket statement. A loop
# paced only by its own work leaves no gap at all -- at 8192, with a 50 ms tick and a 420 ms
# frame, the control socket went from answering to refusing almost continuously.
#
# So the slack stays, as an explicit delay at the END of the frame rather than as an estimate
# folded into a period. It costs the same milliseconds and needs no accuracy: 20 ms of yield is
# 20 ms, where 20 ms of slack rounded up to the next 50 ms grid step costs up to 50.
WRAP = ("do if fftsa.ZWRAP == nil then fftsa.ZWRAP = fftsa.frame ZN = 0 ZY = ZY or 0 "
        "fftsa.frame = function() ZN = ZN + 1 local r = fftsa.ZWRAP() "
        "if ZY > 0 then delay(ZY) end return r end end "
        "print('WR|' .. tostring(ZN) .. '|' .. tostring(ZY)) end")
UNWRAP = ("do if fftsa.ZWRAP ~= nil then fftsa.frame = fftsa.ZWRAP fftsa.ZWRAP = nil end "
          "print('UW|' .. tostring(fftsa.ZWRAP == nil)) end")


def rate(d, secs):
    """Frames a second, counted by the wrapper."""
    a = int(ask(d, "print('FC|' .. tostring(ZN or -1))", 'FC|', timeout=60)[3:])
    if a < 0:
        raise SystemExit('the frame wrapper is not installed')
    t0 = time.time()
    time.sleep(secs)
    b = int(ask(d, "print('FC|' .. tostring(ZN))", 'FC|', timeout=60)[3:])
    el = time.time() - t0
    return (b - a) / el, b - a, el


def phases(d):
    return ask(d, "print('PH|' .. tostring(fftsa.phases()))", 'PH|', timeout=120)[3:]


def work_ms(d):
    return float(ask(d, "print('WK|' .. string.format('%.2f', 1000 * (fftsa.frame_work or 0)))",
                     'WK|', timeout=60)[3:])


def armed(d):
    return ask(d, one("print('AR|n=' .. tostring(fftsa.armed_n)",
                      ".. ' grid=' .. tostring(fftsa.tick_grid_now and fftsa.tick_grid_now())",
                      ".. ' want=' .. string.format('%.3f',",
                      "fftsa.tick_period(fftsa.frame_work or 0)))"), 'AR|', timeout=60)[3:]


def set_count(d, n):
    ask(d, one("do fftsa.n = %d fftsa.apply()" % n,
               "print('NC|' .. tostring(fftsa.n) .. '|' .. tostring(fftsa.nl.ready)",
               ".. '|' .. tostring(fftsa.halted)) end"), 'NC|', timeout=600)


# The fixed-period case. The app's own arithmetic is replaced by a constant, and the re-arm
# threshold is pushed out of reach so nothing changes it back; the frame body is untouched.
def fix_timer(d, period):
    return ask(d, one("do fftsa.ZKEEP = fftsa.tick_period",
                      "fftsa.tick_period = function() return %.3f end" % period,
                      "fftsa.ZRE = fftsa.tick_rearm fftsa.tick_rearm = 1e9",
                      "fftsa.arm(%.3f)" % period,
                      "print('FX|' .. tostring(fftsa.timer ~= nil)) end"), 'FX|', timeout=300)


def unfix_timer(d):
    return ask(d, one("do if fftsa.ZKEEP ~= nil then fftsa.tick_period = fftsa.ZKEEP end",
                      "if fftsa.ZRE ~= nil then fftsa.tick_rearm = fftsa.ZRE end",
                      "fftsa.ZKEEP, fftsa.ZRE = nil, nil",
                      "fftsa.arm(fftsa.tick_period(fftsa.frame_work))",
                      "print('UF|' .. tostring(fftsa.timer ~= nil)) end"), 'UF|', timeout=300)


def restore(d):
    """Everything this probe changed, in ONE statement.

    One, because a saturated interpreter refuses most of what is sent to it and each statement
    that has to land is another chance to be locked out. The one that was written as four never
    got past the first.
    """
    return ask(d, one("do if fftsa.ZWRAP ~= nil then fftsa.frame = fftsa.ZWRAP",
                      "fftsa.ZWRAP = nil end",
                      "if fftsa.ZKEEP ~= nil then fftsa.tick_period = fftsa.ZKEEP",
                      "fftsa.ZKEEP = nil end",
                      "if fftsa.ZRE ~= nil then fftsa.tick_rearm = fftsa.ZRE",
                      "fftsa.ZRE = nil end",
                      "ZY = 0 fftsa.arm(fftsa.tick_period(fftsa.frame_work))",
                      "print('RS|n=' .. tostring(fftsa.n)",
                      ".. ' timer=' .. tostring(fftsa.timer ~= nil)) end"), 'RS|', timeout=300)


def main():
    d = dmmrun.DMM(timeout=300, recover=False)
    for _ in range(40):
        r = d.q(one("print('A|' .. tostring(fftsa ~= nil and fftsa.VERSION)",
                    ".. '|' .. tostring(fftsa ~= nil and fftsa.halted)",
                    ".. '|' .. tostring(fftsa ~= nil and fftsa.timer ~= nil))"), timeout=30)
        if r is not None and str(r).startswith('A|') and 'another interface' not in str(r):
            f = str(r).split('|')
            print('app     : v%s halted=%s timer=%s' % (f[1], f[2], f[3]))
            if f[2] == 'true':
                raise SystemExit('the app is HALTED; relaunch before measuring anything')
            break
        time.sleep(0.5)
    else:
        raise SystemExit('the app is not answering')

    ask(d, "do ZY = %.3f print('ZY|' .. tostring(ZY)) end" % YIELD, 'ZY|', timeout=120)
    print('wrap    : %s  (end-of-frame yield %.0f ms)'
          % (ask(d, WRAP, 'WR|', timeout=120), 1000 * YIELD))
    time.sleep(1.5)
    base = rate(d, 3.0)[0]
    if base <= 0.01:
        raise SystemExit('no frames are running -- is the app launched from the KEY? '
                         'A socket session stops a socket-launched app\'s timer dead.')
    print('frames  : %.2f/s before anything is changed' % base)
    print()
    print('%-7s  %-28s  %-28s' % ('count', 'adaptive (the app as it is)', 'fixed %.0f ms, ticks dropped'
                                  % (1000 * FIXED)))
    # Every path out of the loop below goes through restore(), including a raise: leaving a
    # fixed period behind is what locked the instrument out, and the probe exiting is exactly
    # when nobody is watching for it.
    rows = []
    try:
        rows = sweep(d)
    finally:
        try:
            print('restore : %s' % restore(d))
        except Exception as exc:
            print('restore : FAILED (%s) -- send ABORT on 5025; it frees the interpreter '
                  'and takes the app with it' % type(exc).__name__)
    report(rows)
    print('unwrap  : %s' % ask(d, UNWRAP, 'UW|', timeout=120))
    return 0


def sweep(d):
    rows = []
    for n in COUNTS:
        set_count(d, n)
        time.sleep(1.0)
        a_fps, a_n, a_el = rate(d, SECS)
        a_work, a_arm = work_ms(d), armed(d)
        fix_timer(d, FIXED)
        time.sleep(1.0)
        f_fps, f_n, f_el = rate(d, SECS)
        f_work = work_ms(d)
        unfix_timer(d)
        rows.append((n, a_fps, a_work, a_arm, f_fps, f_work))
        print('%-7d  %5.2f fps, work %6.1f ms  %5.2f fps, work %6.1f ms   %s'
              % (n, a_fps, a_work, f_fps, f_work,
                 'fixed WINS' if f_fps > a_fps * 1.02 else
                 ('same' if f_fps > a_fps * 0.98 else 'fixed loses')))

    return rows


def report(rows):
    if not rows:
        return
    print()
    print('count / grid / what the app would have armed:')
    for n, a_fps, a_work, a_arm, f_fps, f_work in rows:
        print('  n=%-6d %s' % (n, a_arm))
    print()
    print('A fixed period is a multiple of 0.05 by construction, so event 1727 cannot fire --')
    print('which is the whole of the DMM7510 dialog. What it costs is above; what it REQUIRES')
    print('is the end-of-frame yield, without which the interpreter never goes free.')


if __name__ == '__main__':
    sys.exit(main())
