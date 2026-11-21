// PicoRV32 system test for matmul_accel, run by tb/tb_soc_top.v.
//
// 1. Registers: ID and CAPS.
// 2. Jobs: fill A and B (random or extreme values, unaligned addresses),
//    poison C, run on the accelerator, compare every C value with a software
//    matmul, check the word after C is untouched and JOBS_DONE counts once.
//    Each job also reports a benchmark row (software vs accelerator cycles).
// 3. START errors: bad dimensions, unaligned C, past end of RAM, START while
//    busy (the running job must still finish correctly).
// 4. ABORT during a job (it lands in FETCH_A), then a normal job.
// 5. Bus checks (after RESULT_MARK_BUS_TESTS): a byte store to CTRL is
//    dropped, an unmapped read returns 0. Both set soc_top's bus_error.
// main returns RESULT_PASS or the first RESULT_FAIL code.
#include <stdint.h>
#include "accel.h"
#include "soc.h"

#define POISON 0xEEEEEEEEu
#define SW_C ((int32_t *)RAM_SPARE)        // software result, up to 2048 words

enum { FILL_RANDOM, FILL_MIN_MIN, FILL_MIN_MAX };
enum { TEST_REGS = 1, TEST_JOBS, TEST_ERRORS, TEST_ABORT, TEST_BUS };

struct job {
    uint8_t m, k, n, fill;
    uint16_t a_off, b_off, c_off;          // bytes from RAM_A / RAM_B, words from RAM_C
};

// m*n <= 2048 so the software result fits in the spare region. The default
// set reaches M, K and N = 64 with small products, so the slow software
// reference keeps the simulation short; FW_FULL (make test-soc-full) adds
// larger jobs for the benchmark.
static const struct job jobs[] = {
    { 1,  1,  1, FILL_RANDOM,  0, 0, 0},
    { 4,  4,  4, FILL_RANDOM,  1, 2, 0},
    { 5,  3,  7, FILL_RANDOM,  3, 1, 5},
    {13, 16,  9, FILL_RANDOM,  0, 7, 1},
    {64,  2,  3, FILL_RANDOM,  2, 0, 3},   // M = 64
    { 3,  2, 64, FILL_RANDOM,  1, 5, 0},   // N = 64
    { 2, 64,  3, FILL_RANDOM,  3, 0, 7},   // K = 64
    { 4, 64,  4, FILL_MIN_MIN, 0, 0, 0},   // largest sum: 64 * 16384
    { 4, 64,  5, FILL_MIN_MAX, 0, 0, 0},   // most negative: 64 * -16256
#ifdef FW_FULL
    {16, 16, 16, FILL_RANDOM,  0, 0, 0},
    {32,  1, 64, FILL_RANDOM,  2, 0, 3},
    { 2, 64, 64, FILL_RANDOM,  1, 0, 0},   // B fills the whole 4 KB region
    {64, 64,  4, FILL_RANDOM,  0, 3, 2},   // A fills the whole 4 KB region
    {32, 64, 32, FILL_RANDOM,  0, 0, 0},
#endif
};
#define JOB_COUNT (sizeof jobs / sizeof jobs[0])
#define JOB_4X4X4 1
#define JOB_13X16X9 3

static uint32_t seed;

static int8_t random_byte(void)
{
    seed = seed * 1664525u + 1013904223u;
    return (int8_t)(seed >> 24);
}

static void sw_matmul(const int8_t *a, const int8_t *b, int32_t *c, int m, int k, int n)
{
    for (int i = 0; i < m; i++)
        for (int j = 0; j < n; j++) {
            int32_t sum = 0;
            for (int t = 0; t < k; t++)
                sum += a[i*k + t] * b[t*n + j];
            c[i*n + j] = sum;
        }
}

static uint32_t a_addr(const struct job *j) { return RAM_A + j->a_off; }
static uint32_t b_addr(const struct job *j) { return RAM_B + j->b_off; }
static uint32_t c_addr(const struct job *j) { return RAM_C + 4u*j->c_off; }

