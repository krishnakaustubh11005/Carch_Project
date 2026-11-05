#ifndef MATRIX_MULTIPLY_H
#define MATRIX_MULTIPLY_H

#include <stddef.h>
#include <stdint.h>

#define MATRIX_DATA_W 8
#define MATRIX_ACC_W 24
#define MATRIX_MAX_K 256

/*
 * Computes C = A x B.
 * A is M x K, B is K x N, and C is M x N.
 * All matrices use row-major storage.
 *
 * Returns 0 on success, -1 for invalid pointers/dimensions or K > 256.
 * Accumulation wraps to signed 24-bit two's-complement after each MAC.
 */
int matrix_multiply_int8(
    const int8_t *A,
    const int8_t *B,
    int32_t *C,
    size_t M,
    size_t K,
    size_t N
);

#endif
