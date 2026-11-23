// Carch user-program framework (fpga/user/README.md): runs job(), measures
// it, and sends the measurements out of the result port in one burst at the
// end, so one ILA window (4096 clocks) captures all of it:
//
//   0xD1000010  16 words: version, accelerator present, total cycles,
//               total instructions, matmul calls, accelerated calls,
//               cycles in matmul, instructions in matmul, fetch cycles,
//               compute cycles, MACs (all calls), MACs on the accelerator,
//               job() result, values printed, accelerator errors,
//               values dropped
//   0xD20000ii value     one print_value(ii, value)
//   0xD40000ii cycles instructions count   one region_begin/end id ii
//   0xD3000000           end
//   then start.S writes main's return value (1)
#include "carch.h"
#include "../../fw/accel.h"

#define RESULT_PORT ((volatile uint32_t *)0x80000000u)
#define MAX_PRINTS 48
#define BARRIER() __asm__ volatile ("" ::: "memory")

static uint32_t accel_present;
static uint32_t mm_calls, mm_accel_calls, mm_cycles, mm_instructions;
static uint32_t fetch_sum, compute_sum, macs_all, macs_accel, accel_errors;
static uint32_t print_count, print_dropped;
static uint32_t print_id[MAX_PRINTS];
static int32_t print_val[MAX_PRINTS];
static uint32_t rng = 1;
#define REGIONS 8
static uint32_t reg_start_c[REGIONS], reg_start_i[REGIONS];
static uint32_t reg_cycles[REGIONS], reg_instr[REGIONS], reg_count[REGIONS];

void region_begin(uint32_t id)
{
    if (id < REGIONS) {
        reg_start_i[id] = instructions();
        reg_start_c[id] = cycles();
    }
}

void region_end(uint32_t id)
{
    uint32_t c = cycles(), i = instructions();
    if (id < REGIONS) {
        reg_cycles[id] += c - reg_start_c[id];
        reg_instr[id] += i - reg_start_i[id];
        reg_count[id]++;
    }
}

int has_accel(void)
{
    return accel_present;
}

// The two ways matmul() can run. Kept as separate functions (noinline) so
// the page can show each one's machine code (carch_user.py disassembles them).
__attribute__((noinline))
void matmul_cpu(const int8_t *a, const int8_t *b, int32_t *c, int m, int k, int n)
{
    for (int i = 0; i < m; i++)
        for (int j = 0; j < n; j++) {
            int32_t sum = 0;
            for (int t = 0; t < k; t++)
                sum += a[i * k + t] * b[t * n + j];
            c[i * n + j] = sum;
        }
}

// Returns 1 if the accelerator did the job, 0 if it rejected it (ERR).
__attribute__((noinline))
static int matmul_on_accel(const int8_t *a, const int8_t *b, int32_t *c, int m, int k, int n)
{
    BARRIER();                              // A and B are in RAM before the accelerator reads them
    accel_program(m, k, n, (uint32_t)a, (uint32_t)b, (uint32_t)c);
    accel_start();
    uint32_t status = accel_wait();
    ACCEL[ACCEL_STATUS] = STATUS_DONE | STATUS_ERROR;
    BARRIER();                              // C is read only after the job finished
    if (status & STATUS_ERROR)
        return 0;
    fetch_sum += ACCEL[ACCEL_FETCH];
    compute_sum += ACCEL[ACCEL_COMPUTE];
    return 1;
}

static int fits(int m, int k, int n)
{
    return m >= 1 && m <= MATMUL_MAX && k >= 1 && k <= MATMUL_MAX && n >= 1 && n <= MATMUL_MAX;
}

void matmul(const int8_t *a, const int8_t *b, int32_t *c, int m, int k, int n)
{
    uint32_t i0 = instructions();
    uint32_t t0 = cycles();
    int done = 0;
    if (accel_present && fits(m, k, n)) {
        done = matmul_on_accel(a, b, c, m, k, n);
        if (done) {
            mm_accel_calls++;
            macs_accel += (uint32_t)(m * k * n);
        } else {
            accel_errors++;
        }
    }
    if (!done)
        matmul_cpu(a, b, c, m, k, n);
    mm_cycles += cycles() - t0;
    mm_instructions += instructions() - i0;
    mm_calls++;
    macs_all += (uint32_t)(m * k * n);
}

void print_value(uint32_t id, int32_t value)
{
    if (print_count < MAX_PRINTS) {
        print_id[print_count] = id & 0xFFFFFF;
        print_val[print_count] = value;
        print_count++;
    } else {
        print_dropped++;
    }
}

void rand_seed(uint32_t seed)
{
    rng = seed ? seed : 1;
}

uint32_t rand_u32(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

int8_t rand_i8(void)
{
    return (int8_t)(rand_u32() >> 24);
}

uint32_t checksum(const void *data, uint32_t bytes)
{
    const uint8_t *p = (const uint8_t *)data;
    uint32_t h = 2166136261u;
    for (uint32_t i = 0; i < bytes; i++) {
        h ^= p[i];
        h *= 16777619u;
    }
    return h;
}

static void out(uint32_t word)
{
    *RESULT_PORT = word;
}

int main(void)
{
    accel_present = (ACCEL[ACCEL_ID] == ACCEL_ID_VALUE);

    uint32_t i0 = instructions();
    uint32_t t0 = cycles();
    uint32_t result = job();
    uint32_t total_cycles = cycles() - t0;
    uint32_t total_instructions = instructions() - i0;

    out(0xD1000010u);
    out(1);                                 // record version
    out(accel_present);
    out(total_cycles);
    out(total_instructions);
    out(mm_calls);
    out(mm_accel_calls);
    out(mm_cycles);
    out(mm_instructions);
    out(fetch_sum);
    out(compute_sum);
    out(macs_all);
    out(macs_accel);
    out(result);
    out(print_count);
    out(accel_errors);
    out(print_dropped);
    for (uint32_t i = 0; i < print_count; i++) {
        out(0xD2000000u | print_id[i]);
        out((uint32_t)print_val[i]);
    }
    for (uint32_t r = 0; r < REGIONS; r++)
        if (reg_count[r]) {
            out(0xD4000000u | r);
            out(reg_cycles[r]);
            out(reg_instr[r]);
            out(reg_count[r]);
        }
    out(0xD3000000u);
    return 1;                               // start.S writes it: run finished
}
