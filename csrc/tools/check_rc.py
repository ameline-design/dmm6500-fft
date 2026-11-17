#!/usr/bin/env python3
"""Gate: the two status-code spaces, against the Lua that names them.

One 32-bit word in dsp_native_params carries every answer the image gives, and TWO sets of
negative codes travel through it. dsp_native.c has its own DSPN_E* set, and MODE_INIT forwards
whatever dsp_plan_init_segs returned, which is dsp.h's DSP_E* set. Both are small negatives and
the numbers collide: DSP_EBETA is -6 and so is DSPN_EOUTPUT, so a Kaiser beta the plan builder
refused was reported on the glass as an output-geometry fault. The image therefore SHIFTS a
forwarded negative by DSPN_PLAN_BASE and fftsa.nl.rc_name subtracts it again.

Nothing in either language connects the C numbers to the Lua names. rc_name walks a table
written out by hand, so a code added, renumbered or removed on the C side leaves rc_name
printing a bare number -- or, worse, the WRONG name, which is what the collision above did for
a year. The diagnostic is the only channel this app has: the instrument is reached by a screen
grab, and "rc=-6 EOUTPUT" sends the reader to the output geometry when the fault was a window
parameter. A lying diagnostic costs more than a missing one.

Five things are checked:

  * every DSPN_E* define is named in fftsa.nl.RC with the same number, and every RC entry
    exists in the C -- both directions, so a stale Lua name is caught as well as a new C code;
  * every DSP_E* in dsp.h's enum is named in fftsa.nl.PLAN_RC, and the reverse;
  * DSPN_PLAN_BASE and fftsa.nl.PLAN_BASE agree, since one shifts and the other unshifts;
  * no DSPN_E* code is at or below PLAN_BASE, which rc_name would read as a forwarded code
    and name out of the wrong table;
  * no DSP_E* code, once shifted, lands on a DSPN_E* code -- the shift has to separate the
    spaces, not merely move one;
  * MODE_INIT's forward applies the shift, and MODE_SEGS' does not.

That last one is a SOURCE check, and it is here because nothing else can reach the line.
dsp_native.c is compiled only for powerpc-unknown-elf -- CMake builds it under
DSP_DST_NATIVE and never for the host -- so no test can call dsp_native_run and watch what it
returns. The shift is one expression, and an expression held by reading alone is how the
collision above survived in the first place. MODE_SEGS is checked for the ABSENCE of it because
dsp_plan_segs converts every invalid configuration to 0: it has no negative to forward, so a
shift there would be unreachable code asserting a fact that is not true of it.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CSRC = os.path.join(ROOT, 'csrc', 'dsp_native.c')
HDR = os.path.join(ROOT, 'csrc', 'dsp.h')
MODULE = os.path.join(ROOT, 'tsp', 'native_link.tsp')


def c_wrapper_codes(src):
    """#define DSPN_E<NAME> (-N) -- the wrapper's own space."""
    out = {}
    for m in re.finditer(r'^#define\s+DSPN_(E[A-Z0-9]+)\s+\(?\s*(-?\d+)\s*\)?\s*$',
                         src, re.M):
        out[m.group(1)] = int(m.group(2))
    return out


def c_plan_codes(hdr):
    """DSP_E<NAME> = -N, from the enum in dsp.h -- the forwarded space.

    The name may carry digits (DSP_EPOW2), which a letters-only pattern walks past. That is
    exactly how EPOW2 came to be missing from PLAN_RC while every other code was present.
    """
    out = {}
    for m in re.finditer(r'\bDSP_(E[A-Z0-9]+)\s*=\s*(-?\d+)', hdr):
        out[m.group(1)] = int(m.group(2))
    return out


def c_plan_base(src):
    m = re.search(r'^#define\s+DSPN_PLAN_BASE\s+\(?\s*(-?\d+)\s*\)?\s*$', src, re.M)
    return int(m.group(1)) if m else None


def lua_table(mod, name):
    """fftsa.nl.<name> = { K = -N, ... } up to the closing brace."""
    m = re.search(r'^fftsa\.nl\.' + name + r'\s*=\s*\{(.*?)^\}', mod, re.M | re.S)
    if m is None:
        return None
    out = {}
    for k, v in re.findall(r'([A-Z][A-Z0-9_]*)\s*=\s*(-?\d+)', m.group(1)):
        out[k] = int(v)
    return out


