// ZAGROS-1 demo: handwritten-digit MLP (64-32-10, INT8) on the NPU, checked bit-exactly against the Python model,
// plus the same first layer on the CPU alone for a speed comparison.
#include "zg.h"
#include "model.h"

#define B 8                                     // images per NPU batch (array height)
static int8_t  xbuf[B * 64]  __attribute__((aligned(4)));
static int8_t  hid[B * 32]   __attribute__((aligned(4)));
static int8_t  w1[64 * 32]   __attribute__((aligned(4)));
static int8_t  w2[32 * 16]   __attribute__((aligned(4)));
static int32_t b1[32], b2[16];
static int32_t logit[B * 16];
static int8_t  hcpu[B * 32];

static void copy(void *d, const void *s, uint32_t n) {
    const uint32_t *a = s; uint32_t *o = d;
    for (n /= 4; n; n--) *o++ = *a++;
}

static void layer1_npu(void) {
    for (int t = 0; t < 4; t++) {               // 4 column tiles of 8 hidden units, K = 64 in two chunks of 32
        npu_tile(xbuf, 64, w1 + 8 * t, 32, hid + 8 * t, 32, 32, L1_MULT, L1_SHIFT, 0, C_NOSTORE);
        npu_tile(xbuf + 32, 64, w1 + 32 * 32 + 8 * t, 32, hid + 8 * t, 32, 32, L1_MULT, L1_SHIFT, b1 + 8 * t,
                 C_KEEP | C_BIAS | C_RELU);
    }
}

static void layer1_cpu(void) {                  // same math in software (reference speed)
    for (int i = 0; i < B; i++)
        for (int j = 0; j < 32; j++) {
            int32_t acc = b1[j];
            for (int k = 0; k < 64; k++) acc += xbuf[i * 64 + k] * w1[k * 32 + j];
            int64_t v = (int64_t)acc * L1_MULT;
            v = (v + (1LL << (L1_SHIFT - 1))) >> L1_SHIFT;
            hcpu[i * 32 + j] = v > 127 ? 127 : v < 0 ? 0 : (int8_t)v;
        }
}

int main(void) {
    UART_DIV = 8;                               // fast UART for simulation
    puts_("ZAGROS-1 digits demo\n");
    if (NPU(N_ID) != 0x5A474E50) { puts_("NPU missing\n"); return 0x7F00; }
    copy(w1, W1, sizeof w1); copy(w2, W2, sizeof w2); copy(b1, B1, sizeof b1); copy(b2, B2, sizeof b2);

    int bad = 0, correct = 0;
    uint32_t cyc_npu = 0, cyc_cpu = 0;
    for (int base = 0; base < NTEST; base += B) {
        copy(xbuf, X_TEST + base * 64, sizeof xbuf);
        uint32_t c0 = rdcycle();
        layer1_npu();
        cyc_npu += rdcycle() - c0;
        for (int t = 0; t < 2; t++)             // layer 2: K = 32, 16 padded outputs in two tiles, raw int32 + bias
            npu_tile(hid, 32, w2 + 8 * t, 16, logit + 8 * t, 64, 32, 1, 0, b2 + 8 * t, C_RAW | C_BIAS);
        if (base == 0) {
            c0 = rdcycle();
            layer1_cpu();
            cyc_cpu = rdcycle() - c0;
            for (int i = 0; i < B * 32; i++) if (hcpu[i] != hid[i]) bad++;
        }
        for (int i = 0; i < B; i++) {
            int n = base + i, best = 0;
            for (int j = 0; j < 10; j++) {
                if (logit[i * 16 + j] != EXP_LOGITS[n * 10 + j]) bad++;
                if (logit[i * 16 + j] > logit[i * 16 + best]) best = j;
            }
            for (int j = 0; j < 32; j++) if (hid[i * 32 + j] != EXP_HIDDEN[n * 32 + j]) bad++;
            if (best != EXP_PRED[n]) bad++;
            if (best == LABELS[n]) correct++;
            puts_("img "); putd(n); puts_(" pred "); putd(best); puts_(" label "); putd(LABELS[n]); putc_('\n');
        }
    }
    puts_("CYC npu_l1_per_batch "); putd(cyc_npu / (NTEST / B)); puts_(" cpu_l1_per_batch "); putd(cyc_cpu); putc_('\n');
    puts_("RESULT correct "); putd(correct); puts_("/"); putd(NTEST); puts_(" mismatches "); putd(bad); putc_('\n');
    return (bad > 255 ? 255 : bad) << 16 | correct << 8 | NTEST;
}
