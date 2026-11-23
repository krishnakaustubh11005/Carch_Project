// FPGA job firmware (fpga/README.md, fpga/run.tcl). Runs one matmul job per
// reset. The job comes from the laptop through the VIO in fpga_top, which the
// CPU reads as read-only words at 0x8000_0004 onwards (soc_top cfg_in):
//   CFG[1]      ctrl: M [6:0], K [13:7], N [20:14] (each 1..64),
//               bit 21 = take A and B from CFG[3..10] instead of the seed
//   CFG[2]      seed for pseudo-random int8 A and B (xorshift32; 0 means 1)
//   CFG[3..6]   A, row-major int8, 4 per word, element 0 in bits [7:0] (M*K <= 16)
//   CFG[7..10]  B, same packing (K*N <= 16)
//   ctrl = 0 (no VIO, e.g. a plain soc_top) runs the original 4x4x4 demo.
// Baseline build (soc_top ENABLE_ACCEL = 0, accelerator ID reads 0): only the
// software matmul runs; it fills C, and accel/fetch/compute are reported as 0.
//
// Order: build A and B, time the accelerator job, time the same matmul in
// software, compare every C value, then report everything in one burst so a
// single ILA window (4096 samples, about 3500 clocks for 8x8x8) holds it:
//   0xCA0000A1 rows cols  packed int8 words   matrix A  } only when
//   0xCA0000B1 rows cols  packed int8 words   matrix B  } M, K, N <= 8
//   0xCA0000C4 rows cols  int32 words         matrix C  }
//   0xD0000008 m k n sw_cycles accel_cycles fetch compute sw_instructions
//                                                       benchmark row (the low
//                                                       byte is the word count)
//   final word (written by start.S): 1 = PASS, 0xFttt_iidd = FAIL
//     test 1 accelerator ID wrong, test 2 START rejected (detail = ERR),
//     test 3 C mismatch (index = first wrong element, low 8 bits),
//     test 4 bad config (detail 0: a dimension outside 1..64, 1: matrix mode
//            with more than 16 values in A or B)
#include "accel.h"
#include "soc.h"

#define CFG ((volatile uint32_t *)0x80000000u)
#define TAG_I8(t) (0xCA000000u | (t))
#define SW_ROW ((volatile int32_t *)RAM_SPARE)  // software result, one row at a time
#define DUMP_MAX 8
#define BARRIER() __asm__ volatile ("" ::: "memory")

static const int8_t A_DEMO[16] = {
     1,  2,  3,  4,
    -1,  0,  1,  2,
     5, -3,  2,  0,
     0,  1, -2,  3,
};
static const int8_t B_DEMO[16] = {
     1,  0,  2, -1,
     0,  1,  1,  0,
     3, -2,  0,  1,
     1,  1, -1,  2,
};

static uint32_t rng;

static int8_t next_i8(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return (int8_t)(rng >> 24);
}

static int8_t cfg_i8(uint32_t first_word, uint32_t i)
{
    return (int8_t)(CFG[first_word + i / 4] >> (8 * (i % 4)));
}

static void send_matrix(uint32_t tag, uint32_t addr, uint32_t rows, uint32_t cols, uint32_t words)
{
    const volatile uint32_t *p = (const volatile uint32_t *)addr;
    report(tag);
    report(rows);
    report(cols);
    for (uint32_t i = 0; i < words; i++)
        report(p[i]);
}