def lua_scalar(mod, name):
    m = re.search(r'^fftsa\.nl\.' + name + r'\s*=\s*(-?\d+)', mod, re.M)
    return int(m.group(1)) if m else None


def check(csrc_text, hdr_text, mod_text):
    bad = []
    wrap = c_wrapper_codes(csrc_text)
    plan = c_plan_codes(hdr_text)
    base_c = c_plan_base(csrc_text)
    rc = lua_table(mod_text, 'RC')
    plan_rc = lua_table(mod_text, 'PLAN_RC')
    base_lua = lua_scalar(mod_text, 'PLAN_BASE')

    if not wrap:
        bad.append('no DSPN_E* defines found in the C')
    if not plan:
        bad.append('no DSP_E* codes found in dsp.h')
    if rc is None:
        bad.append('fftsa.nl.RC not found')
        rc = {}
    if plan_rc is None:
        bad.append('fftsa.nl.PLAN_RC not found')
        plan_rc = {}

    for name, val in sorted(wrap.items()):
        if name not in rc:
            bad.append('DSPN_%s = %d is not named in fftsa.nl.RC' % (name, val))
        elif rc[name] != val:
            bad.append('DSPN_%s is %d in the C and %d in fftsa.nl.RC'
                       % (name, val, rc[name]))
    for name, val in sorted(rc.items()):
        if name not in wrap:
            bad.append('fftsa.nl.RC.%s = %d names no DSPN_* define' % (name, val))

    for name, val in sorted(plan.items()):
        if name not in plan_rc:
            bad.append('DSP_%s = %d is not named in fftsa.nl.PLAN_RC' % (name, val))
        elif plan_rc[name] != val:
            bad.append('DSP_%s is %d in dsp.h and %d in fftsa.nl.PLAN_RC'
                       % (name, val, plan_rc[name]))
    for name, val in sorted(plan_rc.items()):
        if name not in plan:
            bad.append('fftsa.nl.PLAN_RC.%s = %d names no DSP_E* code' % (name, val))

    if base_c is None:
        bad.append('DSPN_PLAN_BASE not found in the C')
    elif base_lua is None:
        bad.append('fftsa.nl.PLAN_BASE not found')
    elif base_c != base_lua:
        bad.append('PLAN_BASE is %d in the C and %d in Lua' % (base_c, base_lua))
    else:
        # The shift has to SEPARATE the spaces. Either test failing means rc_name picks a
        # table by comparing against PLAN_BASE and picks the wrong one.
        for name, val in sorted(wrap.items()):
            if val <= base_c:
                bad.append('DSPN_%s = %d is at or below PLAN_BASE %d, so rc_name would read '
                           'it as forwarded' % (name, val, base_c))
        shifted = {}
        for name, val in plan.items():
            shifted[val + base_c] = name
        for name, val in sorted(wrap.items()):
            if val in shifted:
                bad.append('DSP_%s shifts onto DSPN_%s at %d'
                           % (shifted[val], name, val))

    # The two forwards, by what their RET expression says.
    m = re.search(r'DSPN_MODE_INIT\).*?RET\(([^;]*)\);', csrc_text, re.S)
    if m is None:
        bad.append('no RET found in the MODE_INIT block')
    elif 'DSPN_PLAN_BASE' not in m.group(1):
        bad.append("MODE_INIT forwards unshifted: RET(%s)" % m.group(1).strip())
    m = re.search(r'DSPN_MODE_SEGS\).*?RET\(([^;]*)\);', csrc_text, re.S)
    if m is None:
        bad.append('no RET found in the MODE_SEGS block')
    elif 'DSPN_PLAN_BASE' in m.group(1):
        bad.append('MODE_SEGS shifts, but dsp_plan_segs returns 0 for every invalid '
                   'configuration and so has no negative to forward')
    return wrap, plan, bad


