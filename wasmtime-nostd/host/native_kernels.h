/* Native kernels offered to wasm guests as imports ("native" module), with the instruction set chosen at start-up:
 *   x86-64: level 0 = baseline (what the compiler makes of the plain loop), 1 = AVX2 + FMA (8 floats per instruction), 2 = AVX-512F (16 floats)
 *   arm64 : level 0 = plain loop, 1 = NEON with fused multiply-add (4 floats per instruction; NEON is part of the baseline of every arm64 machine)
 * The level can be forced with WN_KERNEL_LEVEL (0, 1, 2) for comparisons; a request above what the CPU and the operating system support is lowered. */
#ifndef WN_NATIVE_KERNELS_H
#define WN_NATIVE_KERNELS_H
#include <stddef.h>
#include <stdint.h>
int nk_init(void);   /* returns the level in use */
int nk_level(void);
int nk_haswell_ok(void);   /* x86-64: the CPU and the OS support what a module compiled for the AVX2/FMA/BMI/LZCNT/POPCNT level needs; always 0 elsewhere */
const char *nk_level_name(void);
void nk_saxpy(size_t n, float a, const float *x, float *y);                     /* y += a * x */
float nk_dot(size_t n, const float *x, const float *y);                         /* sum of x * y */
void nk_matmul(size_t m, size_t n, size_t k, const float *A, const float *B, float *C);   /* C (m x n) = A (m x k) * B (k x n), row-major */
#endif
