/* Float kernels three ways, timed inside wasm: (1) written with wasm SIMD128, (2) the host's native kernel through the "native" imports (instruction set chosen at start-up: AVX2+FMA / AVX-512F / NEON),
 * (3) plain scalar C. Prints "K <op> <impl> <size> <microseconds per call>" and "C <op> <size> <max difference between wasm SIMD128 and native>". */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wasm_simd128.h>
#define IMPORT(n) __attribute__((import_module("native"), import_name(n)))
IMPORT("cpu_level") int nat_level(void);
IMPORT("saxpy_f32") void nat_saxpy(int n, float a, const float *x, float *y);
IMPORT("dot_f32") float nat_dot(int n, const float *x, const float *y);
IMPORT("matmul_f32") void nat_matmul(int m, int n, int k, const float *A, const float *B, float *C);

static double now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }
static void s_saxpy(int n, float a, const float *x, float *y) { for (int i = 0; i < n; i++) y[i] += a * x[i]; }
static float s_dot(int n, const float *x, const float *y) { float s = 0; for (int i = 0; i < n; i++) s += x[i] * y[i]; return s; }
static void s_matmul(int m, int n, int k, const float *A, const float *B, float *C) {
    for (int i = 0; i < m; i++) { for (int j = 0; j < n; j++) C[i * n + j] = 0; for (int p = 0; p < k; p++) { float a = A[i * k + p]; for (int j = 0; j < n; j++) C[i * n + j] += a * B[p * n + j]; } }
}
/* wasm SIMD128, written to give the code generator independent work: two vectors per step (saxpy), four accumulators (dot), a 4 x 8 register tile (matmul) */
static void w_saxpy(int n, float a, const float *x, float *y) {
    v128_t va = wasm_f32x4_splat(a); int i = 0;
    for (; i + 8 <= n; i += 8) { wasm_v128_store(y + i, wasm_f32x4_add(wasm_v128_load(y + i), wasm_f32x4_mul(va, wasm_v128_load(x + i)))); wasm_v128_store(y + i + 4, wasm_f32x4_add(wasm_v128_load(y + i + 4), wasm_f32x4_mul(va, wasm_v128_load(x + i + 4)))); }
    for (; i < n; i++) y[i] += a * x[i];
}
static float w_dot(int n, const float *x, const float *y) {
    v128_t s0 = wasm_f32x4_splat(0), s1 = s0, s2 = s0, s3 = s0; int i = 0;
    for (; i + 16 <= n; i += 16) { s0 = wasm_f32x4_add(s0, wasm_f32x4_mul(wasm_v128_load(x + i), wasm_v128_load(y + i))); s1 = wasm_f32x4_add(s1, wasm_f32x4_mul(wasm_v128_load(x + i + 4), wasm_v128_load(y + i + 4))); s2 = wasm_f32x4_add(s2, wasm_f32x4_mul(wasm_v128_load(x + i + 8), wasm_v128_load(y + i + 8))); s3 = wasm_f32x4_add(s3, wasm_f32x4_mul(wasm_v128_load(x + i + 12), wasm_v128_load(y + i + 12))); }
    v128_t t = wasm_f32x4_add(wasm_f32x4_add(s0, s1), wasm_f32x4_add(s2, s3));
    float s = wasm_f32x4_extract_lane(t, 0) + wasm_f32x4_extract_lane(t, 1) + wasm_f32x4_extract_lane(t, 2) + wasm_f32x4_extract_lane(t, 3);
    for (; i < n; i++) s += x[i] * y[i]; return s;
}
static void w_matmul(int m, int n, int k, const float *A, const float *B, float *C) {
    int mi = m & ~3, nj = n & ~7;
    for (int i = 0; i < mi; i += 4) for (int j = 0; j < nj; j += 8) {
        v128_t c00 = wasm_f32x4_splat(0), c01 = c00, c10 = c00, c11 = c00, c20 = c00, c21 = c00, c30 = c00, c31 = c00;
        for (int p = 0; p < k; p++) {
            v128_t b0 = wasm_v128_load(B + p * n + j), b1 = wasm_v128_load(B + p * n + j + 4), a;
            a = wasm_f32x4_splat(A[(i + 0) * k + p]); c00 = wasm_f32x4_add(c00, wasm_f32x4_mul(a, b0)); c01 = wasm_f32x4_add(c01, wasm_f32x4_mul(a, b1));
            a = wasm_f32x4_splat(A[(i + 1) * k + p]); c10 = wasm_f32x4_add(c10, wasm_f32x4_mul(a, b0)); c11 = wasm_f32x4_add(c11, wasm_f32x4_mul(a, b1));
            a = wasm_f32x4_splat(A[(i + 2) * k + p]); c20 = wasm_f32x4_add(c20, wasm_f32x4_mul(a, b0)); c21 = wasm_f32x4_add(c21, wasm_f32x4_mul(a, b1));
            a = wasm_f32x4_splat(A[(i + 3) * k + p]); c30 = wasm_f32x4_add(c30, wasm_f32x4_mul(a, b0)); c31 = wasm_f32x4_add(c31, wasm_f32x4_mul(a, b1));
        }
        float *c = C + i * n + j;
        wasm_v128_store(c, c00); wasm_v128_store(c + 4, c01); wasm_v128_store(c + n, c10); wasm_v128_store(c + n + 4, c11); wasm_v128_store(c + 2 * n, c20); wasm_v128_store(c + 2 * n + 4, c21); wasm_v128_store(c + 3 * n, c30); wasm_v128_store(c + 3 * n + 4, c31);
    }
    for (int i = 0; i < m; i++) for (int j = (i < mi ? nj : 0); j < n; j++) { float s = 0; for (int p = 0; p < k; p++) s += A[i * k + p] * B[p * n + j]; C[i * n + j] = s; }
}
static volatile float sink;
#define TIME(var, reps, body) do { int R = (reps); double t0 = now_us(); for (int r = 0; r < R; r++) { body; } var = (now_us() - t0) / R; } while (0)
static int reps_for(double work) { double r = 4e7 / work; return r < 3 ? 3 : r > 100000 ? 100000 : (int)r; }
int main(void) {
    printf("native level %d\n", nat_level());
    int sizes[] = {64, 1024, 16384, 262144};
    for (int si = 0; si < 4; si++) {
        int n = sizes[si]; float *x = malloc(n * 4), *y = malloc(n * 4), *y2 = malloc(n * 4);
        for (int i = 0; i < n; i++) { x[i] = (float)((i * 37) % 101) / 50 - 1; y[i] = (float)((i * 53) % 97) / 48 - 1; }
        double tw, tn, ts; int reps = reps_for(n);
        memcpy(y2, y, n * 4); w_saxpy(n, 0.5f, x, y2); memcpy(y, y2, n * 4); float wd = w_dot(n, x, y2);   /* a result to compare with the native one */
        float *yn = malloc(n * 4); memcpy(yn, y2, n * 4); (void)yn;
        TIME(tw, reps, w_saxpy(n, 1e-9f, x, y2)); TIME(tn, reps, nat_saxpy(n, 1e-9f, x, y2)); TIME(ts, reps, s_saxpy(n, 1e-9f, x, y2));
        printf("K saxpy wasm-simd128 %d %.3f\nK saxpy native %d %.3f\nK saxpy scalar %d %.3f\n", n, tw, n, tn, n, ts);
        float nd = nat_dot(n, x, y2), sd = s_dot(n, x, y2); float rel = fabsf(nd - wd) / (fabsf(wd) + 1); float rel2 = fabsf(sd - nd) / (fabsf(nd) + 1);
        printf("C dot %d %.3g %.3g\n", n, rel, rel2);
        TIME(tw, reps, sink = w_dot(n, x, y2)); TIME(tn, reps, sink = nat_dot(n, x, y2)); TIME(ts, reps, sink = s_dot(n, x, y2));
        printf("K dot wasm-simd128 %d %.3f\nK dot native %d %.3f\nK dot scalar %d %.3f\n", n, tw, n, tn, n, ts);
        free(x); free(y); free(y2); free(yn);
    }
    int dims[] = {16, 64, 256};
    for (int di = 0; di < 3; di++) {
        int d = dims[di]; float *A = malloc(d * d * 4), *B = malloc(d * d * 4), *C1 = malloc(d * d * 4), *C2 = malloc(d * d * 4), *C3 = malloc(d * d * 4);
        for (int i = 0; i < d * d; i++) { A[i] = (float)((i * 13) % 17) / 8 - 1; B[i] = (float)((i * 7) % 19) / 9 - 1; }
        w_matmul(d, d, d, A, B, C1); nat_matmul(d, d, d, A, B, C2); s_matmul(d, d, d, A, B, C3);
        double worst = 0; for (int i = 0; i < d * d; i++) { double e = fabs((double)C1[i] - C2[i]); if (e > worst) worst = e; double e2 = fabs((double)C3[i] - C2[i]); if (e2 > worst) worst = e2; }
        double tw, tn, ts; double work = 2.0 * d * d * d; int reps = reps_for(work / 4);
        TIME(tw, reps, w_matmul(d, d, d, A, B, C1)); TIME(tn, reps, nat_matmul(d, d, d, A, B, C2)); TIME(ts, reps, s_matmul(d, d, d, A, B, C3));
        printf("C matmul %d %.3g %.3g\nK matmul wasm-simd128 %d %.3f\nK matmul native %d %.3f\nK matmul scalar %d %.3f\n", d, worst, worst, d, tw, d, tn, d, ts);
        free(A); free(B); free(C1); free(C2); free(C3);
    }
    return 0;
}
