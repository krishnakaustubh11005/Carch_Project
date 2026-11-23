// Carch user-program API (fpga/user/README.md).
//
// Write one function in your .c file:
//
//     uint32_t job(void) { ...; return checksum(C, sizeof C); }
//
// It runs on the PicoRV32 of the PYNQ-Z2 twice: once on the CPU-only
// bitstream and once on the CPU + accelerator bitstream. The framework
// (carch.c) times the whole job, every matmul() call, and reports it all.
// The value job() returns is compared between the two runs, so return
// something that depends on your results (checksum() helps).
//
// Memory: 64 KB RAM in total. Your code, constants and global arrays share
// 0x0000-0xDFFF (56 KB); the stack is 0xE000-0xFFFF (8 KB). Put big arrays
// at file scope (static), not on the stack.
#ifndef CARCH_H
#define CARCH_H

#include <stdint.h>

#define MATMUL_MAX 64   // the accelerator takes M, K, N in 1..64

// C (m x n, int32) = A (m x k, int8) x B (k x n, int8), all row-major.
// Uses the accelerator when there is one and the sizes fit; otherwise the
// CPU loop. The same call works on both bitstreams.
void matmul(const int8_t *a, const int8_t *b, int32_t *c, int m, int k, int n);

// Always on the CPU (the same loop matmul() falls back to).
void matmul_cpu(const int8_t *a, const int8_t *b, int32_t *c, int m, int k, int n);

// 1 if this bitstream has the accelerator.
int has_accel(void);

// Show a value in the report: print_value(0, x) appears as "0: x".
// Up to 48 values per run (they are sent at the end in one burst).
void print_value(uint32_t id, int32_t value);

// Time a part of your program: region_begin(1); ... region_end(1);
// ids 0-7; a region can run many times (cycles and instructions add up).
void region_begin(uint32_t id);
void region_end(uint32_t id);

// Pseudo-random numbers (xorshift32), the same sequence on both runs.
void rand_seed(uint32_t seed);
uint32_t rand_u32(void);
int8_t rand_i8(void);

// FNV-1a hash of a buffer, for job()'s return value.
uint32_t checksum(const void *data, uint32_t bytes);

// Clock cycles and retired instructions since reset (50 MHz clock).
static inline uint32_t cycles(void)
{
    uint32_t v;
    __asm__ volatile ("rdcycle %0" : "=r"(v));
    return v;
}

static inline uint32_t instructions(void)
{
    uint32_t v;
    __asm__ volatile ("rdinstret %0" : "=r"(v));
    return v;
}

uint32_t job(void);     // yours

#endif
