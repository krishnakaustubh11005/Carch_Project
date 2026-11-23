// C (6x5) = A (6x2) x B (2x5) with my own values.
// Every C value is printed with id = row*10 + column (e.g. 23 = row 2, col 3).
#include "carch.h"

#define M 6
#define K 2
#define N 5

static int8_t A[M * K] = {      // 6 rows x 2 columns, row by row
     1,  2,
     3, -1,
     0,  4,
    -2,  5,
     7,  0,
     1,  1,
};

static int8_t B[K * N] = {      // 2 rows x 5 columns
     1,  0,  2, -1,  3,
     2,  1,  0,  4, -2,
};

static int32_t C[M * N];

uint32_t job(void)
{
    region_begin(1);                    // region 1: the multiply
    matmul(A, B, C, M, K, N);
    region_end(1);

    for (int r = 0; r < M; r++)         // 30 values (the limit is 48)
        for (int c = 0; c < N; c++)
            print_value(r * 10 + c, C[r * N + c]);

    return checksum(C, sizeof C);
}
