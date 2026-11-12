ENTRY(_start)
MEMORY { ram (rwx) : ORIGIN = 0, LENGTH = 64K }
PHDRS { code PT_LOAD FLAGS(5); data PT_LOAD FLAGS(6); }
SECTIONS {
    .text : { *(.text.start) *(.text*) } > ram :code
    .rodata : { *(.rodata*) *(.srodata*) } > ram :code
    .data : { *(.data*) *(.sdata*) } > ram :data
    .bss (NOLOAD) : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss*) *(.sbss*) *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > ram :data
    _stack_top = ORIGIN(ram) + LENGTH(ram);
    ASSERT(. < _stack_top - 4096, "Insufficient stack space")
}
