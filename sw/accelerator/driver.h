#ifndef ACCELERATOR_DRIVER_H
#define ACCELERATOR_DRIVER_H
#include <stdint.h>

/* Fixed signed INT8 4x4 matrices in row-major order; outputs sign-extended.
 * Returns 0 on success, -1 if already busy, -2 on polling timeout.
 * Caller supplies valid, non-overlapping arrays of sixteen elements.
 */
int accelerator_matmul(const int8_t *a, const int8_t *b, int32_t *c);
#endif
