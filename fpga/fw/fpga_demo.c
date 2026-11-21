// FPGA demo firmware (fpga/README.md). One 4x4x4 job on the accelerator, the
// same job in software, then everything goes out through the result port,
// which fpga_top turns into text on the UART pin:
//   0xCA0000A1 rows cols  packed int8 words   matrix A (4 elements per word)
//   0xCA0000B1 rows cols  packed int8 words   matrix B
//   0xCA0000C4 rows cols  int32 words         matrix C from the accelerator
//   0xD0000007 m k n sw_cycles accel_cycles fetch compute   benchmark row
//   final word (written by start.S): 1 = PASS, 0xFttt_iidd = FAIL
#include "accel.h"
#include "soc.h"

#define M 4
#define K 4
#define N 4
#define TAG_I8(t)  (0xCA000000u | (t))
#define SW_C ((int32_t *)RAM_SPARE)

static const int8_t A_INIT[M * K] = {
     1,  2,  3,  4,
    -1,  0,  1,  2,
     5, -3,  2,  0,
     0,  1, -2,  3,
};
static const int8_t B_INIT[K * N] = {
     1,  0,  2, -1,
     0,  1,  1,  0,
     3, -2,  0,  1,
     1,  1, -1,  2,
};

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
    volatile int8_t *a = (volatile int8_t *)RAM_A;
    volatile int8_t *b = (volatile int8_t *)RAM_B;
    volatile int32_t *c = (volatile int32_t *)RAM_C;

    for (int i = 0; i < M * K; i++)
        a[i] = A_INIT[i];
    for (int i = 0; i < K * N; i++)
        b[i] = B_INIT[i];
    for (int i = 0; i < M * N; i++)
        c[i] = (int32_t)0xEEEEEEEE;

    if (ACCEL[ACCEL_ID] != ACCEL_ID_VALUE)
        return RESULT_FAIL(1, 0, 1);

    uint32_t t0 = rdcycle();
    accel_program(M, K, N, RAM_A, RAM_B, RAM_C);
    accel_start();
    uint32_t status = accel_wait();
    uint32_t accel_cycles = rdcycle() - t0;
    ACCEL[ACCEL_STATUS] = STATUS_DONE | STATUS_ERROR;
    if (status & STATUS_ERROR)
        return RESULT_FAIL(2, 0, ACCEL[ACCEL_ERR]);

    t0 = rdcycle();
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            int32_t sum = 0;
            for (int t = 0; t < K; t++)
                sum += a[i * K + t] * b[t * N + j];
            SW_C[i * N + j] = sum;
        }
    uint32_t sw_cycles = rdcycle() - t0;

    uint32_t verdict = RESULT_PASS;
    for (int i = 0; i < M * N; i++)
        if (c[i] != SW_C[i]) {
            verdict = RESULT_FAIL(3, i, 0);
            break;
        }

    send_matrix(TAG_I8(0xA1), RAM_A, M, K, (M * K + 3) / 4);
    send_matrix(TAG_I8(0xB1), RAM_B, K, N, (K * N + 3) / 4);
    send_matrix(TAG_I8(0xC4), RAM_C, M, N, M * N);
    report(RESULT_BENCH(7));
    report(M); report(K); report(N);
    report(sw_cycles); report(accel_cycles);
    report(ACCEL[ACCEL_FETCH]); report(ACCEL[ACCEL_COMPUTE]);
    return verdict;                         // start.S writes it to the result port
}
