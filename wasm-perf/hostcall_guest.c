/* Guest for the host-kernel experiment: times (a) the cost of one call into an imported host function and (b) the same numeric work done by wasm SIMD128 code in the module
 * versus a native kernel (AVX2/FMA, AVX-512, NEON, chosen at run time by the host) that reads and writes this module's linear memory in place.
 * Prints: CALL <name> <ns per call> / SAXPY|DOT|MATMUL <n> <wasm ns> <host ns> <result check>. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#define IMP(n) __attribute__((import_module("h"), import_name(n)))
IMP("nop") void h_nop(void);
IMP("nop3") int h_nop3(int, int, int);
IMP("nopmem") void h_nopmem(void *p);
IMP("nopcached") void h_nopcached(void *p);
IMP("kind") int h_kind(void);
IMP("saxpy") void h_saxpy(float a, const float *x, float *y, int n);
IMP("sdot") float h_sdot(const float *x, const float *y, int n);
IMP("matmul") void h_matmul(const float *A, const float *B, float *C, int n);
typedef float v4f __attribute__((vector_size(16)));
typedef float v4fu __attribute__((vector_size(16), aligned(4), may_alias));
static double now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
static void __attribute__((noinline)) g_nop(void) { __asm__ volatile(""); }
#define MAXN 65536
static float X[MAXN], Y[MAXN], Y2[MAXN], MA[256 * 256], MB[256 * 256], MC[256 * 256], MC2[256 * 256];
static void w_saxpy(float a, const float *x, float *y, int n) {   /* SIMD128, unrolled 4x */
    v4f av = {a, a, a, a}; int i = 0;
    for (; i + 16 <= n; i += 16) { for (int u = 0; u < 4; u++) *(v4fu *)(y + i + 4 * u) += av * *(const v4fu *)(x + i + 4 * u); }
    for (; i < n; i++) y[i] += a * x[i];
}
static float w_sdot(const float *x, const float *y, int n) {   /* 4 independent SIMD128 accumulators; the host kernel sums in a different order, so only compare approximately */
    v4f s0 = {0}, s1 = {0}, s2 = {0}, s3 = {0}; int i = 0;
    for (; i + 16 <= n; i += 16) { s0 += *(const v4fu *)(x + i) * *(const v4fu *)(y + i); s1 += *(const v4fu *)(x + i + 4) * *(const v4fu *)(y + i + 4); s2 += *(const v4fu *)(x + i + 8) * *(const v4fu *)(y + i + 8); s3 += *(const v4fu *)(x + i + 12) * *(const v4fu *)(y + i + 12); }
    v4f s = (s0 + s1) + (s2 + s3); float r = s[0] + s[1] + s[2] + s[3]; for (; i < n; i++) r += x[i] * y[i]; return r;
}
#define KC 64   /* cache blocking: a KC x JC tile of B (16 KB) stays in L1 while every row pair of A streams past it */
#define JC 64
static void w_matmul(const float *A, const float *B, float *C, int n) {   /* tile over k and j, register-block 2 rows x 16 columns (8 v128 accumulators); n even, >= 8 */
    memset(C, 0, (size_t)n * n * 4);
    for (int kb = 0; kb < n; kb += KC) { int ke = kb + KC < n ? kb + KC : n;
        for (int jb = 0; jb < n; jb += JC) { int je = jb + JC < n ? jb + JC : n;
            for (int i = 0; i < n; i += 2) { int j = jb;
                for (; j + 16 <= je; j += 16) { v4f c[2][4]; for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) c[r][u] = *(const v4fu *)(C + (i + r) * n + j + 4 * u);
                    for (int k = kb; k < ke; k++) { v4f b[4]; for (int u = 0; u < 4; u++) b[u] = *(const v4fu *)(B + k * n + j + 4 * u);
                        for (int r = 0; r < 2; r++) { float a = A[(i + r) * n + k]; v4f av = {a, a, a, a}; for (int u = 0; u < 4; u++) c[r][u] += av * b[u]; } }
                    for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) *(v4fu *)(C + (i + r) * n + j + 4 * u) = c[r][u]; }
                for (; j + 4 <= je; j += 4) { v4f c0 = *(const v4fu *)(C + i * n + j), c1 = *(const v4fu *)(C + (i + 1) * n + j);
                    for (int k = kb; k < ke; k++) { v4f b = *(const v4fu *)(B + k * n + j); float a0 = A[i * n + k], a1 = A[(i + 1) * n + k]; c0 += (v4f){a0, a0, a0, a0} * b; c1 += (v4f){a1, a1, a1, a1} * b; }
                    *(v4fu *)(C + i * n + j) = c0; *(v4fu *)(C + (i + 1) * n + j) = c1; } } } }
}
/* time fn(): calibrate the repeat count to >= 4 ms, then best of 7 */
#define TIME_NS(fn_stmt, out) do { long it = 1; for (;;) { double t0 = now_ns(); for (long q = 0; q < it; q++) { fn_stmt; } double dt = now_ns() - t0; if (dt > 4e6 || it > (1L << 28)) break; it *= (dt < 1e5 ? 16 : 2); } \
    double best = 1e30; for (int r = 0; r < 7; r++) { double t0 = now_ns(); for (long q = 0; q < it; q++) { fn_stmt; } double dt = (now_ns() - t0) / it; if (dt < best) best = dt; } (out) = best; } while (0)
