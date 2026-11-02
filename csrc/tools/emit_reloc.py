#!/usr/bin/env python3
"""Emit the flat binary and its relocation table from the linked PPC ELF.

The binary lands at a heap address chosen at runtime, but on PPC32 every data reference
is an absolute address fixed at link time (`lis rX,hi` + `lfd fY,lo(rX)`). clang's PPC
backend has no small-data addressing (-msdata and -G are both rejected for this triple),
so the references have to be patched for the real load address instead.

This reads the relocations the linker kept with --emit-relocs and writes two files:

  <stem>.bin        the flat image, exactly as it is loaded
  <stem>_reloc.lua  `fftsa.nl._DSP_RELOC = '...'`, the table nl.relocate applies

Table encoding, 9 bytes per entry, big-endian:

  [0]     relocation kind: 1 = word32, 2 = half-lo, 3 = half-ha
  [1..4]  offset of the field within the image
  [5..8]  target address at link time, i.e. symbol value plus addend

nl.relocate turns each target into `target + code_base` and writes the field. Nothing
depends on what the linker already wrote into the field, so a relocation is idempotent
and the image can be re-patched for a different load address.

Usage:
  python3 emit_reloc.py build-ppc/dsp_native_elf --stem build-ppc/dsp_native
"""

import argparse
import struct
import sys

# ELF constants.
SHT_SYMTAB = 2
SHT_RELA = 4

# PowerPC relocation types we understand.
R_PPC_ADDR32 = 1
R_PPC_ADDR16 = 3
R_PPC_ADDR16_LO = 4
R_PPC_ADDR16_HI = 5
R_PPC_ADDR16_HA = 6

# PC-relative: correct wherever the image lands, nothing to patch.
R_PPC_REL24 = 10
R_PPC_REL14 = 11
R_PPC_REL32 = 26

KIND_WORD32 = 1
KIND_HALF_LO = 2
KIND_HALF_HA = 3

# ADDR16_HI is the plain high half with no carry correction. clang pairs HA with LO, so
# HI should not appear; if it does, treating it as HA would be wrong by one in the top
# half whenever the low half is negative, so it is refused rather than guessed at.
PATCHABLE = {
    R_PPC_ADDR32: KIND_WORD32,
    R_PPC_ADDR16_LO: KIND_HALF_LO,
    R_PPC_ADDR16_HA: KIND_HALF_HA,
}
PC_RELATIVE = {R_PPC_REL24, R_PPC_REL14, R_PPC_REL32}


