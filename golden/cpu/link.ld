ENTRY(_start)
MEMORY { ram (rwx) : ORIGIN = 0, LENGTH = 64K }
SECTIONS {
    .text : { *(.text.start) *(.text*) } > ram
    .rodata : { *(.rodata*) *(.srodata*) } > ram
    .data : { *(.data*) *(.sdata*) } > ram
    .bss : { *(.bss*) *(.sbss*) *(COMMON) } > ram
    _stack_top = ORIGIN(ram) + LENGTH(ram);
    ASSERT(. < _stack_top - 4096, "Insufficient stack space")
}
