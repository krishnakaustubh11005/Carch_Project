#include <stdint.h>
#include "driver.h"
#include "cases.h"

/* Simulation-only reporting registers, outside RAM and accelerator windows. */
#define REPORT(offset) (*(volatile uint32_t *)(uintptr_t)(0x20000000u + (offset)))
static int32_t cpu_output[16], accelerator_output[16];

static inline uint32_t cycles(void)
{
    uint32_t value;
    __asm__ volatile ("rdcycle %0" : "=r"(value) :: "memory");
    return value;
}

/* K=4 cannot overflow signed 24 bits, so int32 accumulation is exact here. */
__attribute__((noinline))
static void cpu_matmul(const int8_t *a, const int8_t *b, int32_t *c)
{
    for (unsigned row = 0; row < 4u; ++row)
        for (unsigned col = 0; col < 4u; ++col) {
            int32_t sum = 0;
            for (unsigned k = 0; k < 4u; ++k)
                sum += (int32_t)a[4u*row+k] * (int32_t)b[4u*k+col];
            c[4u*row+col] = sum;
        }
}

int main(void)
{
    for (unsigned t = 0; t < CASE_COUNT; ++t) {
        uint32_t start = cycles();
        cpu_matmul(cases[t].a, cases[t].b, cpu_output);
        uint32_t cpu_cycles = cycles() - start;
        start = cycles();
        int status = accelerator_matmul(cases[t].a, cases[t].b, accelerator_output);
        uint32_t accelerator_cycles = cycles() - start;
        if (status != 0) { REPORT(8u) = 2u; return 1; }
        for (unsigned i = 0; i < 16u; ++i) {
            if (cpu_output[i] != cases[t].expected[i]) {
                REPORT(8u) = 3u; return 1;
            }
            if (accelerator_output[i] != cases[t].expected[i]) {
                REPORT(8u) = 4u; return 1;
            }
        }
        REPORT(0u) = cpu_cycles;
        REPORT(4u) = accelerator_cycles;
    }
    REPORT(8u) = 1u;
    return 0;
}
