// No matrix multiply at all: counts primes below 3000 on the CPU.
// Both bitstreams run the same instructions, so the speed-up is 1.0x.
#include "carch.h"

uint32_t job(void)
{
    uint32_t count = 0;
    for (uint32_t n = 2; n < 3000; n++) {
        int prime = 1;
        for (uint32_t d = 2; d * d <= n; d++)
            if (n % d == 0) { prime = 0; break; }   // no divider: % is a software routine
        count += prime;
    }
    print_value(0, count);
    return count;
}
