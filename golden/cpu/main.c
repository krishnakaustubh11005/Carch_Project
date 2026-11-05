#include "matrix_multiply.h"
#include "cases.h"

#define REPORT (*(volatile uint32_t *)0x10000000u)
#define DONE (*(volatile uint32_t *)0x10000004u)
static inline uint32_t cycles(void)
{
    uint32_t value;
    __asm__ volatile ("rdcycle %0" : "=r"(value) :: "memory");
    return value;
}

int main(void)
{
    for (unsigned t = 0; t < CASE_COUNT; ++t) {
        const struct test_case *test = &cases[t];
        uint32_t start = cycles();
        int status = matrix_multiply_int8(test->a, test->b, output,
                                         test->m, test->k, test->n);
        uint32_t elapsed = cycles() - start;
        if (status != 0) { DONE = 2; return 1; }
        for (unsigned i = 0; i < test->m * test->n; ++i)
            if (output[i] != test->expected[i]) { DONE = 3; return 1; }
        REPORT = elapsed;
    }
    DONE = 1;
    return 0;
}
