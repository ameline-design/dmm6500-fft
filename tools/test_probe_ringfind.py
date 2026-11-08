#!/usr/bin/env python3
"""Drive probe_ringfind end to end against a stub instrument, before it is run on a real one.

A probe is untested code until it has run, and the run is the expensive part: the instrument
window is scarce, the app has to be relaunched to get a clean one, and a defect found at the
far end of a probe has already spent the window. audit_probe.py catches the static defects --
unbound names, a %% that reaches Lua, a %X Python ate -- and this catches the ones only
execution finds.

It stubs DMM and the guard, answers every statement by its tag, and asserts the two rules a
TSP statement has to satisfy: ONE LINE, and under 1000 bytes, because a one-line probe dies
past 1024 and a newline is two statements the instrument answers once.

Both defects it has already caught were tag collisions. Two statements printing different
field counts under one tag is not cosmetic: ask() retries until a reply STARTS with the tag,
so a stale three-field reply gets parsed as two and the probe dies on an unpack a long way
from the cause.

    python3 -I tools/test_probe_ringfind.py
"""
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
sys.path.insert(0, os.path.join(SIB, 'notes', 'firmware'))

# The geometry measured on a DMM6500 1.7.17a, so the stub answers what a real one would.
RING_LO, STRIDE, NREC = 0x03B53038, 56, 721
RING_HI = RING_LO + NREC * STRIDE
HDR = RING_LO - 40904
OV, OX = 32, 44
VAL0 = RING_LO + OV
NCOL, BN = 255, 510

FAIL = []
SEEN = []


def check(name, cond, detail=''):
    print(('  PASS  ' if cond else '  FAIL  ') + name + (('   ' + detail) if detail else ''))
    if not cond:
        FAIL.append(name)


class StubDMM:
    """Answers by tag. Every statement is checked on the way in, which is the point."""

    def __init__(self, *a, **k):
        self.stmts = []

    def drain(self):
        pass

    def close(self):
        pass

    def send(self, s):
        self._check(s)

    def q(self, cmd, timeout=None):
        self._check(cmd)
        return self._answer(cmd)

    def _check(self, cmd):
        self.stmts.append(cmd)
        SEEN.append(cmd)
        if '\n' in cmd:
            FAIL.append('multiline statement: %r' % cmd[:120])
        if len(cmd) >= 1000:
            FAIL.append('statement is %d bytes: %r' % (len(cmd), cmd[:160]))

    @staticmethod
    def _answer(cmd):
        m = re.search(r"print\((?:string\.format\()?'([A-Z0-9]+)\|", cmd)
        tag = m.group(1) if m else None
        if tag == 'A':
            return 'A|true|true'
        if tag == 'R':
            return 'R|ok|1,1/1, %X/%d' % (VAL0, STRIDE)
        if tag == 'H':
            return 'H|ok|%d,%d,%d,%d,%d,%d,%d,%d,%d' % (HDR, RING_LO, RING_HI, NREC,
                                                        OV, OX, VAL0, STRIDE, 12)
        if tag == 'S' and 'sg_ncol' in cmd:
            return 'S|510,510,255,true,0,50000,2048'
        if tag == 'S':
            return 'S|40376,255'
        if tag == 'N':
            return 'N|%d,%d,%d' % (NCOL, BN, BN)
        if tag == 'B':
            return 'B|255,%d,%d' % (RING_LO + 254 * STRIDE, RING_LO)
        if tag == 'L':
            return 'L|255,%d' % (RING_LO + 254 * STRIDE)
        if tag == 'A2':
            return 'A2|256,%d,%d' % (RING_LO + 255 * STRIDE, RING_LO)
        if tag == 'C':
            return 'C|123456'
        if tag == 'D':
            return 'D|' + '00' * STRIDE
        if tag == 'X':
            return 'X|' + 'C2C80000' * 2
        if tag == 'T':
            return 'T|7.31|0.12'
        if tag == 'O' or tag == 'M' or tag == 'V':
            return '%s|true' % tag
        # A tag that prints its own payload, like W|3 or KG|2, echoes it back.
        m2 = re.search(r"print\('([A-Z]+\|[0-9]+)'\)", cmd)
        if m2:
            return m2.group(1)
        if tag:
            return '%s|1' % tag
        return None


class StubGuard:
    def __init__(self, *a, **k):
        pass

    @staticmethod
    def tsp():
        return ["do print('KG|%d') end" % i for i in range(1, 6)]


def run(argv):
    """Load probe_ringfind fresh so its module-level flags see this argv, and run main."""
    import dmmrun
    import fwguard
    dmmrun.DMM = StubDMM
    fwguard.Guard = StubGuard
    saved = sys.argv
    sys.argv = ['probe_ringfind.py'] + argv
    del SEEN[:]
    try:
        src = open(os.path.join(HERE, 'probe_ringfind.py')).read()
        mod = types.ModuleType('probe_ringfind_under_test')
        mod.__dict__['__name__'] = 'probe_ringfind_under_test'
        exec(compile(src, 'probe_ringfind.py', 'exec'), mod.__dict__)
        mod.main()
    finally:
        sys.argv = saved
    return list(SEEN)


def main():
    import io
    import contextlib

    for argv, name, want in (
        ([], 'the read-only phase', 'Read only'),
        (['--pass'], 'the whole-pass refusal without --yes', 'add --yes'),
        (['--pass', '--yes', '--hold', '2'], 'the whole-pass prototype', 'restore: header'),
        (['--write'], 'the single-record experiment', 'restore: '),
    ):
        buf = io.StringIO()
        before = len(FAIL)
        try:
            with contextlib.redirect_stdout(buf):
                stmts = run(argv)
        except SystemExit as e:
            # The write phase ends in SystemExit when the stub refuses, which is the path
            # that proves the restore happens in finally. Not a failure.
            stmts = list(SEEN)
            buf.write('\n[SystemExit] %s\n' % e)
        out = buf.getvalue()
        check('%s runs, %d statements, all one line and under 1000 bytes'
              % (name, len(stmts)), len(FAIL) == before, '%d statements' % len(stmts))
        check('%s reaches its end' % name, want in out,
              'looked for %r' % want)

    # The restore has to be in the finally, so it happens even when the body raises. The
    # write phase above raises on the stub's refusal, so the restore statement must still be
    # among those seen.
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            run(['--write'])
    except SystemExit:
        pass
    restored = [s for s in SEEN if 'KG.write' in s and 'Z1|' in s]
    check('a refusal mid-write still runs the restore', len(restored) > 0,
          '%d restore statements after the raise' % len(restored))

    # And no statement may define a tag that another statement with a different field count
    # also uses, because ask() matches on the prefix alone.
    tags = {}
    for s in SEEN:
        m = re.search(r"print\((?:string\.format\()?'([A-Z0-9]+)\|", s)
        if not m:
            continue
        n = s.count("','") + s.count("..  ','") + s.count(".. ','")
        tags.setdefault(m.group(1), set()).add(n)
    clashes = sorted(t for t, v in tags.items() if len(v) > 1)
    check('no tag is shared by statements printing different field counts', not clashes,
          'clashing: %s' % (', '.join(clashes) or 'none'))

    print()
    print('%d checks, %d failed' % (8 + 2, len(FAIL)))
    for f in FAIL:
        print('  ' + f)
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