static volatile int sinki; static volatile float sinkf;
int main(void) {
    for (int i = 0; i < MAXN; i++) { X[i] = (float)(i % 17) * 0.5f; Y[i] = (float)(i % 5) * 0.25f; }
    for (int i = 0; i < 256 * 256; i++) { MA[i] = (float)(i % 13) * 0.25f; MB[i] = (float)(i % 7) * 0.5f; }
    int kind = h_kind(); printf("HOSTKERNEL %s\n", kind == 1 ? "avx2+fma" : kind == 2 ? "avx512f" : kind == 3 ? "neon" : "scalar");
    double ns;
    TIME_NS(g_nop(), ns); printf("CALL wasm-to-wasm-noinline %.2f\n", ns);
    TIME_NS(h_nop(), ns); printf("CALL import-nop %.2f\n", ns);
    TIME_NS(sinki = h_nop3(1, 2, 3), ns); printf("CALL import-3args-1result %.2f\n", ns);
    TIME_NS(h_nopmem(X), ns); printf("CALL import-memory-lookup-by-name %.2f\n", ns);
    TIME_NS(h_nopcached(X), ns); printf("CALL import-memory-handle-cached %.2f\n", ns);
    static const int sizes[] = {8, 16, 32, 64, 128, 256, 512, 1024, 4096, 16384, 65536};
    for (unsigned s = 0; s < sizeof sizes / sizeof *sizes; s++) { int n = sizes[s]; double w, h;
        memcpy(Y2, Y, sizeof Y); TIME_NS(w_saxpy(1.0f, X, Y2, n), w); memcpy(Y2, Y, sizeof Y); TIME_NS(h_saxpy(1.0f, X, Y2, n), h);
        /* correctness on fresh data: one application each */
        memcpy(Y2, Y, sizeof Y); w_saxpy(0.5f, X, Y2, n); memcpy(MC, Y, sizeof Y); h_saxpy(0.5f, X, MC, n); int ok = !memcmp(Y2, MC, (size_t)n * 4);
        printf("SAXPY %d %.1f %.1f %s\n", n, w, h, ok ? "same" : "DIFFERENT"); }
    for (unsigned s = 0; s < sizeof sizes / sizeof *sizes; s++) { int n = sizes[s]; double w, h; float a, b;
        TIME_NS(sinkf = w_sdot(X, Y, n), w); TIME_NS(sinkf = h_sdot(X, Y, n), h); a = w_sdot(X, Y, n); b = h_sdot(X, Y, n);
        printf("DOT %d %.1f %.1f %s\n", n, w, h, (a - b < 1e-3f * (a < 0 ? -a : a) + 1e-3f && b - a < 1e-3f * (a < 0 ? -a : a) + 1e-3f) ? "same" : "DIFFERENT"); }
    static const int msz[] = {8, 16, 32, 64, 128, 256};
    for (unsigned s = 0; s < sizeof msz / sizeof *msz; s++) { int n = msz[s]; double w, h;
        TIME_NS(w_matmul(MA, MB, MC, n), w); TIME_NS(h_matmul(MA, MB, MC2, n), h); w_matmul(MA, MB, MC, n); h_matmul(MA, MB, MC2, n);
        printf("MATMUL %d %.1f %.1f %s\n", n, w, h, !memcmp(MC, MC2, (size_t)n * n * 4) ? "same" : "DIFFERENT"); }
    return 0;
}