def self_test():
    """Each check has to fail when the thing it checks is broken."""
    csrc = """
#define DSPN_EMAGIC      (-1)
#define DSPN_EOUTPUT     (-6)
#define DSPN_EFIND      (-14)
#define DSPN_PLAN_BASE (-100)
    if (p->mode == DSPN_MODE_SEGS) {
        RET(dsp_plan_segs((int)p->cap_n));
    }
    if (p->mode == DSPN_MODE_INIT) {
        RET(rc < 0 ? rc + DSPN_PLAN_BASE : rc);
    }
"""
    hdr = """
    DSP_EARG  = -1,
    DSP_EPOW2 = -2,
    DSP_EBETA = -6,
"""
    mod = """
fftsa.nl.RC = {
  EMAGIC = -1, EOUTPUT = -6, EFIND = -14,
}
fftsa.nl.PLAN_BASE = -100
fftsa.nl.PLAN_RC = {
  EARG = -1, EPOW2 = -2, EBETA = -6,
}
"""
    cases = []
    _, _, bad = check(csrc, hdr, mod)
    cases.append(('the matched pair is clean', not bad, bad))

    # a C code the Lua does not name
    _, _, bad = check(csrc + '#define DSPN_ENEW (-15)\n', hdr, mod)
    cases.append(('an unnamed DSPN code is caught', bool(bad), None))

    # a renumbered code
    _, _, bad = check(csrc.replace('(-6)', '(-7)'), hdr, mod)
    cases.append(('a renumbered DSPN code is caught', bool(bad), None))

    # a stale Lua name
    _, _, bad = check(csrc, hdr, mod.replace('EFIND = -14,', 'EFIND = -14, EGONE = -20,'))
    cases.append(('a stale RC entry is caught', bool(bad), None))

    # the digit-bearing plan code dropped, which a letters-only sweep misses
    _, _, bad = check(csrc, hdr, mod.replace('EPOW2 = -2, ', ''))
    cases.append(('a missing PLAN_RC code is caught', bool(bad), None))

    # the two bases disagreeing
    _, _, bad = check(csrc, hdr, mod.replace('PLAN_BASE = -100', 'PLAN_BASE = -90'))
    cases.append(('a PLAN_BASE mismatch is caught', bool(bad), None))

    # a wrapper code reaching into the forwarded space
    _, _, bad = check(csrc + '#define DSPN_EDEEP (-120)\n',
                      hdr, mod.replace('EFIND = -14,', 'EFIND = -14, EDEEP = -120,'))
    cases.append(('a DSPN code below PLAN_BASE is caught', bool(bad), None))

    # a shift that lands one space on the other
    _, _, bad = check(csrc.replace('(-100)', '(-8)'), hdr,
                      mod.replace('PLAN_BASE = -100', 'PLAN_BASE = -8'))
    cases.append(('a shift that collides is caught', bool(bad), None))

    # MODE_INIT forwarding raw, which is the original defect
    _, _, bad = check(csrc.replace('RET(rc < 0 ? rc + DSPN_PLAN_BASE : rc);', 'RET(rc);'),
                      hdr, mod)
    cases.append(('an unshifted MODE_INIT forward is caught', bool(bad), None))

    # and a shift where there is nothing to shift
    _, _, bad = check(csrc.replace('RET(dsp_plan_segs((int)p->cap_n));',
                                   'RET(dsp_plan_segs((int)p->cap_n) + DSPN_PLAN_BASE);'),
                      hdr, mod)
    cases.append(('a shift in MODE_SEGS is caught', bool(bad), None))

    rc = 0
    for name, ok, detail in cases:
        print('  %-44s %s' % (name, 'ok' if ok else 'FAILED'))
        if not ok:
            rc = 1
            if detail:
                for d in detail:
                    print('      %s' % d)
    return rc


def main():
    if '--self-test' in sys.argv:
        rc = self_test()
        print('self-test %s' % ('passed' if rc == 0 else 'FAILED'))
        return rc
    with open(CSRC) as fh:
        csrc_text = fh.read()
    with open(HDR) as fh:
        hdr_text = fh.read()
    with open(MODULE) as fh:
        mod_text = fh.read()
    wrap, plan, bad = check(csrc_text, hdr_text, mod_text)
    for b in bad:
        print('  %s' % b)
    if bad:
        print('status codes: %d problem(s)' % len(bad))
        return 1
    print('status codes: %d wrapper codes and %d forwarded codes, named and separated'
          % (len(wrap), len(plan)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
