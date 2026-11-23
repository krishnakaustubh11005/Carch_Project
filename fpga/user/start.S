// Reset entry for user programs (fpga/user/README.md). Same as fw/start.S
// except the stack: it sits at the top of RAM (0xE000-0xFFFF), so code and
// data get 0x0000-0xDFFF.
    .section .text.start
    .global _start
_start:
    j reset

    .balign 16
irq_vector:                 // 0x10; unused while ENABLE_IRQ = 0
    j irq_vector

reset:
    li sp, 0x10000          // top of RAM
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
