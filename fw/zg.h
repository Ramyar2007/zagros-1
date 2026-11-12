// ZAGROS-1 register map (see SPEC.md) + tiny UART / NPU drivers
#pragma once
#include <stdint.h>
#define REG(a) (*(volatile uint32_t *)(a))
#define UART_DATA   REG(0x40000000)
#define UART_STATUS REG(0x40000004)
#define UART_DIV    REG(0x40000008)
#define GPIO_OUT    REG(0x40001000)
#define POST        REG(0x4000F000)
#define NPU_BASE    0x50000000
#define NPU(o)      REG(NPU_BASE + (o))
enum { N_CTRL = 0x00, N_STATUS = 0x04, N_A = 0x08, N_AS = 0x0C, N_B = 0x10, N_BS = 0x14, N_C = 0x18, N_CS = 0x1C,
       N_K = 0x20, N_MULT = 0x24, N_SHIFT = 0x28, N_ZP = 0x2C, N_BIAS = 0x30, N_CYC = 0x34, N_ID = 0x38 };
enum { C_START = 1, C_KEEP = 2, C_RELU = 4, C_IRQ = 8, C_BIAS = 16, C_RAW = 32, C_NOSTORE = 64 };

static inline uint32_t rdcycle(void) { uint32_t c; __asm__ volatile("csrr %0, mcycle" : "=r"(c)); return c; }

static void putc_(char ch) { while (UART_STATUS & 1) ; UART_DATA = (uint8_t)ch; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putd(int32_t v) {
    char b[12]; int i = 0; uint32_t u = v < 0 ? -(uint32_t)v : (uint32_t)v;
    if (v < 0) putc_('-');
    do { b[i++] = '0' + u % 10; u /= 10; } while (u);
    while (i) putc_(b[--i]);
}

// one 8x8 output tile on the NPU (blocking)
static void npu_tile(const void *a, uint32_t as, const void *b, uint32_t bs, void *c, uint32_t cs, uint32_t k,
                     uint32_t mult, uint32_t shift, const int32_t *bias, uint32_t flags) {
    NPU(N_A) = (uint32_t)a; NPU(N_AS) = as; NPU(N_B) = (uint32_t)b; NPU(N_BS) = bs;
    NPU(N_C) = (uint32_t)c; NPU(N_CS) = cs; NPU(N_K) = k; NPU(N_MULT) = mult; NPU(N_SHIFT) = shift; NPU(N_ZP) = 0;
    NPU(N_BIAS) = (uint32_t)bias;
    NPU(N_CTRL) = flags | C_START;
    while (!(NPU(N_STATUS) & 2)) ;
    NPU(N_STATUS) = 2;
}
