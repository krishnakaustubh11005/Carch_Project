// A tiny 2-layer neural network on 8 inputs:
//   hidden = ReLU(X x W1) scaled back to int8,  scores = hidden x W2
// The two matmuls can use the accelerator; ReLU, scaling and argmax run on
// the CPU in both versions (Amdahl's law: they limit the overall speed-up).
// Regions: 0 = layer 1 matmul, 1 = ReLU + requantise, 2 = layer 2 matmul.
#include "carch.h"

#define BATCH 8
#define IN 64
#define HID 32
#define OUT 10

static int8_t X[BATCH * IN], W1[IN * HID], H[BATCH * HID], W2[HID * OUT];
static int32_t T1[BATCH * HID], S[BATCH * OUT];

uint32_t job(void)
{
    rand_seed(7);
    for (int i = 0; i < BATCH * IN; i++) X[i] = rand_i8();
    for (int i = 0; i < IN * HID; i++) W1[i] = rand_i8() / 8;
    for (int i = 0; i < HID * OUT; i++) W2[i] = rand_i8() / 8;

    region_begin(0);
    matmul(X, W1, T1, BATCH, IN, HID);              // layer 1
    region_end(0);
    region_begin(1);
    for (int i = 0; i < BATCH * HID; i++) {         // ReLU + requantise to int8
        int32_t v = T1[i] > 0 ? T1[i] >> 6 : 0;
        H[i] = v > 127 ? 127 : (int8_t)v;
    }
    region_end(1);
    region_begin(2);
    matmul(H, W2, S, BATCH, HID, OUT);              // layer 2
    region_end(2);

    uint32_t answers = 0;
    for (int b = 0; b < BATCH; b++) {               // predicted class per input
        int best = 0;
        for (int o = 1; o < OUT; o++)
            if (S[b * OUT + o] > S[b * OUT + best]) best = o;
        print_value(b, best);
        answers = answers * 10 + best;
    }
    return answers ^ checksum(S, sizeof S);
}