// Fills A and B, poisons C and the word after it.
static void prepare(int index)
{
    const struct job *j = &jobs[index];
    int8_t *a = (int8_t *)a_addr(j), *b = (int8_t *)b_addr(j);
    volatile uint32_t *c = (volatile uint32_t *)c_addr(j);
    seed = 0x2026u + 0x9E3779B9u * (uint32_t)index;
    for (int i = 0; i < j->m * j->k; i++)
        a[i] = j->fill == FILL_RANDOM ? random_byte() : -128;
    for (int i = 0; i < j->k * j->n; i++)
        b[i] = j->fill == FILL_RANDOM ? random_byte() : j->fill == FILL_MIN_MIN ? -128 : 127;
    for (int i = 0; i <= j->m * j->n; i++)
        c[i] = POISON;
}

// Compares C with the software result; reports the benchmark row.
static uint32_t check(int index, uint32_t accel_cycles)
{
    const struct job *j = &jobs[index];
    volatile int32_t *c = (volatile int32_t *)c_addr(j);
    uint32_t t0 = rdcycle();
    sw_matmul((const int8_t *)a_addr(j), (const int8_t *)b_addr(j), SW_C, j->m, j->k, j->n);
    uint32_t sw_cycles = rdcycle() - t0;
    for (int i = 0; i < j->m * j->n; i++)
        if (c[i] != SW_C[i])
            return RESULT_FAIL(TEST_JOBS, index, 2);
    if ((uint32_t)c[j->m * j->n] != POISON)
        return RESULT_FAIL(TEST_JOBS, index, 3);
    report(RESULT_BENCH(7));
    report(j->m); report(j->k); report(j->n);
    report(sw_cycles); report(accel_cycles);
    report(ACCEL[ACCEL_FETCH]); report(ACCEL[ACCEL_COMPUTE]);
    return 0;
}

static uint32_t run_job(int index)
{
    const struct job *j = &jobs[index];
    prepare(index);
    uint32_t jobs_before = ACCEL[ACCEL_JOBS];
    uint32_t t0 = rdcycle();
    accel_program(j->m, j->k, j->n, a_addr(j), b_addr(j), c_addr(j));
    accel_start();
    uint32_t status = accel_wait();
    uint32_t accel_cycles = rdcycle() - t0;
    if (status & STATUS_ERROR)
        return RESULT_FAIL(TEST_JOBS, index, 1);
    ACCEL[ACCEL_STATUS] = STATUS_DONE;
    if (ACCEL[ACCEL_STATUS] & STATUS_DONE)
        return RESULT_FAIL(TEST_JOBS, index, 4);
    if (ACCEL[ACCEL_JOBS] != jobs_before + 1)
        return RESULT_FAIL(TEST_JOBS, index, 5);
    return check(index, accel_cycles);
}

static uint32_t expect_error(int index, uint32_t m, uint32_t k, uint32_t n,
                             uint32_t a, uint32_t b, uint32_t c, uint32_t code)
{
    uint32_t jobs_before = ACCEL[ACCEL_JOBS];
    accel_program(m, k, n, a, b, c);
    accel_start();
    uint32_t status = ACCEL[ACCEL_STATUS];
    if (!(status & STATUS_ERROR) || (status & STATUS_BUSY))
        return RESULT_FAIL(TEST_ERRORS, index, 1);
    if (ACCEL[ACCEL_ERR] != code)
        return RESULT_FAIL(TEST_ERRORS, index, 2);
    ACCEL[ACCEL_STATUS] = STATUS_ERROR;
    if (ACCEL[ACCEL_STATUS] & STATUS_ERROR)
        return RESULT_FAIL(TEST_ERRORS, index, 3);
    if (ACCEL[ACCEL_JOBS] != jobs_before)
        return RESULT_FAIL(TEST_ERRORS, index, 4);
    return 0;
}

