#include "driver.h"

#define ACCEL_BASE ((uintptr_t)0x10000000u)
#define REG(offset) (*(volatile uint32_t *)(ACCEL_BASE + (offset)))
#define POLL_LIMIT 1000u

int accelerator_matmul(const int8_t *a, const int8_t *b, int32_t *c)
{
    if (REG(0x04u) & 1u) return -1;
    for (unsigned i = 0; i < 16u; ++i) {
        REG(0x10u + 4u*i) = (uint8_t)a[i];
        REG(0x50u + 4u*i) = (uint8_t)b[i];
    }
    REG(0x00u) = 1u;
    for (unsigned poll = 0; poll < POLL_LIMIT; ++poll) {
        if ((REG(0x04u) & 3u) == 2u) {
            for (unsigned i = 0; i < 16u; ++i)
                c[i] = (int32_t)REG(0x90u + 4u*i);
            return 0;
        }
    }
    return -2;
}
