/* Kernels typical of game / application code, one source for wasm (clang) and native (GCC/clang). Prints "KERNEL <name> <ms> <checksum>" (best of several runs).
 * Build with -DSIMD=1 to use explicit 128-bit vector extensions where a kernel has a vector variant (wasm SIMD128 / SSE / NEON); without it everything is scalar C. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>
#ifndef SIMD
#define SIMD 0
#endif
typedef float v4f __attribute__((vector_size(16)));
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static uint64_t sink;
#define BEST(name, reps, body, sum) do { double best = 1e30; uint64_t cs = 0; for (int r = 0; r < (reps); r++) { double t0 = now_ms(); body; double t1 = now_ms(); if (t1 - t0 < best) best = t1 - t0; cs = (sum); } \
    printf("KERNEL %s %.3f %llu\n", name, best, (unsigned long long)cs); sink += cs; } while (0)

/* 1. dense matrix multiply 256x256 floats (scalar triple loop, i-k-j order so the inner loop is contiguous) */
#define MN 256
static float MA[MN * MN], MB[MN * MN], MC[MN * MN];
static void matmul(void) {
    memset(MC, 0, sizeof MC);
    for (int i = 0; i < MN; i++) for (int k = 0; k < MN; k++) { float a = MA[i * MN + k];
#if SIMD
        v4f av = {a, a, a, a};
        for (int j = 0; j < MN; j += 4) { v4f c = *(v4f *)(MC + i * MN + j); c += av * *(const v4f *)(MB + k * MN + j); *(v4f *)(MC + i * MN + j) = c; }
#else
        for (int j = 0; j < MN; j++) MC[i * MN + j] += a * MB[k * MN + j];
#endif
    }
}
/* 2. n-body, 1024 bodies, double precision, O(n^2) step */
#define NB 1024
static double px[NB], py[NB], pz[NB], vx[NB], vy[NB], vz[NB], mass[NB];
static void nbody(void) {
    for (int i = 0; i < NB; i++) { double ax = 0, ay = 0, az = 0;
        for (int j = 0; j < NB; j++) { double dx = px[j] - px[i], dy = py[j] - py[i], dz = pz[j] - pz[i], d2 = dx * dx + dy * dy + dz * dz + 0.01, inv = 1.0 / sqrt(d2), f = mass[j] * inv * inv * inv; ax += dx * f; ay += dy * f; az += dz * f; }
        vx[i] += ax * 0.01; vy[i] += ay * 0.01; vz[i] += az * 0.01; }
    for (int i = 0; i < NB; i++) { px[i] += vx[i] * 0.01; py[i] += vy[i] * 0.01; pz[i] += vz[i] * 0.01; }
}
/* 3. branchy integer code: a tiny bytecode interpreter loop (what a scripting VM written in C++ looks like) */
static uint32_t prog[256];
static uint64_t interp(uint32_t iters) {
    uint64_t acc = 1, r[8] = {1, 2, 3, 4, 5, 6, 7, 8}; uint32_t pc = 0;
    for (uint32_t n = 0; n < iters; n++) { uint32_t ins = prog[pc & 255]; pc++;
        switch (ins & 7) { case 0: r[(ins >> 3) & 7] += r[(ins >> 6) & 7]; break; case 1: r[(ins >> 3) & 7] ^= (r[(ins >> 6) & 7] << 3); break; case 2: acc += r[(ins >> 3) & 7]; break;
            case 3: r[(ins >> 3) & 7] = acc ^ ins; break; case 4: if (r[(ins >> 3) & 7] & 1) pc += (ins >> 9) & 3; break; case 5: r[(ins >> 3) & 7] *= 31; break; case 6: acc = (acc << 5) | (acc >> 59); break; default: acc -= r[(ins >> 6) & 7]; } }
    return acc ^ r[0] ^ r[3];
}
/* 4. memory streaming: triad a[i] = b[i] + s*c[i] over 32 MB arrays */
#define SN (1 << 22)
static float SA[SN], SB[SN], SC[SN];
static void triad(void) { for (int i = 0; i < SN; i++) SA[i] = SB[i] + 1.5f * SC[i]; }
/* 5. bit manipulation / hashing (xxhash-like mixing over 64 MB) */
static uint8_t buf[1 << 24];
static uint64_t hash(void) { uint64_t h = 0x9E3779B97F4A7C15ull; const uint64_t *p = (const uint64_t *)buf; for (size_t i = 0; i < sizeof buf / 8; i++) { h ^= p[i] * 0xC2B2AE3D27D4EB4Full; h = (h << 31 | h >> 33) * 0x9E3779B185EBCA87ull; } return h; }
/* 6. sorting 1M ints with our own quicksort (indirect calls through the comparison callback; libc qsort differs between libcs and would measure the libc, not the engine) */
static int cmp(const void *a, const void *b) { int x = *(const int *)a, y = *(const int *)b; return (x > y) - (x < y); }
static void qs(int *a, long lo, long hi, int (*c)(const void *, const void *)) {
    while (hi - lo > 16) { int p = a[(lo + hi) / 2]; long i = lo, j = hi;
        while (i <= j) { while (c(&a[i], &p) < 0) i++; while (c(&a[j], &p) > 0) j--; if (i <= j) { int t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; } }
        if (j - lo < hi - i) { qs(a, lo, j, c); lo = i; } else { qs(a, i, hi, c); hi = j; } }
    for (long i = lo + 1; i <= hi; i++) { int v = a[i]; long k = i - 1; while (k >= lo && c(&a[k], &v) > 0) { a[k + 1] = a[k]; k--; } a[k + 1] = v; }
}
static int ints[1 << 20], ints0[1 << 20];
/* 7. vertex transform (as in the earlier benchmark) */
#define NV (1 << 18)
static float M4[16], V4[NV * 4], O4[NV * 4];
static void transform(void) {
#if SIMD
    const v4f c0 = {M4[0], M4[1], M4[2], M4[3]}, c1 = {M4[4], M4[5], M4[6], M4[7]}, c2 = {M4[8], M4[9], M4[10], M4[11]}, c3 = {M4[12], M4[13], M4[14], M4[15]};
    for (int i = 0; i < NV; i++) { const float x = V4[4*i], y = V4[4*i+1], z = V4[4*i+2], w = V4[4*i+3];
        v4f r = c0 * (v4f){x,x,x,x} + c1 * (v4f){y,y,y,y} + c2 * (v4f){z,z,z,z} + c3 * (v4f){w,w,w,w}; O4[4*i] = r[0]; O4[4*i+1] = r[1]; O4[4*i+2] = r[2]; O4[4*i+3] = r[3]; }
#else
    for (int i = 0; i < NV; i++) { const float x = V4[4*i], y = V4[4*i+1], z = V4[4*i+2], w = V4[4*i+3];
        for (int r = 0; r < 4; r++) O4[4*i+r] = M4[r]*x + M4[4+r]*y + M4[8+r]*z + M4[12+r]*w; }
#endif
}
static uint64_t fsum(const float *p, int n) { double s = 0; for (int i = 0; i < n; i += 7) s += p[i]; return (uint64_t)(int64_t)(s * 16.0); }

