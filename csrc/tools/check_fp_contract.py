#!/usr/bin/env python3
"""Gate: the graph ring fill in the built image holds no fused multiply-add.

The image is built with -ffp-contract=fast, which the target wants: the e300c4 retires a
fused multiply-add a cycle, it is the butterfly's inner operation, and fusing is strictly
more accurate -- one rounding instead of two. In dsp.c that is free.

In dspn_px_fill it is not free, because that loop has to agree with a Lua reimplementation of
itself. It writes a row number per ring record; the Lua writer in tsp/native_link.tsp writes
the same row the same way, and a frame picks one writer or the other -- the image's normally,
Lua's on any frame that re-pointed the frequency series, because only Lua's lays down the x
fields. Lua rounds the product and then adds the intercept, having no other option. Fused,
the image does it in one rounding, and where the sum lands on a half the two floors differ by
a whole row:

    ay = -7.7603470944719, db = 8.477140426635742, by = 231.28555207927295
    the product rounded, then added  ->  166.0               -> row 166
    fused, one rounding              ->  165.99999999999997  -> row 165

dspn_px_row defeats it with a volatile, which the standard guarantees and no contraction flag
can take away.

THE HOST SUITE CANNOT GATE THAT, and it would be worth nothing to pretend otherwise.
csrc/test/dsp_native_px_test.cc compiles the same header with -ffp-contract=fast, and clang on
this host declines to fuse across the statement boundary anyway -- so deleting the volatile
passes there and still emits fmadd on PowerPC. Measured both ways: with the volatile,
dspn_px_fill holds no fused multiply-add; written as one expression it holds one. The built
image is the only place the question can be settled, so this reads the built image.

dspn_px_fill is kept out of line for exactly this reason, so there is a symbol to disassemble.
A build that inlined it anyway fails here rather than passing silently.

    python3 -I csrc/tools/check_fp_contract.py --build build-ppc
    python3 -I csrc/tools/check_fp_contract.py --build build-ppc --self-test

The build runs it with --elf, which it already knows; --build is for running it by hand.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SYMBOL = 'dspn_px_fill'

# PowerPC's fused multiply-adds: single and double, with and without the negation.
FUSED_RE = re.compile(r'^\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} ){4}\s*'
                      r'(fn?m(?:add|sub)s?)\s', re.M)


def find_objdump():
    for base in ('/opt/homebrew/opt/llvm/bin', '/usr/local/opt/llvm/bin'):
        p = os.path.join(base, 'llvm-objdump')
        if os.path.exists(p):
            return p
    return shutil.which('llvm-objdump') or shutil.which('objdump')


def disassemble(elf, symbol):
    od = find_objdump()
    if od is None:
        raise SystemExit('no objdump found; this gate needs the LLVM one the build uses')
    out = subprocess.run([od, '-d', '--disassemble-symbols=' + symbol, elf],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit('%s failed on %s: %s'
                         % (os.path.basename(od), elf, out.stderr.strip()[:200]))
    return out.stdout


def fused_sites(text):
    return [(int(a, 16), op) for a, op in FUSED_RE.findall(text)]


def self_test(elf):
    rc = 0
    # The regression itself: a fused multiply-add anywhere in the fill must fail.
    body = disassemble(elf, SYMBOL)
    if not fused_sites(body + '    12f0: fc 7f f0 fa  \tfmadd 3, 31, 3, 30\n'):
        print('  MISSED: an added fused multiply-add was not seen')
        rc = 1
    else:
        print('  caught: a fused multiply-add in the fill')
    # And the pattern must not read an ordinary multiply or add as a fused one, or the gate
    # would fail on the very instructions the fix produces.
    plain = ('    12f0: fc 42 00 72  \tfmul 2, 2, 1\n'
             '    12f4: fc 42 18 2a  \tfadd 2, 2, 3\n'
             '    12f8: fc 00 10 1e  \tfctiwz 0, 2\n')
    if fused_sites(plain):
        print('  MISSED: fmul, fadd or fctiwz read as fused')
        rc = 1
    else:
        print('  caught: fmul, fadd and fctiwz are not fused multiply-adds')
    # An absent symbol has to fail rather than read as a clean empty function, which is
    # how a build that inlined the fill would otherwise pass.
    absent = disassemble(elf, 'dspn_no_such_symbol_here')
    if '<dspn_no_such_symbol_here>' in absent:
        print('  MISSED: a symbol that does not exist disassembled anyway')
        rc = 1
    else:
        print('  caught: an absent symbol is not a clean function')
    print('self-test %s' % ('passed' if rc == 0 else 'FAILED'))
    return rc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', default='build-ppc',
                    help='the target build directory holding dsp_native_elf')
    ap.add_argument('--elf', default=None,
                    help='the linked image, when the build knows its path already')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args()

    elf = args.elf or os.path.join(ROOT, args.build, 'dsp_native_elf')
    if not os.path.exists(elf):
        print('  %s is not built; run cmake --build %s --target dsp_native_bin'
              % (elf, args.build))
        return 1

    if args.self_test:
        return self_test(elf)

    body = disassemble(elf, SYMBOL)
    # An empty disassembly means the symbol is gone -- inlined, renamed or optimised away --
    # and an absent function reads exactly like a clean one, so it is a failure.
    if '<%s>' % SYMBOL not in body:
        print('  %s is not a symbol in the image. It is kept out of line so this gate has'
              % SYMBOL)
        print('  something to read; inlined, the ring fill\'s arithmetic is unverifiable and')
        print('  a fused multiply-add in it would draw a row the Lua writer never draws.')
        return 1

    sites = fused_sites(body)
    if sites:
        print('  %s holds %d fused multiply-add(s):' % (SYMBOL, len(sites)))
        for addr, op in sites:
            print('    0x%04X  %s' % (addr, op))
        print('  dspn_px_row must round the product before adding the intercept -- the')
        print('  volatile in it is what does that -- or the image and the Lua writer draw')
        print('  different rows for the same spectrum.')
        return 1

    ninstr = len(re.findall(r'^\s*[0-9a-f]+:\s+(?:[0-9a-f]{2} ){4}', body, re.M))
    print('%s: %d instructions, no fused multiply-add' % (SYMBOL, ninstr))
    return 0


if __name__ == '__main__':
    sys.exit(main())
