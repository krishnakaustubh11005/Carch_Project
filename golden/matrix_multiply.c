#include "matrix_multiply.h"

#include <stddef.h>
#include <stdint.h>

/* Match the Python model's signed 24-bit accumulator wraparound. */
static int32_t wrap_acc24(int64_t value)
{
    const uint32_t mask = 0x00FFFFFFu;
    const uint32_t sign_bit = 0x00800000u;
    uint32_t wrapped = (uint32_t)value & mask;

    if ((wrapped & sign_bit) != 0u) {
        return (int32_t)((int64_t)wrapped - 0x01000000LL);
    }

    return (int32_t)wrapped;
}

int matrix_multiply_int8(
    const int8_t *A,
    const int8_t *B,
    int32_t *C,
    size_t M,
    size_t K,
    size_t N
)
{
    if (A == NULL || B == NULL || C == NULL ||
        M == 0u || K == 0u || N == 0u || K > MATRIX_MAX_K) {
        return -1;
    }

    for (size_t i = 0; i < M; ++i) {
        for (size_t j = 0; j < N; ++j) {
            int32_t accumulator = 0;

            for (size_t k = 0; k < K; ++k) {
                int32_t a = (int32_t)A[i * K + k];
                int32_t b = (int32_t)B[k * N + j];
                int32_t product = a * b;

                accumulator = wrap_acc24(
                    (int64_t)accumulator + (int64_t)product
                );
            }

            C[i * N + j] = accumulator;
        }
    }

    return 0;
}

/* Host-side test. Define MATRIX_MULTIPLY_NO_MAIN for firmware builds. */
#ifndef MATRIX_MULTIPLY_NO_MAIN
#include <stdio.h>

int main(void)
{
    const int8_t A[2][2] = {{1, 2}, {3, 4}};
    const int8_t B[2][2] = {{5, 6}, {7, 8}};
    int32_t C[2][2] = {{0, 0}, {0, 0}};
    const int32_t expected[2][2] = {{19, 22}, {43, 50}};

    if (matrix_multiply_int8(&A[0][0], &B[0][0], &C[0][0],
                             2u, 2u, 2u) != 0) {
        printf("Matrix multiplication failed: invalid arguments.\n");
        return 1;
    }

    for (size_t i = 0; i < 2u; ++i) {
        for (size_t j = 0; j < 2u; ++j) {
            if (C[i][j] != expected[i][j]) {
                printf("Mismatch at C[%zu][%zu]: got %ld, expected %ld\n",
                       i, j, (long)C[i][j], (long)expected[i][j]);
                return 1;
            }
        }
    }

    printf("Matrix multiplication test passed.\n");
    return 0;
}
#endif
