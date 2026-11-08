#!/usr/bin/env python3
"""Does the app's firmware strategy hold on this image? One command per version.

Two things in the tree depend on firmware layout, and both are supposed to be
model-independent and build-independent. This checks each claim directly against an image,
so a new version is a measurement rather than an opinion.

CLAIM 1, resolve_math. Every Lua math wrapper is the same shape: ten calls into the VM, the
library function if it has one, then lua_pushnumber. math.abs, math.deg and math.rad call no
library function, so every target they reach is VM glue by construction. Therefore: take the
targets of the wrappers that make ELEVEN calls as the glue set, and every wrapper that makes
TWELVE must have exactly ONE target outside it. That is checkable with no symbols -- the
wrappers are found by shape, and the claim is about the relationship between them.

CLAIM 2, the compiled bounds. tsp/native_link.tsp carries TEXT_LO/TEXT_HI for the ki.peek8
pointer, and csrc/dsp_native_bounds.h compiles a .text window and a HEAP window into the
image, which dspn_write_ok uses as the backstop on every write. Those have to contain the
real sections of whatever model runs the app, or pointers are refused at MODE_INIT with
rc=-11.

A .text run address in a flattened image is also its file offset, so the base is 0.

    python3 -u -I tools/check_fw_strategy.py /tmp/fw1717a/flash17.bin /tmp/fw7510/flash7510.bin
    python3 -u -I tools/check_fw_strategy.py --flatten ~/Downloads/.../main.x
"""
import argparse
import os
import struct
import subprocess
import sys

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
FW = os.path.join(SIB, 'notes', 'firmware')
sys.path.insert(0, FW)
import sections                                                          # noqa: E402

BLR = 0x4E800020
# What the tree compiles in, and what this is checking those sections against.
TEXT_LO, TEXT_HI = 0x00004000, 0x00527000          # tsp/native_link.tsp
DRAM_LO, DRAM_END = 0x00003000, 0x10000000         # csrc/dsp_native_bounds.h
OLD_FLOOR = 0x00400000                             # the scan floor 8.44 removed

WRAP_WORDS = 91          # a wrapper is 0x16C bytes; its blr sits at word 89
GLUE_MIN = 6


def flatten(src):
    out = '/tmp/fwcheck/%s.bin' % os.path.basename(src).replace('.', '_')
    os.makedirs('/tmp/fwcheck', exist_ok=True)
    subprocess.run([sys.executable, '-I', os.path.join(FW, 'srflat.py'), src, out],
                   check=True, capture_output=True)
    return out


def words(img):
    n = len(img) // 4
    return struct.unpack('>%dI' % n, img[:n * 4])


def bl_targets(w, base, i0):
    """Every bl target in one wrapper body, stopping at its blr. Refuses bla: the AA bit
    makes the field absolute, and reading it as a displacement is how a wrong entry gets
    picked up."""
    out = []
    for k in range(1, WRAP_WORDS):
        n = w[i0 + k]
        if (n >> 26) == 18 and (n & 3) == 1:
            r = (n >> 2) & 0xFFFFFF
            if r >= 0x800000:
                r -= 0x1000000
            out.append((base + (i0 + k) * 4 + r * 4) & 0xFFFFFFFF)
        if n == BLR:
            break
    return out


WRAP_PITCH = 0x16C       # every one-argument wrapper is exactly this long
RUN_MIN = 6              # a run shorter than this is a coincidence, not the math block


