// Ten chained 16x16 matmuls: C = A x B, then the top byte of C feeds the
// next A. Shows many small accelerator calls and their fixed overhead.
#include "carch.h"

#define D 16

static int8_t A[D * D], B[D * D];
static int32_t C[D * D];

uint32_t job(void)
{
    rand_seed(3);
    for (int i = 0; i < D * D; i++) { A[i] = rand_i8(); B[i] = rand_i8(); }
    for (int step = 0; step < 10; step++) {
        matmul(A, B, C, D, D, D);
        for (int i = 0; i < D * D; i++)
            A[i] = (int8_t)(C[i] >> 10);
        print_value(step, C[0]);
    }
    return checksum(C, sizeof C);
}
