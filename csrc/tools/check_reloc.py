#!/usr/bin/env python3
"""Prove the relocation applier against the linker.

emit_reloc.py emits a table; fftsa.nl.relocate applies it on the instrument. Both could be
self-consistently wrong, and the failure mode is silent -- a constant read from the wrong
address returns a plausible number. So this uses an independent oracle: link the same
objects at the load address, and require the applier's output to be byte-identical to what
the linker produced.

If those agree for several bases, the applier does exactly what a linker would have done.

    python3 check_reloc.py --build /tmp/ppcbuild3 --objdir /tmp/ppcbuild3/CMakeFiles/dsp_native_elf.dir
"""

import argparse
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from emit_reloc import (Elf32BE, relocation_entries, pack_table,  # noqa: E402
                        KIND_WORD32, KIND_HALF_LO)

LD = '/opt/homebrew/bin/ld.lld'
OBJCOPY = '/opt/homebrew/opt/llvm/bin/llvm-objcopy'


def apply_table(image, table, base):
    """The Lua applier's arithmetic, in Python. Mirrors fftsa.nl.relocate exactly."""
    out = bytearray(image)
    off = 0
    while off < len(table):
        kind = table[off]
        field, target = struct.unpack_from('>II', table, off + 1)
        final = (base + target) & 0xFFFFFFFF
        if kind == KIND_WORD32:
            struct.pack_into('>I', out, field, final)
        elif kind == KIND_HALF_LO:
            struct.pack_into('>H', out, field, final & 0xFFFF)
        else:
            struct.pack_into('>H', out, field, ((final + 0x8000) >> 16) & 0xFFFF)
        off += 9
    return bytes(out)


def emit_table(elf_path):
    """The exact table emit_reloc.py writes. Imported, not reimplemented: two copies of
    the walk is how the field offset came to be wrong in both at once."""
    with open(elf_path, 'rb') as fh:
        elf = Elf32BE(fh.read())
    entries, _ = relocation_entries(elf)
    return pack_table(entries)


def link_at(base, objs, ldscript_src, workdir):
    """Link the same objects with the script's origin moved to `base`."""
    with open(ldscript_src) as fh:
        script = fh.read()
    assert '. = 0;' in script, 'linker script origin not found'
    moved = script.replace('. = 0;', '. = 0x%08X;' % base)
    sp = os.path.join(workdir, 'at_%08X.ld' % base)
    with open(sp, 'w') as fh:
        fh.write(moved)
    elf = os.path.join(workdir, 'at_%08X.elf' % base)
    bin_ = os.path.join(workdir, 'at_%08X.bin' % base)
    # Every flag the real link uses, --gc-sections and the dsp_native_sizes root included.
    # This is an oracle only while it links the same program: without the collector the
    # reference image carries the code the shipped one drops, and the comparison then fails
    # at the first address that moved rather than at a relocation fault.
    subprocess.run([LD, '-T', sp, '-e', 'dsp_native_run', '--no-dynamic-linker',
                    '--unresolved-symbols=report-all', '--emit-relocs',
                    '--gc-sections', '-u', 'dsp_native_sizes',
                    *objs, '-o', elf], check=True, capture_output=True)
    subprocess.run([OBJCOPY, '-O', 'binary', elf, bin_], check=True, capture_output=True)
    with open(bin_, 'rb') as fh:
        return fh.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--build', required=True)
    ap.add_argument('--objdir', required=True)
    args = ap.parse_args()

    objs = [os.path.join(args.objdir, o)
            for o in ('dsp_native.c.obj', 'dsp.c.obj')]
    for o in objs:
        if not os.path.exists(o):
            sys.exit('missing object: %s' % o)
    ldscript = os.path.join(HERE, '..', 'dsp_native.ld')

    base0 = os.path.join(args.build, 'dsp_native.bin')
    with open(base0, 'rb') as fh:
        image0 = fh.read()
    table = emit_table(os.path.join(args.build, 'dsp_native_elf'))
    print('image at base 0 : %d bytes' % len(image0))
    print('relocation table: %d entries' % (len(table) // 9))

    # Heap addresses a chunk payload has actually been seen at, plus a deliberately
    # awkward one whose low half is above 0x8000 so the ha carry is exercised.
    # The shipping applier lives in native_link.tsp. Running it needs Lua 5.0.2; when it
    # is absent the Python mirror below is still checked, and the gap is reported rather
    # than passed over.
    lua = os.path.expanduser('~/tmp/lua502/lua-5.0.2/bin/lua')
    module = os.path.join(HERE, '..', '..', 'tsp', 'native_link.tsp')
    driver = os.path.join(HERE, 'relocate_image.lua')
    have_lua = os.path.exists(lua) and os.path.exists(module)
    if not have_lua:
        print('note: Lua 5.0.2 not found, only the Python mirror is checked')

    table_path = os.path.join(args.build, 'reloc_table.bin')
    with open(table_path, 'wb') as fh:
        fh.write(table)

    bases = [0x03518420, 0x03520000, 0x0355A0C8, 0x0100FFF0 & ~0x1F, 0x0D80FFE0]
    fails = 0
    for b in bases:
        want = link_at(b, objs, ldscript, args.build)
        got = apply_table(image0, table, b)
        if have_lua:
            out = os.path.join(args.build, 'lua_%08X.bin' % b)
            r = subprocess.run([lua, driver, module, base0, table_path, '%08X' % b, out],
                               capture_output=True, text=True)
            if r.returncode != 0:
                print('FAIL base 0x%08X: the Lua applier failed: %s'
                      % (b, (r.stderr or '').strip()))
                fails += 1
                continue
            with open(out, 'rb') as fh:
                lua_got = fh.read()
            if lua_got != want:
                diffs = [i for i, (x, y) in enumerate(zip(want, lua_got)) if x != y]
                print('FAIL base 0x%08X: the shipping Lua applier differs from the linker '
                      'at %d bytes, first 0x%X' % (b, len(diffs), diffs[0] if diffs else -1))
                fails += 1
                continue
            if lua_got != got:
                print('FAIL base 0x%08X: Lua and the Python mirror disagree' % b)
                fails += 1
                continue
        if len(want) != len(got):
            print('FAIL base 0x%08X: length %d vs %d' % (b, len(got), len(want)))
            fails += 1
            continue
        if want == got:
            # How many bytes the relocation actually changed, so a table that patched
            # nothing cannot pass by accident.
            changed = sum(1 for x, y in zip(image0, got) if x != y)
            print('ok   base 0x%08X: %sbyte-identical to the linker (%d bytes differ '
                  'from the base-0 image)'
                  % (b, 'Lua and Python both ' if have_lua else '', changed))
            if b != 0 and changed == 0:
                print('     FAIL: nothing was patched, so this proves nothing')
                fails += 1
        else:
            diffs = [i for i, (x, y) in enumerate(zip(want, got)) if x != y]
            print('FAIL base 0x%08X: %d bytes differ, first at 0x%X (linker %02X, '
                  'applier %02X)' % (b, len(diffs), diffs[0],
                                     want[diffs[0]], got[diffs[0]]))
            fails += 1

    print()
    if fails:
        print('=== %d base(s) failed ===' % fails)
        sys.exit(1)
    print('=== the applier reproduces the linker exactly at every base ===')


if __name__ == '__main__':
    main()
