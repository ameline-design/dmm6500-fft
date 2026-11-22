/*
 * Link at zero so relocation targets are image offsets. Keep constants and initialized data;
 * the loader zeroes the BSS range exported with the image.
 */
SECTIONS {
    . = 0;
    .text   : { *(.text.dsp_native_run) *(.text .text.*) }
    .rodata : { *(.rodata .rodata.*) }
    .data   : { *(.data .data.* .sdata .sdata.*) }
    .bss    : { *(.bss .bss.* .sbss .sbss.*) *(COMMON) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
