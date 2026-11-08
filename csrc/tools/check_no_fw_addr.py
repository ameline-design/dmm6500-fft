#!/usr/bin/env python3
"""Gate: nothing in the native path holds a firmware address.

The operator's requirement is that the app has a good chance of working unmodified after a
firmware upgrade. A wrong firmware address is not a refusal -- the trampoline branches to
whatever now occupies it, which bluescreens, and ki.reboot cannot recover a bluescreen. So
this checks the three places an address could hide and fails the build if one appears.

  1. The trampoline bytes, instruction by instruction. The literal in native_link.tsp is
     executed from the heap and nothing patches it, so an address in it would have to be
     formed by the instructions themselves. Anything that could form one is refused:
     addis/lis, ori/oris, a move to CTR, a branch to CTR or LR that links, a branch with
     the absolute bit set, and a D-form load or store with rA = 0, which addresses the
     low 32 KB directly.

  2. csrc/dsp_native.c, for a literal inside firmware .text. The image is called with no
     Lua arguments and reports through the params struct, so it needs no entry point but
     the six math addresses, and those arrive in the struct from FNF at runtime.

  3. tsp/native_link.tsp, for a decimal literal that looks like an entry point. Lua 5.0.2
     has no hex, so an address there is a large decimal. Round numbers are excluded: a
     power of two or a multiple of 1024 in this file is a mask, a field width or a range
     bound, while an entry point sits at an arbitrary offset. Those exclusions are listed
     in the output so a 1024-aligned address cannot hide behind them silently.

  4. And no version-to-address table anywhere, which is what a gate on the version string
     was: a build not in the table lost the native path, and a build wrongly in it
     bluescreened.

  5. EVERY integer literal in the native path that falls inside DRAM, against a list that
     states why each one is not an address. Checks 1 to 4 only look in firmware .text, and
     that is how this gate passed a build whose write backstop and heap sweep windows were
     both the DMM6500's heap measured in hex -- 0x01036000..0x0D836000, which is in DRAM,
     is 1024-aligned so the round-number exclusion waved it through, and which left 45% of
     a DMM7510's heap unswept. The app would not start and the gate said nothing.

     csrc/dsp_native_bounds.h was not read at all, which is where the backstop lives.

     The list is small on purpose. A new DRAM-range constant fails until someone writes
     down what it is, and the one model-dependent figure left in the tree -- TEXT_HI -- is
     named as such rather than hidden among the arithmetic.

    python3 -I csrc/tools/check_no_fw_addr.py
    python3 -I csrc/tools/check_no_fw_addr.py --self-test
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODULE = os.path.join(ROOT, 'tsp', 'native_link.tsp')
CSRC = os.path.join(ROOT, 'csrc', 'dsp_native.c')
BOUNDS = os.path.join(ROOT, 'csrc', 'dsp_native_bounds.h')

# DRAM, as the backstop declares it. Anything in here could be an address.
DRAM_LO, DRAM_END = 0x00003000, 0x10000000
# Below this a literal is a field width, an enum or a small count, not an address worth
# checking: the lowest thing the native path addresses is the vector area top at 0x3000.
DRAM_FLOOR = 0x3000

# Every DRAM-range literal the native path is allowed to hold, and why it is not an address.
# A value missing from here fails the gate, which is the whole point: the 6500 heap bounds
# that broke the DMM7510 were 1024-aligned and sailed through a round-number exclusion.
DRAM_ALLOW = {
    12288: 'DSPN_DRAM_LO, 0x3000: the top of the vector area. A board figure, not a build one',
    16384: 'TEXT_LO, 0x4000: where firmware .text starts, the same on both models',
    32768: 'CHUNK_BYTES, the reading-buffer chunk payload, and the sweep slice size',
    65536: 'the 16-bit split in the float packers and in hex formatting',
    262144: 'TIGHT, 256 KB: the tight descriptor window, a distance and not a place',
    1000000: 'a seed reading written into a buffer this module creates',
    1048576: 'the chunk payload ceiling, and MB arithmetic in a report',
    2000000: 'a seed reading',
    3000000: 'a seed reading',
    4000000: 'a seed reading',
    4194304: 'MID, 4 MB: the second descriptor window, a distance',
    5402624: 'TEXT_HI, 0x527000. THE ONE MODEL-DEPENDENT FIRMWARE FIGURE LEFT IN THE TREE. '
             'It is a ceiling the backstop and the lua_CFunction check rest on, and every '
             'image measured so far puts its heap floor above it -- check_fw_strategy.py '
             'asserts that per image. A model that does not would need this derived',
    8388608: '2^23, the float32 significand',
    16777216: '2^24, byte arithmetic in the branch decoder and the packers',
    25165824: 'ANCHOR_NEAR, 24 MB: a sweep radius',
    67108864: '2^26, the primary opcode field in the branch decoder',
    134217728: 'ANCHOR_FAR, 128 MB: a sweep radius',
}

# Firmware .text, the same extent TEXT_LO and TEXT_HI declare. A call target has to be in
# here to be a call target, which is what makes this the range to scan.
TEXT_LO = 0x00004000
TEXT_HI = 0x00527000

# Primary opcodes that can build or reach an absolute address.
OP_FORBIDDEN = {
    15: 'addis/lis builds the high half of an absolute address',
    24: 'ori completes an absolute address built by lis',
    25: 'oris completes an absolute address built by lis',
}
# D-form loads and stores. rA = 0 means the displacement is the whole address.
OP_DFORM = {32: 'lwz', 33: 'lwzu', 34: 'lbz', 35: 'lbzu', 36: 'stw', 37: 'stwu',
            38: 'stb', 39: 'stbu', 40: 'lhz', 41: 'lhzu', 42: 'lha', 43: 'lhau',
            44: 'sth', 45: 'sthu', 48: 'lfs', 49: 'lfsu', 50: 'lfd', 51: 'lfdu',
            52: 'stfs', 53: 'stfsu', 54: 'stfd', 55: 'stfdu'}
XO_MTSPR = 467
SPR_CTR = 9


def tramp_bytes(src):
    m = re.search(r"fftsa\.nl\._TRAMP\s*=\s*'((?:\\\d{3})+)'", src)
    if m is None:
        return None
    return bytes(int(v) for v in re.findall(r'\\(\d{3})', m.group(1)))


def check_tramp(src):
    """Every instruction of the shipped trampoline, against the forbidden forms."""
    bad = []
    data = tramp_bytes(src)
    if data is None:
        return ['no fftsa.nl._TRAMP literal in %s' % MODULE]
    if len(data) % 4 != 0:
        bad.append('the trampoline is %d bytes, not a whole number of instructions'
                   % len(data))
        return bad
    m = re.search(r'fftsa\.nl\.TRAMP_RANGE\s*=\s*(\d+)', src)
    if m is None:
        return ['no fftsa.nl.TRAMP_RANGE in %s' % MODULE]
    rng = int(m.group(1))
    for off in range(0, len(data), 4):
        # The range words are data the loader writes, not instructions.
        if rng <= off < rng + 8:
            continue
        w = int.from_bytes(data[off:off + 4], 'big')
        op = w >> 26
        if op in OP_FORBIDDEN:
            bad.append('trampoline+%d is %s: %s' % (off, OP_FORBIDDEN[op], '%08X' % w))
        elif op in (16, 18) and (w & 2):
            bad.append('trampoline+%d branches to an absolute address: %08X' % (off, w))
        elif op == 19 and (w & 1):
            bad.append('trampoline+%d is a linking branch through CTR or LR: %08X'
                       % (off, w))
        elif op == 31 and ((w >> 1) & 0x3FF) == XO_MTSPR:
            spr = ((w >> 16) & 0x1F) | (((w >> 11) & 0x1F) << 5)
            if spr == SPR_CTR:
                bad.append('trampoline+%d loads CTR, which is how a far call is made: %08X'
                           % (off, w))
        elif op in OP_DFORM and ((w >> 16) & 0x1F) == 0:
            bad.append('trampoline+%d is a %s through rA = 0, an absolute address: %08X'
                       % (off, OP_DFORM[op], w))
    return bad


def strip_c_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    return re.sub(r'//[^\n]*', ' ', s)


def check_c(src, name='csrc/dsp_native.c'):
    """A literal inside firmware .text, in code or in a comment that names one."""
    bad = []
    for m in re.finditer(r'\b0[xX]([0-9A-Fa-f]+)[uU]?\b', strip_c_comments(src)):
        v = int(m.group(1), 16)
        if TEXT_LO <= v < TEXT_HI:
            bad.append('%s has 0x%08X, inside firmware .text' % (name, v))
    return bad


def c_literals(src):
    """Every integer literal in C, hex or decimal, comments stripped."""
    code = strip_c_comments(src)
    out = set()
    for m in re.finditer(r'\b0[xX]([0-9A-Fa-f]+)[uU]?\b', code):
        out.add(int(m.group(1), 16))
    for m in re.finditer(r'\b(\d+)[uU]?[lL]*\b', code):
        out.add(int(m.group(1)))
    return out


def lua_literals(src):
    """Every decimal literal in Lua, comments stripped. Lua 5.0.2 has no hex at all."""
    code = re.sub(r'--[^\n]*', ' ', src)
    return set(int(m.group(1)) for m in re.finditer(r'\b(\d+)\b', code))


def check_dram(files):
    """Every DRAM-range literal in the native path, against the stated list.

    This is the check the .text scan could not be: a heap bound is in DRAM, is page-aligned
    and so looks round, and nothing about it reads as an entry point. The only test that
    works is an explicit list with a reason beside each value.
    """
    bad, seen = [], {}
    for name, src, kind in files:
        lits = c_literals(src) if kind == 'c' else lua_literals(src)
        for v in sorted(lits):
            if not DRAM_FLOOR <= v < DRAM_END:
                continue
            if v in DRAM_ALLOW:
                seen.setdefault(v, []).append(name)
                continue
            bad.append('%s has %d (0x%08X), inside DRAM and not in DRAM_ALLOW. If it is not '
                       'an address, say what it is there; if it is one, derive it at runtime'
                       % (name, v, v))
    return bad, seen


def _round(v):
    """Round in some base a human writes in, so not an entry point.

    A power of two or a multiple of 1024 is a mask, a field width or a range bound. A
    multiple of 1000 is a quantity someone typed in decimal -- the seed readings this
    module writes into its code buffer are 1000000 and 3000000, which are arbitrary in
    hex. An entry point is arbitrary in both bases.
    """
    return (v & (v - 1)) == 0 or v % 1024 == 0 or v % 1000 == 0


def check_module(src):
    """A decimal literal in native_link.tsp that looks like an entry point."""
    bad, allowed = [], []
    # Comments carry addresses as hex for the reader; what executes is the decimal.
    code = re.sub(r'--[^\n]*', ' ', src)
    for m in re.finditer(r'\b(\d{5,})\b', code):
        v = int(m.group(1))
        if not TEXT_LO <= v < TEXT_HI:
            continue
        if _round(v):
            allowed.append(v)
        else:
            bad.append('tsp/native_link.tsp has %d (0x%08X), which is in firmware .text '
                       'and is not a round number' % (v, v))
    return bad, sorted(set(allowed))


def check_no_fw_table(src):
    if re.search(r'fftsa\.nl\.FW\s*=', src):
        return ['tsp/native_link.tsp has an nl.FW table: a version-to-address map is the '
                'thing this gate exists to prevent']
    return []


def run(module_src, c_src, bounds_src=''):
    bad = []
    bad += check_tramp(module_src)
    bad += check_c(c_src)
    # NOT the .text scan on the bounds header: declaring the .text window is what that file is
    # for, so TEXT_LO and TEXT_HI are in it by necessity. The DRAM list below covers it
    # instead, and covers it more strictly -- it has no round-number escape, so an arbitrary
    # .text address there fails just the same.
    mbad, allowed = check_module(module_src)
    bad += mbad
    bad += check_no_fw_table(module_src)
    dbad, seen = check_dram([('tsp/native_link.tsp', module_src, 'lua'),
                             ('csrc/dsp_native.c', c_src, 'c'),
                             ('csrc/dsp_native_bounds.h', bounds_src, 'c')])
    bad += dbad
    return bad, allowed, seen


def main():
    self_test = '--self-test' in sys.argv
    module_src = open(MODULE).read()
    c_src = open(CSRC).read()
    bounds_src = open(BOUNDS).read()

    if self_test:
        # Each mutation is one way an address comes back. A gate that cannot see them is
        # a gate that passes by not looking.
        cases = [
            ('an lis in the trampoline', 'addis/lis',
             lambda m, c: (re.sub(r"(fftsa\.nl\._TRAMP\s*=\s*')",
                                  r"\g<1>\\061\\128\\000\\033", m), c)),
            ('a lwz through rA = 0', 'rA = 0',
             lambda m, c: (re.sub(r"(fftsa\.nl\._TRAMP\s*=\s*')",
                                  r"\g<1>\\128\\096\\232\\104", m), c)),
            ('a call through CTR', 'CTR',
             lambda m, c: (re.sub(r"(fftsa\.nl\._TRAMP\s*=\s*')",
                                  r"\g<1>\\078\\128\\004\\033", m), c)),
            ('an address in dsp_native.c', 'dsp_native.c',
             lambda m, c: (m, c + '\nstatic const unsigned a = 0x0021E868u;\n')),
            ('an address in the module', '2223908',
             lambda m, c: (m + '\nfftsa.nl.PN = 2223908\n', c)),
            ('an nl.FW table', 'nl.FW table',
             lambda m, c: (m + "\nfftsa.nl.FW = { ['1.7.17az'] = 1 }\n", c)),
            # THE CASE THIS GATE USED TO MISS, both halves of it. A 6500 heap bound is in
            # DRAM, is 1024-aligned so it reads as round, and is nowhere near .text.
            ('a 6500 heap bound in the module', '16998400',
             lambda m, c: (m + '\nfftsa.nl.HEAP_LO = 16998400\n', c)),
            ('a 6500 heap bound in the backstop header', '226713600',
             lambda m, c: (m, c), '#define DSPN_HEAP_HI 0x0D836000U\n'),
            # And one that is not page-aligned either, so neither exclusion could hide it.
            ('an arbitrary DRAM address in dsp_native.c', '0x03B53038',
             lambda m, c: (m, c + '\nstatic const unsigned r = 0x03B53038u;\n')),
        ]
        ok = True
        # The mutations have to be the only finding, so a case cannot pass on a failure
        # that was already there.
        found, _, _ = run(module_src, c_src, bounds_src)
        if found:
            print('FAIL the tree itself does not pass: %s' % found[0])
            return 1
        for case in cases:
            name, want, mutate = case[0], case[1], case[2]
            extra = case[3] if len(case) > 3 else ''
            mm, cc = mutate(module_src, c_src)
            found, _, _ = run(mm, cc, bounds_src + extra)
            hit = [f for f in found if want in f]
            if hit:
                print('ok   caught %s: %s' % (name, hit[0]))
            else:
                print('FAIL missed %s (found %r)' % (name, found))
                ok = False
        return 0 if ok else 1

    bad, allowed, seen = run(module_src, c_src, bounds_src)
    data = tramp_bytes(module_src)
    for line in bad:
        print('FAIL ' + line)
    if bad:
        return 1
    print('no firmware addresses: %d trampoline instructions form none, neither C file has '
          'a .text literal, and the module has no version table'
          % ((len(data) - 8) // 4))
    if allowed:
        print('  in-range round numbers passed over: %s'
              % ', '.join('%d (0x%X)' % (v, v) for v in allowed))
    # Printed rather than counted, because the point of the list is that a reader can see
    # what the native path is allowed to know about memory and judge it.
    print('  %d DRAM-range literals, each stated:' % len(seen))
    for v in sorted(seen):
        print('    %-11d 0x%08X  %s' % (v, v, DRAM_ALLOW[v]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
