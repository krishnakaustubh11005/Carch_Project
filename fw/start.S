// Reset and IRQ entry for PicoRV32 (PROGADDR_RESET = 0, PROGADDR_IRQ = 0x10).
// Sets the stack, clears .bss, runs main and writes its return value (the
// final result code) to the result port, then stops.
    .section .text.start
    .global _start
_start:
    j reset

    .balign 16
irq_vector:                 // 0x10; unused while ENABLE_IRQ = 0
    j irq_vector

reset:
    li sp, 0x8000           // top of the stack region 0x6000-0x7FFF
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call main
    li t0, 0x80000000       // result port
    sw a0, 0(t0)
3:  j 3b
