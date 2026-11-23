/* User programs (fpga/user/README.md): code, constants and globals in
   0x0000-0xDFFF, stack 0xE000-0xFFFF (start.S). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    CODE (rwx) : ORIGIN = 0x0000, LENGTH = 0xE000
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
