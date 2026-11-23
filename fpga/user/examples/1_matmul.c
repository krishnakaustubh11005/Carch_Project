// One 32x32x32 int8 matrix multiply with random values.
// Try other sizes (up to 64): the bigger, the larger the speed-up.
// Regions time parts of the program; the rest (checksum) is "other".
#include "carch.h"

#define M 32
#define K 32
#define N 32

static int8_t A[M * K], B[K * N];
static int32_t C[M * N];

uint32_t job(void)
{
    region_begin(0);                    // region 0: make the input matrices
    rand_seed(1);
    for (int i = 0; i < M * K; i++) A[i] = rand_i8();
    for (int i = 0; i < K * N; i++) B[i] = rand_i8();
    region_end(0);

    region_begin(1);                    // region 1: the multiply
    matmul(A, B, C, M, K, N);
    region_end(1);

    print_value(0, C[0]);
    print_value(1, C[M * N - 1]);
    return checksum(C, sizeof C);
}