def find_wrappers(w, lo, hi):
    """The Lua math block, by its shape AND its spacing.

    Shape alone is far too loose: a blr at word 89 with eleven or twelve bl matches about
    200 unrelated functions in .text, and intersecting their target sets is empty by
    construction. What identifies the block is that its one-argument wrappers are
    CONTIGUOUS at a pitch of exactly 0x16C -- 0x000CDE9C, 0x000CE008, 0x000CE174 on the
    7510, 0x002026F8 upward on the 6500. So collect the shape matches, then keep only the
    longest run of them spaced at that pitch.
    """
    hits = []
    for i in range(lo // 4, min(hi // 4, len(w)) - WRAP_WORDS):
        if w[i + 89] != BLR:
            continue
        ts = bl_targets(w, 0, i)
        if len(ts) in (11, 12):
            hits.append((i * 4, ts))
    byaddr = dict(hits)
    best = []
    for a, _ in hits:
        if a - WRAP_PITCH in byaddr:
            continue                         # not the start of a run
        run, k = [], a
        while k in byaddr:
            run.append((k, byaddr[k]))
            k += WRAP_PITCH
        if len(run) > len(best):
            best = run
    if len(best) < RUN_MIN:
        return []
    print('  math block: %d wrappers at pitch 0x%X, %08X..%08X'
          % (len(best), WRAP_PITCH, best[0][0], best[-1][0]))
    return best


def check(path):
    print('=' * 78)
    print(path)
    try:
        named = {}
        for addr, size, flags, twin, name in sections.walk(path):
            if size and name not in named:
                named[name] = (addr, addr + size)
    except Exception as e:
        print('  section table unreadable: %s' % e)
        return False
    text = named.get('.text')
    heap = named.get('.heap')
    print('  .text %08X..%08X    .heap %08X..%08X'
          % (text[0], text[1], heap[0], heap[1]))

    ok = True
    # CLAIM 2 first: it is cheap and it is the one that bites intermittently.
    t_in = text[0] >= TEXT_LO and text[1] <= TEXT_HI
    print('  text inside the compiled %08X..%08X : %s' % (TEXT_LO, TEXT_HI,
                                                          'yes' if t_in else 'NO'))
    if not t_in:
        print('    a resolved libm entry outside this is refused by dspn_text_ok, so the'
              ' native path is lost')
        ok = False

    # The writable backstop is DRAM less the vectors less .text, so the whole heap has to
    # sit above TEXT_HI. That is the one section relation the backstop depends on, and it
    # is the reason no heap figure is compiled in: a heap bound would have to be one of
    # these two maps and would refuse the other.
    h_in = heap[0] >= max(DRAM_LO, TEXT_HI) and heap[1] <= DRAM_END
    print('  heap above TEXT_HI and inside DRAM             : %s   (floor is %.1f MB clear)'
          % ('yes' if h_in else 'NO', (heap[0] - TEXT_HI) / 1048576.0))
    if not h_in:
        print('    part of this heap is refused by the compiled backstop, so the app works')
        print('    or fails by where the allocator lands a buffer')
        ok = False
    print('  whole .text below the old %08X floor      : %s'
          % (OLD_FLOOR, 'YES, so 8.44 is required here' if text[1] <= OLD_FLOOR else 'no'))

    # CLAIM 1.
    with open(path, 'rb') as fh:
        img = fh.read()
    w = words(img)
    wraps = find_wrappers(w, text[0], text[1])
    eleven = [(a, t) for a, t in wraps if len(t) == 11]
    twelve = [(a, t) for a, t in wraps if len(t) == 12]
    print('  wrappers by shape: %d with 11 bl, %d with 12' % (len(eleven), len(twelve)))
    if not eleven or not twelve:
        print('  CLAIM 1 NOT TESTABLE on this image: no wrapper pair of both shapes found')
        return ok

    # The glue set is the intersection of the eleven-call wrappers' targets: a target one of
    # them reaches and another does not is not shared glue, and taking the union instead
    # would swallow a library entry.
    glue = set(eleven[0][1])
    for _, t in eleven[1:]:
        glue &= set(t)
    print('  glue set from the 11-bl wrappers: %d targets' % len(glue))
    if len(glue) < GLUE_MIN:
        print('  CLAIM 1 FAILS: glue set under the %d the module requires' % GLUE_MIN)
        return False

    bad, entries = 0, []
    for a, t in twelve:
        left = [x for x in t if x not in glue]
        if len(left) != 1:
            bad += 1
        else:
            entries.append(left[0])
    print('  12-bl wrappers with exactly one target outside the glue set: %d of %d'
          % (len(twelve) - bad, len(twelve)))
    if bad:
        print('  CLAIM 1 FAILS on %d wrapper(s)' % bad)
        ok = False
    if entries:
        lo, hi = min(entries), max(entries)
        print('  resolved entries span %08X..%08X, %d distinct'
              % (lo, hi, len(set(entries))))
        if len(set(entries)) != len(entries):
            print('  CLAIM 1 FAILS: two wrappers resolve to one address')
            ok = False
        if not (lo >= TEXT_LO and hi < TEXT_HI):
            print('  CLAIM 1 FAILS: an entry is outside TEXT_LO..TEXT_HI, so resolve_math'
                  ' refuses it')
            ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('images', nargs='+')
    ap.add_argument('--flatten', action='store_true',
                    help='the arguments are S-record main.x files, not flat images')
    a = ap.parse_args()
    allok = True
    for p in a.images:
        path = flatten(p) if a.flatten else p
        allok = check(path) and allok
    print('=' * 78)
    print('both claims hold on every image' if allok
          else 'AT LEAST ONE CLAIM FAILS -- see above')
    sys.exit(0 if allok else 1)


if __name__ == '__main__':
    main()