static uint32_t error_tests(void)
{
    uint32_t r;
    if ((r = expect_error(0, 0, 4, 4, RAM_A, RAM_B, RAM_C, ERR_DIMS))) return r;
    if ((r = expect_error(1, 65, 4, 4, RAM_A, RAM_B, RAM_C, ERR_DIMS))) return r;
    if ((r = expect_error(2, 4, 4, 4, RAM_A, RAM_B, RAM_C + 2, ERR_ALIGN))) return r;
    if ((r = expect_error(3, 1, 1, 2, RAM_A, RAM_B, RAM_END - 4, ERR_RANGE))) return r;
    if ((r = expect_error(4, 64, 64, 64, RAM_END - 64, RAM_B, RAM_C, ERR_RANGE))) return r;

    // START while busy: rejected with ERR_BUSY; the running job is unharmed.
    const struct job *j = &jobs[JOB_13X16X9];
    prepare(JOB_13X16X9);
    uint32_t jobs_before = ACCEL[ACCEL_JOBS];
    accel_program(j->m, j->k, j->n, a_addr(j), b_addr(j), c_addr(j));
    accel_start();
    accel_start();
    uint32_t status = ACCEL[ACCEL_STATUS];
    if (!(status & STATUS_BUSY) || !(status & STATUS_ERROR))
        return RESULT_FAIL(TEST_ERRORS, 5, 1);
    if (ACCEL[ACCEL_ERR] != ERR_BUSY)
        return RESULT_FAIL(TEST_ERRORS, 5, 2);
    ACCEL[ACCEL_STATUS] = STATUS_ERROR;
    while (!(ACCEL[ACCEL_STATUS] & STATUS_DONE))
        ;
    ACCEL[ACCEL_STATUS] = STATUS_DONE;
    if (ACCEL[ACCEL_JOBS] != jobs_before + 1)
        return RESULT_FAIL(TEST_ERRORS, 5, 3);
    volatile int32_t *c = (volatile int32_t *)c_addr(j);
    sw_matmul((const int8_t *)a_addr(j), (const int8_t *)b_addr(j), SW_C, j->m, j->k, j->n);
    for (int i = 0; i < j->m * j->n; i++)
        if (c[i] != SW_C[i])
            return RESULT_FAIL(TEST_ERRORS, 5, 4);
    return 0;
}

static uint32_t abort_test(void)
{
    const struct job *j = &jobs[JOB_13X16X9];
    prepare(JOB_13X16X9);
    uint32_t jobs_before = ACCEL[ACCEL_JOBS];
    accel_program(j->m, j->k, j->n, a_addr(j), b_addr(j), c_addr(j));
    accel_start();
    if (!(ACCEL[ACCEL_STATUS] & STATUS_BUSY))
        return RESULT_FAIL(TEST_ABORT, 0, 1);
    ACCEL[ACCEL_CTRL] = CTRL_ABORT;
    uint32_t status = ACCEL[ACCEL_STATUS];
    if (status & (STATUS_BUSY | STATUS_DONE))
        return RESULT_FAIL(TEST_ABORT, 0, 2);
    if (ACCEL[ACCEL_JOBS] != jobs_before)
        return RESULT_FAIL(TEST_ABORT, 0, 3);
    uint32_t r = run_job(JOB_4X4X4);         // the accelerator still works
    return r ? RESULT_FAIL(TEST_ABORT, 1, r & 0xFF) : 0;
}

static uint32_t bus_tests(void)
{
    report(RESULT_MARK_BUS_TESTS);
    uint32_t jobs_before = ACCEL[ACCEL_JOBS];
    accel_program(1, 1, 1, RAM_A, RAM_B, RAM_C);
    *(volatile uint8_t *)(ACCEL_BASE + 4u*ACCEL_CTRL) = CTRL_START;   // dropped
    for (volatile int i = 0; i < 5; i++)
        ;
    if (ACCEL[ACCEL_STATUS] & (STATUS_BUSY | STATUS_DONE | STATUS_ERROR))
        return RESULT_FAIL(TEST_BUS, 0, 1);
    if (ACCEL[ACCEL_JOBS] != jobs_before)
        return RESULT_FAIL(TEST_BUS, 0, 2);
    if (*(volatile uint32_t *)UNMAPPED_ADDR != 0)
        return RESULT_FAIL(TEST_BUS, 1, 1);
    return 0;
}

int main(void)
{
    uint32_t r;
    if (ACCEL[ACCEL_ID] != ACCEL_ID_VALUE)
        return RESULT_FAIL(TEST_REGS, 0, 1);
    if (ACCEL[ACCEL_CAPS] != ACCEL_CAPS_VALUE)
        return RESULT_FAIL(TEST_REGS, 0, 2);
    for (unsigned i = 0; i < JOB_COUNT; i++)
        if ((r = run_job(i)))
            return r;
    if ((r = error_tests()))
        return r;
    if ((r = abort_test()))
        return r;
    if ((r = bus_tests()))
        return r;
    return RESULT_PASS;
}
