/* SIMD-heavy kernels, one source for wasm (wasi-sdk/clang) and native (Cosmopolitan/GCC).
 * KERNEL 0 = plain scalar C (the compiler may auto-vectorise), 1 = GCC/clang vector extensions (explicit 128-bit SIMD).
 * Prints ns per item for: vertex transform (4x4 matrix times float4) and a dot-product reduction. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#ifndef KERNEL
#define KERNEL 0
#endif
typedef float v4f __attribute__((vector_size(16)));
static double now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
#define NV (1 << 18)
#define ND (1 << 20)
static float M[16], V[NV * 4], O[NV * 4], A[ND], B[ND];

static void transform_scalar(void) {
  for (int i = 0; i < NV; i++) {
    const float x = V[4*i], y = V[4*i+1], z = V[4*i+2], w = V[4*i+3];
    for (int r = 0; r < 4; r++) O[4*i+r] = M[r]*x + M[4+r]*y + M[8+r]*z + M[12+r]*w;
  }
}
static void transform_vec(void) {
  const v4f c0 = {M[0],M[1],M[2],M[3]}, c1 = {M[4],M[5],M[6],M[7]}, c2 = {M[8],M[9],M[10],M[11]}, c3 = {M[12],M[13],M[14],M[15]};
  for (int i = 0; i < NV; i++) {
    const float x = V[4*i], y = V[4*i+1], z = V[4*i+2], w = V[4*i+3];
    v4f r = c0 * (v4f){x,x,x,x} + c1 * (v4f){y,y,y,y} + c2 * (v4f){z,z,z,z} + c3 * (v4f){w,w,w,w};
    O[4*i] = r[0]; O[4*i+1] = r[1]; O[4*i+2] = r[2]; O[4*i+3] = r[3];
  }
}
static float dot_scalar(void) { float s = 0; for (int i = 0; i < ND; i++) s += A[i] * B[i]; return s; }   /* strict FP order: cannot be vectorised without -ffast-math */
static float dot_vec(void) {
  v4f s0 = {0,0,0,0}, s1 = s0, s2 = s0, s3 = s0;
  for (int i = 0; i < ND; i += 16) {
    s0 += *(const v4f *)(A + i)      * *(const v4f *)(B + i);
    s1 += *(const v4f *)(A + i + 4)  * *(const v4f *)(B + i + 4);
    s2 += *(const v4f *)(A + i + 8)  * *(const v4f *)(B + i + 8);
    s3 += *(const v4f *)(A + i + 12) * *(const v4f *)(B + i + 12);
  }
  v4f s = s0 + s1 + s2 + s3; return s[0] + s[1] + s[2] + s[3];
}
int main(void) {
  for (int i = 0; i < 16; i++) M[i] = 0.5f + 0.01f * i;
  for (int i = 0; i < NV * 4; i++) V[i] = (float)(i % 97) * 0.25f;
  for (int i = 0; i < ND; i++) { A[i] = (float)(i % 31) * 0.5f; B[i] = (float)(i % 17) * 0.25f; }
  /* 9 trials of 6 repetitions each; report the fastest trial (shared CI runners are noisy, the minimum is the least disturbed run) */
  const int trials = 9, reps = 6;
  double best_t = 1e30, best_d = 1e30; float cs = 0, d = 0;
  for (int k = 0; k < trials; k++) {
    double t0 = now_ns();
    for (int r = 0; r < reps; r++) { M[0] += 1e-6f; V[1] += 1e-3f; __asm__ volatile("" ::: "memory"); if (KERNEL) transform_vec(); else transform_scalar(); __asm__ volatile("" ::: "memory"); }
    double t1 = now_ns(); cs = 0; for (int i = 0; i < NV * 4; i += 4099) cs += O[i];
    d = 0; double t2 = now_ns();
    for (int r = 0; r < reps; r++) { A[3] += 1.0f; __asm__ volatile("" ::: "memory"); d += KERNEL ? dot_vec() : dot_scalar(); __asm__ volatile("" ::: "memory"); }
    double t3 = now_ns();
    if (t1 - t0 < best_t) best_t = t1 - t0;
    if (t3 - t2 < best_d) best_d = t3 - t2;
  }
  printf("transform: %.2f ns/vertex (checksum %.3f)\n", best_t / ((double)reps * NV), cs);
  printf("dot:       %.3f ns/element (result %.1f)\n", best_d / ((double)reps * ND), d);
  return 0;
}
