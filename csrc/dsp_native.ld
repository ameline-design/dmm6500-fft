/*
 * dsp_native.ld -- linker script for the DMM6500 native DSP binary.
 *
 * The binary is purely .text + .rodata; there are no globals so there is no
 * .data section.  dsp_native_run is at offset 0, which is CODE_BASE at runtime.
 *
 * The Lua startup redirects ki.peek8 to CODE_BASE and calls
 *   ki.peek8(params_addr_hex)
 * where params_addr_hex is the address of the dsp_native_params struct.
 *
 * Usage:
 *   cmake -B build-ppc -DCMAKE_TOOLCHAIN_FILE=csrc/toolchain-ppc-clang.cmake \
 *         -DDSP_DST_NATIVE=ON
 *   cmake --build build-ppc --target dsp_native_bin
 *   # output: build-ppc/dsp_native.bin
 *
 * Verify entry offset (should be 0x0000):
 *   llvm-nm build-ppc/dsp_native_elf | grep dsp_native_run
 */
SECTIONS {
    . = 0;
    .text   : { *(.text.dsp_native_run) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    /DISCARD/ : { *(.data*) *(.bss*) *(.comment) *(.note*) *(.eh_frame*) }
}
