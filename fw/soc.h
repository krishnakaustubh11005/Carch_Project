// soc_top address map and the result port protocol shared with tb/tb_soc_top.v.
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

// RAM layout (64 KB): code + data 0x0000-0x5FFF, stack 0x6000-0x7FFF,
// A 0x8000, B 0x9000, C 0xA000-0xDFFF, spare 0xE000-0xFFFF.
#define RAM_A     0x8000u
#define RAM_B     0x9000u
#define RAM_C     0xA000u
#define RAM_SPARE 0xE000u
#define RAM_END   0x10000u

#define UNMAPPED_ADDR 0x20000000u

// Result port: every write is seen by the testbench.
//   RESULT_PASS            final: all tests passed
//   0xFttt_iidd            final: failure, test t, case i, detail d
//   RESULT_MARK_BUS_TESTS  bus_error must still be 0 here; deliberate bad
//                          accesses follow
//   0xD000_00nn            the next nn words are one benchmark row
#define RESULT ((volatile uint32_t *)0x80000000u)
#define RESULT_PASS 0x00000001u
#define RESULT_MARK_BUS_TESTS 0x000000B0u
#define RESULT_BENCH(words) (0xD0000000u | (words))
#define RESULT_FAIL(test, index, detail) \
    (0xF0000000u | ((uint32_t)(test) << 16) | ((uint32_t)(index) << 8) | (uint32_t)(detail))

static inline void report(uint32_t word)
{
    *RESULT = word;
}

static inline uint32_t rdcycle(void)
{
    uint32_t cycles;
    __asm__ volatile ("rdcycle %0" : "=r"(cycles));
    return cycles;
}

// Instructions retired so far (PicoRV32 ENABLE_COUNTERS).
static inline uint32_t rdinstret(void)
{
    uint32_t count;
    __asm__ volatile ("rdinstret %0" : "=r"(count));
    return count;
}

#endif
