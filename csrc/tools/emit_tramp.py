#!/usr/bin/env python3
"""Turn the assembled flush trampoline into the Lua byte literal fftsa.nl installs.

csrc/flush_tramp.S is position-independent and carries no relocations, so the bytes in
its .text are final and the object needs no link. This reads them out, checks the
properties the Lua loader depends on, and either prints the literal or verifies that the
one in tsp/native_link.tsp still matches the source.

    python3 csrc/tools/emit_tramp.py build-ppc/CMakeFiles/.../flush_tramp.S.o
    python3 csrc/tools/emit_tramp.py <obj> --check tsp/native_link.tsp

The checks are the whole point of the tool. A trampoline with a relocation in it would be
patched by nobody and would branch to offset zero of the heap; an entry symbol anywhere
but offset 0 would not be where the closure's f pointer is made to point; and a range
offset that disagrees with Lua would flush whatever the two words happen to hold.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emit_reloc import Elf32BE, SHT_SYMTAB          # noqa: E402

SHT_RELA = 4
SHT_REL = 9

# Offset 0 is where ki.peek8's f pointer is made to point, and nl.flush writes the range
# words relative to the same address.
ENTRY_SYM = "dspn_flush_tramp"
RANGE_SYM = "dspn_flush_range"
RANGE_WORDS = 2


def lua_literal(data):
    return "'" + "".join("\\%03d" % b for b in data) + "'"


def read_tramp(path):
    with open(path, "rb") as fh:
        elf = Elf32BE(fh.read())
    text = elf.by_name(".text")
    if text is None or text["size"] == 0:
        sys.exit("%s has no .text" % path)
    for s in elf.sections:
        if s["type"] in (SHT_RELA, SHT_REL) and s["size"] > 0:
            sys.exit("%s carries relocations in %s: the trampoline has to be complete as "
                     "assembled, because nothing patches it" % (path, s["name"]))
    entry = elf.symbol_named(ENTRY_SYM)
    rng = elf.symbol_named(RANGE_SYM)
    if entry is None or rng is None:
        sys.exit("%s is missing %s or %s" % (path, ENTRY_SYM, RANGE_SYM))
    if entry != 0:
        sys.exit("%s is at offset %d, not 0" % (ENTRY_SYM, entry))
    if rng + 4 * RANGE_WORDS > text["size"]:
        sys.exit("the range words at offset %d do not fit the %d-byte trampoline"
                 % (rng, text["size"]))
    blob = elf.blob[text["offset"]:text["offset"] + text["size"]]
    if blob[rng:rng + 4 * RANGE_WORDS] != b"\0" * (4 * RANGE_WORDS):
        sys.exit("the range words are not zero in the assembled bytes")
    return blob, rng


def shipped(path):
    """The literal and the range offset as tsp/native_link.tsp has them."""
    src = open(path).read()
    m = re.search(r"fftsa\.nl\._TRAMP\s*=\s*'((?:\\\d{3})+)'", src)
    if m is None:
        sys.exit("no fftsa.nl._TRAMP literal in %s" % path)
    data = bytes(int(v) for v in re.findall(r"\\(\d{3})", m.group(1)))
    m = re.search(r"fftsa\.nl\.TRAMP_RANGE\s*=\s*(\d+)", src)
    if m is None:
        sys.exit("no fftsa.nl.TRAMP_RANGE in %s" % path)
    return data, int(m.group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("obj", help="the assembled flush_tramp.S object")
    ap.add_argument("--check", metavar="TSP",
                    help="compare against the literal in this file instead of printing")
    a = ap.parse_args()

    blob, rng = read_tramp(a.obj)
    if a.check is None:
        print("-- %d bytes, assembled from csrc/flush_tramp.S" % len(blob))
        print("fftsa.nl._TRAMP = %s" % lua_literal(blob))
        print("fftsa.nl.TRAMP_RANGE = %d" % rng)
        return 0

    have, have_rng = shipped(a.check)
    bad = []
    if have != blob:
        if len(have) != len(blob):
            bad.append("the literal is %d bytes, the source assembles to %d"
                       % (len(have), len(blob)))
        else:
            first = next(i for i in range(len(blob)) if blob[i] != have[i])
            bad.append("the literal differs from the source at byte %d: %d, not %d"
                       % (first, have[first], blob[first]))
    if have_rng != rng:
        bad.append("TRAMP_RANGE is %d, the source puts the range words at %d"
                   % (have_rng, rng))
    if bad:
        for line in bad:
            print("FAIL " + line)
        print("Regenerate with: python3 csrc/tools/emit_tramp.py %s" % a.obj)
        return 1
    print("ok  %s matches csrc/flush_tramp.S: %d bytes, range at %d"
          % (a.check, len(blob), rng))
    return 0


if __name__ == "__main__":
    sys.exit(main())
