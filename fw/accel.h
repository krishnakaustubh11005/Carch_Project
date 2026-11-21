// matmul_accel register map (docs/ACCELERATOR_PLAN.md section 4) and a small
// polling driver. Registers are 32-bit words: always access them through
// ACCEL[...] (lw/sw); byte or half-word stores are dropped by soc_top.
#ifndef ACCEL_H
#define ACCEL_H

#include <stdint.h>

#define ACCEL_BASE 0x40000000u
#define ACCEL ((volatile uint32_t *)ACCEL_BASE)

// Word indices (byte offset / 4).
enum accel_reg {
    ACCEL_ID = 0, ACCEL_CAPS, ACCEL_CTRL, ACCEL_STATUS, ACCEL_ERR, ACCEL_JOBS,
    ACCEL_FETCH, ACCEL_COMPUTE, ACCEL_M, ACCEL_N, ACCEL_K,
    ACCEL_A, ACCEL_B, ACCEL_C, ACCEL_IRQ_EN
};

#define ACCEL_ID_VALUE   0x4D4D3434u   // "MM44"
#define ACCEL_CAPS_VALUE 0x00000440u   // MAX_DIM 64, 4x4 array, no queue

#define CTRL_START   0x1u
#define CTRL_ABORT   0x2u
#define STATUS_BUSY  0x1u
#define STATUS_DONE  0x4u              // write 1 to clear
#define STATUS_ERROR 0x8u              // write 1 to clear

#define ERR_DIMS   1u                  // M, N or K outside 1..64
#define ERR_ALIGN  2u                  // C_ADDR not a multiple of 4
#define ERR_BUSY   4u                  // START while a job runs
#define ERR_RANGE  5u                  // A, B or C past the end of RAM

// C (m x n, int32, row-major) = A (m x k, int8, row-major) x B (k x n).
static inline void accel_program(uint32_t m, uint32_t k, uint32_t n,
                                 uint32_t a_addr, uint32_t b_addr, uint32_t c_addr)
{
    ACCEL[ACCEL_M] = m;
    ACCEL[ACCEL_N] = n;
    ACCEL[ACCEL_K] = k;
    ACCEL[ACCEL_A] = a_addr;
    ACCEL[ACCEL_B] = b_addr;
    ACCEL[ACCEL_C] = c_addr;
}

static inline void accel_start(void)
{
    ACCEL[ACCEL_CTRL] = CTRL_START;
}

// Polls until the job finishes or START is rejected; returns STATUS.
static inline uint32_t accel_wait(void)
{
    uint32_t status;
    do {
        status = ACCEL[ACCEL_STATUS];
    } while (!(status & (STATUS_DONE | STATUS_ERROR)));
    return status;
}

#endif
