/* Program, constants and variables live in RAM 0x0000-0x5FFF (see soc.h). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    CODE (rwx) : ORIGIN = 0x0000, LENGTH = 0x6000
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > CODE
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > CODE
    .data : { *(.data .data.* .sdata .sdata.*) } > CODE
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > CODE
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
