/*
 * dsp_native.ld -- linker script for the DMM6500 native DSP binary.
 *
 * Linked at address 0 so every relocation target doubles as an offset into the image;
 * csrc/tools/emit_reloc.py relies on that and refuses a .text anywhere else.
 *
 * .rodata and .data are part of the image and must be kept. dsp.c puts its float
 * constants in .rodata.cst4/.cst8, and its error-message table and the window
 * coefficient array dsp_wincos in .data.rel.ro. Discarding .data* drops dsp_wincos, and
 * the window then reads uninitialised memory -- a silent numerical failure rather than a
 * crash, which is why it is called out here.
 *
 * .bss holds the math function pointers dsp_native.c forwards through. It has no file
 * contents; the Lua loader zeroes [bss_lo, bss_hi), which emit_reloc.py reports.
 *
 * Usage:
 *   cmake -B build-ppc -DCMAKE_TOOLCHAIN_FILE=csrc/toolchain-ppc-clang.cmake \
 *         -DDSP_DST_NATIVE=ON
 *   cmake --build build-ppc --target dsp_native_bin
 *   # outputs: build-ppc/dsp_native.bin, build-ppc/dsp_native_reloc.lua
 */
SECTIONS {
    . = 0;
    .text   : { *(.text.dsp_native_run) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data   : { *(.data .data.* .sdata .sdata.*) }
    .bss    : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
