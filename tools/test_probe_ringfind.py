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
import subprocess
import sys
import tempfile
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
GRABS = []
LUAC = os.path.expanduser('~/tmp/lua502/lua-5.0.2/bin/luac')


def lua_parse_error(cmd):
    """luac -p on one statement, or '' if it parses. '' also when luac is absent, which is
    stated once rather than silently skipped -- a check that cannot run must not read as a
    pass."""
    if not os.path.exists(LUAC):
        return ''
    with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False) as fh:
        fh.write(cmd + '\n')
        path = fh.name
    try:
        p = subprocess.run([LUAC, '-p', path], capture_output=True, text=True)
        if p.returncode == 0:
            return ''
        return (p.stderr or p.stdout).strip().split('\n')[-1].split(': ', 1)[-1]
    finally:
        os.unlink(path)


SEEN_CHECKS = []


def check(name, cond, detail=''):
    SEEN_CHECKS.append(name)
    print(('  PASS  ' if cond else '  FAIL  ') + name + (('   ' + detail) if detail else ''))
    if not cond:
        FAIL.append(name)


class StubDMM:
    """Answers by tag. Every statement is checked on the way in, which is the point."""

    def __init__(self, *a, **k):
        self.stmts = []
        self.wrote = {}
        self.pending = []

    def drain(self):
        del self.pending[:]

    def close(self):
        pass

    def send(self, s):
        # The probe now sends once and reads separately, which is what stopped it queueing a
        # slow statement fourteen times. The stub answers the same way: the reply is computed
        # at send time and handed back by the next line().
        self._check(s)
        self.pending.append(self._answer(s))

    def line(self, timeout=None):
        if self.pending:
            return self.pending.pop(0)
        return None

    RAISE_ON = None

    def q(self, cmd, timeout=None):
        self._check(cmd)
        if StubDMM.RAISE_ON and StubDMM.RAISE_ON in cmd:
            raise KeyboardInterrupt('interrupted inside %r' % cmd[:40])
        return self._answer(cmd)

    def _check(self, cmd):
        self.stmts.append(cmd)
        SEEN.append(cmd)
        if '\n' in cmd:
            FAIL.append('multiline statement: %r' % cmd[:120])
        if len(cmd) >= 1000:
            FAIL.append('statement is %d bytes: %r' % (len(cmd), cmd[:160]))
        # AND IT HAS TO BE LUA. A statement that does not parse prints nothing, so the
        # instrument looks wedged and the probe reports a desync with last=None -- which is
        # indistinguishable from a refusal and sent a bench session after the wrong thing.
        # The defect that produced this check was a Lua table constructor whose entries were
        # joined with a space instead of a comma. Nothing else here could see it: the tag
        # answer does not care whether the statement parses, and audit_probe.py works on the
        # Python source rather than on the string it builds.
        why = lua_parse_error(cmd)
        if why:
            FAIL.append('statement is not Lua 5.0.2: %s -- %r' % (why, cmd[:160]))

    SENT_X = [113, 127, 155, 211]        # deltas 14, 28, 56 -- the 1:2:4 of the Hz steps
    SENT_Y = [239, 241, 243, 245]        # deltas 2, 2, 2 -- the constant dB step

    def record(self, k):
        """A 56-byte record as a DMM6500 lays one down: two int32 triples, two zero words,
        the value twice, a flags word, the x twice, then 2.0f."""
        import struct as _s
        x = self.SENT_X[k] if k < 4 else 300 + k
        y = self.SENT_Y[k] if k < 4 else 200
        v = _s.pack('>f', -100.0 - (k if k < 4 else 0))
        hz = _s.pack('>f', 1024.0 * (2 ** k) if k < 4 else 20000.0)
        return (_s.pack('>III', x, x, x) + _s.pack('>III', y, y, y)
                + b'\0' * 8 + v + v + b'\0' * 4 + hz + hz + _s.pack('>f', 2.0))

    def mem(self, a, n):
        """Reads come from what was written if anything was, else from the synthetic ring.
        Serving writes back is what makes the probe's read-back assertion mean something."""
        out = bytearray()
        for i in range(n):
            if a + i in self.wrote:
                out.append(self.wrote[a + i])
            elif RING_LO <= a + i < RING_HI:
                k, off = divmod(a + i - RING_LO, STRIDE)
                out.append(self.record(k)[off])
            else:
                out.append(0)
        return bytes(out)

    def _answer(self, cmd):
        m = re.search(r"print\((?:string\.format\()?'([A-Z0-9]+)\|", cmd)
        tag = m.group(1) if m else None
        mw = re.search(r"KG\.write\((\d+), *string\.char\(([0-9,]+)\)", cmd)
        if mw:
            a = int(mw.group(1))
            for i, b in enumerate(int(x) for x in mw.group(2).split(',')):
                self.wrote[a + i] = b
            return 'V|true' if tag == 'V' else '%s|true' % (tag or 'V')
        mr = re.search(r"ki\.memread\('([0-9A-F]+)', *'([0-9A-F]+)'\)", cmd)
        if mr and tag == 'D':
            return 'D|' + self.mem(int(mr.group(1), 16), int(mr.group(2), 16)).hex().upper()
        if tag == 'PK':
            return 'PK|true'
        if tag == 'UP':
            return 'UP|true'
        if tag == 'SP':
            # The same value both times, which is what park() requires to call it stopped.
            return 'SP|787950'
        # The install statement DEFINES ZP, whose body contains a print -- so the first
        # print( in the text is ZT|, not the ZI|ok the statement actually reaches. Matched on
        # the definition rather than on the tag regex, which cannot see inside a function.
        if 'function ZP(' in cmd:
            return 'ZI|ok'
        if 'ZY = {}' in cmd:
            return 'ZY|480'
        if tag == 'ZB':
            return 'ZB|28560,1530'
        if tag == 'ZQ':
            return 'ZQ|3.104,28560'
        if tag == 'Z3':
            return 'Z3|true'
        if tag == 'ZT' or tag == 'ZC':
            return 'ZT|4.812'
        if tag == 'S2':
            return 'S2|28560'
        if tag == 'RW':
            return 'RW|%d,%d,%d' % (RING_LO, 255, RING_LO + 254 * STRIDE)
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
        # The grab runs screenshot.py out of process, which talks to the real instrument over
        # the LAN. A test must not do that: the first run of this harness timed out against a
        # live DMM. Replaced on the module rather than by patching subprocess, because
        # patching that globally once broke luac for every statement check in this file.
        del GRABS[:]
        mod.shot = lambda d, path: GRABS.append(path) or True
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
        (['--pixel'], 'the pixel-triple experiment', 'Compare /tmp/pixel_before.png'),
        (['--pixelpass'], 'the whole-pass pixel prototype', 'Compare /tmp/pass_before.png'),
        (['--pixelbulk'], 'the one-memwrite pass', 'in ONE memwrite'),
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
        if argv == ['--pixel']:
            check('the pixel phase grabs the glass before and after',
                  GRABS == ['/tmp/pixel_before.png', '/tmp/pixel_after.png'],
                  'grabs: %s' % (GRABS or 'none'))
        if argv == ['--pixelpass']:
            check('the pass phase grabs the glass before and after',
                  GRABS == ['/tmp/pass_before.png', '/tmp/pass_after.png'],
                  'grabs: %s' % (GRABS or 'none'))

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

    # THE CLEANUP HAS TO SURVIVE BEING INTERRUPTED IN THE MIDDLE OF ITSELF. Chained steps
    # meant a KeyboardInterrupt inside the second one skipped the third and the unpark, and
    # the app was left with its frames stopped on a real instrument -- which looks exactly
    # like a wedge and sent the recovery after the wrong fault.
    buf = io.StringIO()
    StubDMM.RAISE_ON = 'KG.armed = false KG.wb = nil end end'
    try:
        with contextlib.redirect_stdout(buf):
            run(['--pixel'])
    except BaseException:                                                # noqa: BLE001
        pass
    StubDMM.RAISE_ON = None
    out = buf.getvalue()
    check('an interrupt inside the cleanup still reaches the unpark',
          'UP|' in out or 'unpark' in out,
          'cleanup output: %r' % (out[-220:].replace('\n', ' | ') or 'none'))

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
    print('%d checks, %d failed' % (len(SEEN_CHECKS), len(FAIL)))
    for f in FAIL:
        print('  ' + f)
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