int main(void) {
    for (int i = 0; i < MN * MN; i++) { MA[i] = (float)(i % 13) * 0.25f; MB[i] = (float)(i % 7) * 0.5f; }
    for (int i = 0; i < NB; i++) { px[i] = i * 0.37; py[i] = (i * 7 % 101) * 0.1; pz[i] = (i * 13 % 89) * 0.2; vx[i] = vy[i] = vz[i] = 0; mass[i] = 1.0 + (i % 5); }
    for (int i = 0; i < 256; i++) prog[i] = (uint32_t)(i * 2654435761u) >> 4;
    for (int i = 0; i < SN; i++) { SB[i] = (float)(i & 1023); SC[i] = (float)(i & 255); }
    for (size_t i = 0; i < sizeof buf; i++) buf[i] = (uint8_t)(i * 131 + (i >> 8));
    for (int i = 0; i < (1 << 20); i++) ints0[i] = (int)((uint32_t)i * 2654435761u >> 3);
    for (int i = 0; i < 16; i++) M4[i] = 0.5f + 0.01f * i;
    for (int i = 0; i < NV * 4; i++) V4[i] = (float)(i % 97) * 0.25f;
    BEST("matmul256", 5, matmul(), fsum(MC, MN * MN));
    BEST("nbody1024", 5, nbody(), (uint64_t)(int64_t)(px[5] * 1e6) ^ (uint64_t)(int64_t)(vz[9] * 1e9));
    BEST("interp", 5, sink += interp(60000000), interp(1000));
    BEST("triad32MB", 7, triad(), fsum(SA, SN));
    BEST("hash16MB", 7, sink += hash(), hash());
    BEST("sort1M", 3, { memcpy(ints, ints0, sizeof ints); qs(ints, 0, (1 << 20) - 1, cmp); }, (uint64_t)ints[12345] + ints[999999]);
    BEST("transform", 7, transform(), fsum(O4, NV * 4));
    return sink == 12345;
}
