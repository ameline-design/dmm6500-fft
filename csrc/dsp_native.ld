/*
 * dsp_native.ld -- linker script for the DMM6500 native DSP binary.
 *
 * Places .native_header (dsp_native_params_addr) at the start, followed by
 * .text, .rodata and .data.  The result is a flat binary with:
 *
 *   [0x00]  dsp_native_params_addr  (4 bytes, initialised to 0)
 *   [0x04]  dsp_native_run entry point
 *   [...]   rest of .text from dsp.c, then .rodata, then .data
 *
 * The Lua startup code:
 *   1. ki.poke32(CODE_BASE + 0, params_addr)   -- write params address
 *   2. redirect ki.peek8 closure to CODE_BASE + 4  -- entry point
 *
 * Usage:
 *   powerpc-eabi-ld -T csrc/dsp_native.ld -r dsp_native.o dsp.o \
 *       -o dsp_native_linked.o
 *   powerpc-eabi-objcopy -O binary dsp_native_linked.o dsp_native.bin
 *
 * Use `powerpc-eabi-nm dsp_native_linked.o` to confirm:
 *   - dsp_native_params_addr at relative offset 0x0000
 *   - dsp_native_run at relative offset 0x0004
 */
SECTIONS {
    . = 0;
    .native_header : { *(.native_header) }
    .text          : { *(.text .text.*) }
    .rodata        : { *(.rodata .rodata.*) }
    .data          : { *(.data .data.*) }
    /DISCARD/      : { *(.comment) *(.note*) *(.eh_frame*) *(.ARM.extab*) *(.ARM.exidx*) }
}