class Elf32BE:
    """Just enough big-endian ELF32 to read section headers, symbols and relocations."""

    def __init__(self, blob):
        if blob[:4] != b"\x7fELF":
            raise ValueError("not an ELF file")
        if blob[4] != 1:
            raise ValueError("not ELF32")
        if blob[5] != 2:
            raise ValueError("not big-endian; the target is big-endian PowerPC")
        self.blob = blob
        e_shoff, = struct.unpack_from(">I", blob, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(">HHH", blob, 0x2E)
        self.sections = []
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            (sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size,
             sh_link, sh_info, sh_addralign, sh_entsize) = struct.unpack_from(
                ">IIIIIIIIII", blob, off)
            self.sections.append({
                "name_off": sh_name, "type": sh_type, "flags": sh_flags,
                "addr": sh_addr, "offset": sh_offset, "size": sh_size,
                "link": sh_link, "info": sh_info, "align": sh_addralign,
                "entsize": sh_entsize, "index": i,
            })
        strtab = self.sections[e_shstrndx]
        names = blob[strtab["offset"]:strtab["offset"] + strtab["size"]]
        for s in self.sections:
            end = names.find(b"\0", s["name_off"])
            s["name"] = names[s["name_off"]:end].decode("ascii", "replace")

    def by_name(self, name):
        for s in self.sections:
            if s["name"] == name:
                return s
        return None

    def symbol_named(self, name):
        """The address of a global symbol, or None. Needs .strtab for the symbol table."""
        symtab = None
        for s in self.sections:
            if s["type"] == SHT_SYMTAB:
                symtab = s
                break
        if symtab is None:
            return None
        strtab = self.sections[symtab["link"]]
        names = self.blob[strtab["offset"]:strtab["offset"] + strtab["size"]]
        for sym in self.symbols(symtab):
            end = names.find(b"\0", sym["name_off"])
            if names[sym["name_off"]:end].decode("ascii", "replace") == name:
                return sym["value"]
        return None

    def read_at(self, addr, nbytes):
        """Bytes at a virtual address, from whichever allocated section holds it."""
        for s in self.sections:
            if not (s["flags"] & 0x2) or s["type"] == 8 or s["size"] == 0:
                continue
            if s["addr"] <= addr and addr + nbytes <= s["addr"] + s["size"]:
                off = s["offset"] + (addr - s["addr"])
                return self.blob[off:off + nbytes]
        return None

    def symbols(self, symtab):
        """Symbol values for a SHT_SYMTAB section, indexed as the relocations index them."""
        out = []
        data = self.blob[symtab["offset"]:symtab["offset"] + symtab["size"]]
        for off in range(0, len(data), 16):
            st_name, st_value, st_size, st_info, st_other, st_shndx = \
                struct.unpack_from(">IIIBBH", data, off)
            out.append({"name_off": st_name, "value": st_value,
                        "shndx": st_shndx, "info": st_info})
        return out

    def relocations(self):
        """Every SHT_RELA entry, as (section_name, r_offset, r_type, sym_index, addend)."""
        for s in self.sections:
            if s["type"] != SHT_RELA:
                continue
            data = self.blob[s["offset"]:s["offset"] + s["size"]]
            for off in range(0, len(data), 12):
                r_offset, r_info, r_addend = struct.unpack_from(">IIi", data, off)
                yield (s["name"], r_offset, r_info & 0xFF, r_info >> 8, r_addend)


def relocation_entries(elf):
    """(kind, field offset, target) for every relocation that needs patching.

    Shared with tools/check_reloc.py, which validates the result against the linker: two
    copies of this walk is how the field offset came to be wrong in both at once.

    r_offset points **at the 16-bit field**, not at the start of the instruction, for the
    ADDR16 family. For the `lis r3,0` at 0x104 whose immediate lives at 0x106, ld.lld
    emits r_offset = 0x106. Adding 2 to reach the immediate lands on the next
    instruction's opcode instead, which is what the first version of this did.
    """
    symtab = None
    for s in elf.sections:
        if s["type"] == SHT_SYMTAB:
            symtab = s
            break
    if symtab is None:
        raise ValueError("no symbol table: link with --emit-relocs and do not strip")
    syms = elf.symbols(symtab)

    entries = []
    skipped = 0
    for sec_name, r_offset, r_type, r_sym, r_addend in elf.relocations():
        if r_type in PC_RELATIVE:
            skipped += 1
            continue
        kind = PATCHABLE.get(r_type)
        if kind is None:
            raise ValueError(
                "relocation type %d in %s at 0x%X is not handled; a missed relocation "
                "reads the wrong address silently, so this is fatal"
                % (r_type, sec_name, r_offset))
        if r_sym >= len(syms):
            raise ValueError("relocation in %s references symbol %d, past the symbol table"
                             % (sec_name, r_sym))
        target = (syms[r_sym]["value"] + r_addend) & 0xFFFFFFFF
        entries.append((kind, r_offset, target))

    entries.sort(key=lambda e: e[1])
    return entries, skipped


def pack_table(entries):
    """The on-wire table: 9 bytes per entry, big-endian."""
    table = bytearray()
    for kind, field, target in entries:
        table.append(kind)
        table.extend(struct.pack(">II", field, target))
    return bytes(table)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf", help="linked ELF, built with --emit-relocs")
    ap.add_argument("--stem", required=True, help="output path stem")
    ap.add_argument("--var", default="fftsa.nl._DSP_RELOC",
                    help="Lua variable to assign the table to")
    args = ap.parse_args()

    with open(args.elf, "rb") as fh:
        elf = Elf32BE(fh.read())

    text = elf.by_name(".text")
    if text is None:
        sys.exit("no .text section")
    if text["addr"] != 0:
        sys.exit(".text must be linked at address 0; check dsp_native.ld "
                 "(got 0x%08X)" % text["addr"])

    try:
        entries, skipped = relocation_entries(elf)
    except ValueError as exc:
        sys.exit(str(exc))

    # The flat image: every allocated section with contents, in address order. .bss has
    # no contents and is zeroed by the loader, so it is not in the image.
    alloc = [s for s in elf.sections
             if (s["flags"] & 0x2) and s["type"] != 8 and s["size"] > 0]
    alloc.sort(key=lambda s: s["addr"])
    if not alloc:
        sys.exit("no allocated sections with contents")
    image = bytearray()
    for s in alloc:
        if s["addr"] < len(image):
            sys.exit("section %s at 0x%08X overlaps the image built so far"
                     % (s["name"], s["addr"]))
        image.extend(b"\0" * (s["addr"] - len(image)))
        image.extend(elf.blob[s["offset"]:s["offset"] + s["size"]])

    # .bss has to be inside the region the loader reserves, or zeroing it would land
    # outside the buffer the Lua side sized.
    bss = elf.by_name(".bss")
    bss_lo = bss["addr"] if bss is not None and bss["size"] > 0 else 0
    bss_hi = bss_lo + (bss["size"] if bss is not None else 0)

    for kind, field, target in entries:
        if field + (4 if kind == KIND_WORD32 else 2) > len(image):
            sys.exit("relocation field at 0x%X is past the end of the image" % field)

    table = pack_table(entries)

    bin_path = args.stem + ".bin"
    lua_path = args.stem + "_reloc.lua"
    with open(bin_path, "wb") as fh:
        fh.write(image)

    def lua_literal(data):
        return "'" + "".join("\\%03d" % b for b in data) + "'"

    # Struct sizes read out of the image the target compiler produced. A 32-bit
    # big-endian PowerPC has 4-byte pointers, so sizeof(dsp_plan) is not what a 64-bit
    # host reports and the Lua side must not carry its own copy of the figure.
    sizes_addr = elf.symbol_named("dsp_native_sizes")
    if sizes_addr is None:
        sys.exit("dsp_native_sizes not found: the Lua side needs the target's struct sizes")
    raw = elf.read_at(sizes_addr, 32)
    if raw is None or len(raw) != 32:
        sys.exit("dsp_native_sizes at 0x%08X is not inside an allocated section" % sizes_addr)
    (plan_sz, params_sz, real_sz, align, heap_lo, heap_hi,
     res_peaks, res_doubles) = struct.unpack(">IIIIIIII", raw)
    if 0 in (plan_sz, params_sz, real_sz, align, heap_lo, heap_hi,
             res_peaks, res_doubles):
        sys.exit("dsp_native_sizes reads as zeros; it is a tentative definition in .bss "
                 "rather than an initialised one in .rodata")
    if heap_lo >= heap_hi:
        sys.exit("dsp_native_sizes heap bounds are inverted: 0x%08X >= 0x%08X"
                 % (heap_lo, heap_hi))

    with open(lua_path, "w") as fh:
        fh.write("-- Generated by csrc/tools/emit_reloc.py; do not edit.\n")
        fh.write("-- %d relocations over a %d-byte image.\n" % (len(entries), len(image)))
        fh.write("%s = %s\n" % (args.var, lua_literal(table)))
        fh.write("%s_BSS_LO = %d\n" % (args.var, bss_lo))
        fh.write("%s_BSS_HI = %d\n" % (args.var, bss_hi))
        fh.write("-- struct sizes from the target compiler, not from a host build\n")
        fh.write("fftsa.nl.SIZEOF_PLAN = %d\n" % plan_sz)
        fh.write("fftsa.nl.SIZEOF_PARAMS = %d\n" % params_sz)
        fh.write("fftsa.nl.SIZEOF_REAL = %d\n" % real_sz)
        fh.write("fftsa.nl.DSP_ALIGN = %d\n" % align)
        fh.write("-- heap bounds from dsp_native_bounds.h, so Lua holds no second copy\n")
        fh.write("fftsa.nl.HEAP_LO = %d\n" % heap_lo)
        fh.write("fftsa.nl.HEAP_HI = %d\n" % heap_hi)
        fh.write("-- results block: Lua reserves the memory and decodes what lands in it\n")
        fh.write("fftsa.nl.RES_PEAKS = %d\n" % res_peaks)
        fh.write("fftsa.nl.RES_DOUBLES = %d\n" % res_doubles)

    print("image      %s  %d bytes" % (bin_path, len(image)))
    print("relocs     %s  %d entries, %d bytes"
          % (lua_path, len(entries), len(table)))
    print("pc-relative skipped: %d (correct at any load address)" % skipped)
    print("bss        0x%08X..0x%08X (%d bytes, zeroed by the loader)"
          % (bss_lo, bss_hi, bss_hi - bss_lo))
    print("target     sizeof(dsp_plan)=%d  sizeof(params)=%d  sizeof(dsp_real)=%d  align=%d"
          % (plan_sz, params_sz, real_sz, align))
    kinds = {}
    for kind, _, _ in entries:
        kinds[kind] = kinds.get(kind, 0) + 1
    names = {KIND_WORD32: "word32", KIND_HALF_LO: "half-lo", KIND_HALF_HA: "half-ha"}
    for k in sorted(kinds):
        print("  %-8s %d" % (names[k], kinds[k]))


if __name__ == "__main__":
    main()