int main(void)
{
    int8_t *a = (int8_t *)RAM_A;
    int8_t *b = (int8_t *)RAM_B;
    volatile int32_t *c = (volatile int32_t *)RAM_C;

    uint32_t ctrl = CFG[1];
    uint32_t m = 4, k = 4, n = 4, use_matrices = 1;
    if (ctrl != 0) {
        m = ctrl & 0x7F;
        k = (ctrl >> 7) & 0x7F;
        n = (ctrl >> 14) & 0x7F;
        use_matrices = (ctrl >> 21) & 1;
    }
    if (m < 1 || m > 64 || k < 1 || k > 64 || n < 1 || n > 64)
        return RESULT_FAIL(4, 0, 0);
    if (use_matrices && (m * k > 16 || k * n > 16))
        return RESULT_FAIL(4, 0, 1);

    if (use_matrices) {
        for (uint32_t i = 0; i < m * k; i++)
            a[i] = ctrl ? cfg_i8(3, i) : A_DEMO[i];
        for (uint32_t i = 0; i < k * n; i++)
            b[i] = ctrl ? cfg_i8(7, i) : B_DEMO[i];
    } else {
        rng = CFG[2] ? CFG[2] : 1;
        for (uint32_t i = 0; i < m * k; i++)
            a[i] = next_i8();
        for (uint32_t i = 0; i < k * n; i++)
            b[i] = next_i8();
    }
    for (uint32_t i = 0; i < m * n; i++)
        c[i] = (int32_t)0xEEEEEEEE;
    BARRIER();                              // A and B are in RAM before the accelerator reads them

    uint32_t id = ACCEL[ACCEL_ID];
    uint32_t baseline = (id == 0);
    if (!baseline && id != ACCEL_ID_VALUE)
        return RESULT_FAIL(1, 0, 1);

    // ---------------------------------------------------------------- accelerator
    uint32_t t0, accel_cycles = 0, fetch_cycles = 0, compute_cycles = 0;
    if (!baseline) {
        t0 = rdcycle();
        accel_program(m, k, n, RAM_A, RAM_B, RAM_C);
        accel_start();
        uint32_t status = accel_wait();
        accel_cycles = rdcycle() - t0;
        ACCEL[ACCEL_STATUS] = STATUS_DONE | STATUS_ERROR;
        if (status & STATUS_ERROR)
            return RESULT_FAIL(2, 0, ACCEL[ACCEL_ERR]);
        fetch_cycles = ACCEL[ACCEL_FETCH];
        compute_cycles = ACCEL[ACCEL_COMPUTE];
    }

    // ---------------------------------------------------------------- software
    // The same C = A x B on the CPU (RV32IM, hardware multiplier). Each result
    // is stored, as the accelerator stores each C value.
    BARRIER();
    uint32_t i0 = rdinstret();
    t0 = rdcycle();
    for (uint32_t i = 0; i < m; i++)
        for (uint32_t j = 0; j < n; j++) {
            int32_t sum = 0;
            for (uint32_t t = 0; t < k; t++)
                sum += a[i * k + t] * b[t * n + j];
            SW_ROW[j] = sum;
        }
    uint32_t sw_cycles = rdcycle() - t0;
    uint32_t sw_instructions = rdinstret() - i0;   // CPI = sw_cycles / sw_instructions

    // ---------------------------------------------------------------- check (untimed)
    // Baseline: there is no accelerator C to check; store the CPU's C instead.
    uint32_t verdict = RESULT_PASS;
    for (uint32_t i = 0; i < m && verdict == RESULT_PASS; i++)
        for (uint32_t j = 0; j < n; j++) {
            int32_t sum = 0;
            for (uint32_t t = 0; t < k; t++)
                sum += a[i * k + t] * b[t * n + j];
            if (baseline)
                c[i * n + j] = sum;
            else if (c[i * n + j] != sum) {
                verdict = RESULT_FAIL(3, (i * n + j) & 0xFF, 0);
                break;
            }
        }

    // ---------------------------------------------------------------- report (one burst)
    if (m <= DUMP_MAX && k <= DUMP_MAX && n <= DUMP_MAX) {
        send_matrix(TAG_I8(0xA1), RAM_A, m, k, (m * k + 3) / 4);
        send_matrix(TAG_I8(0xB1), RAM_B, k, n, (k * n + 3) / 4);
        send_matrix(TAG_I8(0xC4), RAM_C, m, n, m * n);
    }
    report(RESULT_BENCH(8));
    report(m); report(k); report(n);
    report(sw_cycles); report(accel_cycles);
    report(fetch_cycles); report(compute_cycles);
    report(sw_instructions);
    return verdict;                         // start.S writes it to the result port
}
