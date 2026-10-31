#define _COSMO_SOURCE
#include <cosmo.h>
#include <stdlib.h>
#include <string.h>
#include "native_kernels.h"
#if defined(__x86_64__)
#include <immintrin.h>
#include <libc/nexgen32e/x86feature.h>
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif

/* ---- baseline: the plain loops (also the reference for the tests) ---- */
static void saxpy0(size_t n, float a, const float *x, float *y) { for (size_t i = 0; i < n; i++) y[i] += a * x[i]; }
static float dot0(size_t n, const float *x, const float *y) { float s = 0; for (size_t i = 0; i < n; i++) s += x[i] * y[i]; return s; }
static void matmul0(size_t m, size_t n, size_t k, const float *A, const float *B, float *C) {
    for (size_t i = 0; i < m; i++) { for (size_t j = 0; j < n; j++) C[i * n + j] = 0; for (size_t p = 0; p < k; p++) { float a = A[i * k + p]; for (size_t j = 0; j < n; j++) C[i * n + j] += a * B[p * n + j]; } }
}
/* the rows and columns a register tile does not cover */
static void mm_edges(size_t m, size_t n, size_t k, const float *A, const float *B, float *C, size_t mi, size_t nj) {
    for (size_t i = 0; i < m; i++) for (size_t j = (i < mi ? nj : 0); j < n; j++) { float s = 0; for (size_t p = 0; p < k; p++) s += A[i * k + p] * B[p * n + j]; C[i * n + j] = s; }
}

#if defined(__x86_64__)
/* ---- AVX2 + FMA ---- */
__attribute__((target("avx2,fma"))) static void saxpy1(size_t n, float a, const float *x, float *y) {
    __m256 va = _mm256_set1_ps(a); size_t i = 0;
    for (; i + 16 <= n; i += 16) { _mm256_storeu_ps(y + i, _mm256_fmadd_ps(va, _mm256_loadu_ps(x + i), _mm256_loadu_ps(y + i))); _mm256_storeu_ps(y + i + 8, _mm256_fmadd_ps(va, _mm256_loadu_ps(x + i + 8), _mm256_loadu_ps(y + i + 8))); }
    for (; i < n; i++) y[i] += a * x[i];
}
__attribute__((target("avx2,fma"))) static float dot1(size_t n, const float *x, const float *y) {
    __m256 s0 = _mm256_setzero_ps(), s1 = s0, s2 = s0, s3 = s0; size_t i = 0;
    for (; i + 32 <= n; i += 32) { s0 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i), _mm256_loadu_ps(y + i), s0); s1 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i + 8), _mm256_loadu_ps(y + i + 8), s1); s2 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i + 16), _mm256_loadu_ps(y + i + 16), s2); s3 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i + 24), _mm256_loadu_ps(y + i + 24), s3); }
    s0 = _mm256_add_ps(_mm256_add_ps(s0, s1), _mm256_add_ps(s2, s3));
    __m128 h = _mm_add_ps(_mm256_castps256_ps128(s0), _mm256_extractf128_ps(s0, 1)); h = _mm_add_ps(h, _mm_movehl_ps(h, h)); h = _mm_add_ss(h, _mm_shuffle_ps(h, h, 1));
    float s = _mm_cvtss_f32(h); for (; i < n; i++) s += x[i] * y[i]; return s;
}
__attribute__((target("avx2,fma"))) static void matmul1(size_t m, size_t n, size_t k, const float *A, const float *B, float *C) {
    size_t mi = m & ~(size_t)3, nj = n & ~(size_t)15;
    for (size_t i = 0; i < mi; i += 4) for (size_t j = 0; j < nj; j += 16) {
        __m256 c00 = _mm256_setzero_ps(), c01 = c00, c10 = c00, c11 = c00, c20 = c00, c21 = c00, c30 = c00, c31 = c00;
        for (size_t p = 0; p < k; p++) {
            __m256 b0 = _mm256_loadu_ps(B + p * n + j), b1 = _mm256_loadu_ps(B + p * n + j + 8), a;
            a = _mm256_broadcast_ss(A + (i + 0) * k + p); c00 = _mm256_fmadd_ps(a, b0, c00); c01 = _mm256_fmadd_ps(a, b1, c01);
            a = _mm256_broadcast_ss(A + (i + 1) * k + p); c10 = _mm256_fmadd_ps(a, b0, c10); c11 = _mm256_fmadd_ps(a, b1, c11);
            a = _mm256_broadcast_ss(A + (i + 2) * k + p); c20 = _mm256_fmadd_ps(a, b0, c20); c21 = _mm256_fmadd_ps(a, b1, c21);
            a = _mm256_broadcast_ss(A + (i + 3) * k + p); c30 = _mm256_fmadd_ps(a, b0, c30); c31 = _mm256_fmadd_ps(a, b1, c31);
        }
        float *c = C + i * n + j;
        _mm256_storeu_ps(c, c00); _mm256_storeu_ps(c + 8, c01); _mm256_storeu_ps(c + n, c10); _mm256_storeu_ps(c + n + 8, c11);
        _mm256_storeu_ps(c + 2 * n, c20); _mm256_storeu_ps(c + 2 * n + 8, c21); _mm256_storeu_ps(c + 3 * n, c30); _mm256_storeu_ps(c + 3 * n + 8, c31);
    }
    mm_edges(m, n, k, A, B, C, mi, nj);
}
/* ---- AVX-512F ---- */
__attribute__((target("avx512f"))) static void saxpy2(size_t n, float a, const float *x, float *y) {
    __m512 va = _mm512_set1_ps(a); size_t i = 0;
    for (; i + 32 <= n; i += 32) { _mm512_storeu_ps(y + i, _mm512_fmadd_ps(va, _mm512_loadu_ps(x + i), _mm512_loadu_ps(y + i))); _mm512_storeu_ps(y + i + 16, _mm512_fmadd_ps(va, _mm512_loadu_ps(x + i + 16), _mm512_loadu_ps(y + i + 16))); }
    for (; i < n; i++) y[i] += a * x[i];
}
__attribute__((target("avx512f"))) static float dot2(size_t n, const float *x, const float *y) {
    __m512 s0 = _mm512_setzero_ps(), s1 = s0, s2 = s0, s3 = s0; size_t i = 0;
    for (; i + 64 <= n; i += 64) { s0 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i), _mm512_loadu_ps(y + i), s0); s1 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i + 16), _mm512_loadu_ps(y + i + 16), s1); s2 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i + 32), _mm512_loadu_ps(y + i + 32), s2); s3 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i + 48), _mm512_loadu_ps(y + i + 48), s3); }
    float s = _mm512_reduce_add_ps(_mm512_add_ps(_mm512_add_ps(s0, s1), _mm512_add_ps(s2, s3)));
    for (; i < n; i++) s += x[i] * y[i]; return s;
}
__attribute__((target("avx512f"))) static void matmul2(size_t m, size_t n, size_t k, const float *A, const float *B, float *C) {
    size_t mi = m & ~(size_t)3, nj = n & ~(size_t)31;
    for (size_t i = 0; i < mi; i += 4) for (size_t j = 0; j < nj; j += 32) {
        __m512 c00 = _mm512_setzero_ps(), c01 = c00, c10 = c00, c11 = c00, c20 = c00, c21 = c00, c30 = c00, c31 = c00;
        for (size_t p = 0; p < k; p++) {
            __m512 b0 = _mm512_loadu_ps(B + p * n + j), b1 = _mm512_loadu_ps(B + p * n + j + 16), a;
            a = _mm512_set1_ps(A[(i + 0) * k + p]); c00 = _mm512_fmadd_ps(a, b0, c00); c01 = _mm512_fmadd_ps(a, b1, c01);
            a = _mm512_set1_ps(A[(i + 1) * k + p]); c10 = _mm512_fmadd_ps(a, b0, c10); c11 = _mm512_fmadd_ps(a, b1, c11);
            a = _mm512_set1_ps(A[(i + 2) * k + p]); c20 = _mm512_fmadd_ps(a, b0, c20); c21 = _mm512_fmadd_ps(a, b1, c21);
            a = _mm512_set1_ps(A[(i + 3) * k + p]); c30 = _mm512_fmadd_ps(a, b0, c30); c31 = _mm512_fmadd_ps(a, b1, c31);
        }
        float *c = C + i * n + j;
        _mm512_storeu_ps(c, c00); _mm512_storeu_ps(c + 16, c01); _mm512_storeu_ps(c + n, c10); _mm512_storeu_ps(c + n + 16, c11);
        _mm512_storeu_ps(c + 2 * n, c20); _mm512_storeu_ps(c + 2 * n + 16, c21); _mm512_storeu_ps(c + 3 * n, c30); _mm512_storeu_ps(c + 3 * n + 16, c31);
    }
    mm_edges(m, n, k, A, B, C, mi, nj);
}
static uint64_t xgetbv0(void) { uint32_t lo, hi; __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0)); return ((uint64_t)hi << 32) | lo; }
static int max_level(void) {
    if (!X86_HAVE(AVX) || !X86_HAVE(AVX2) || !X86_HAVE(FMA) || !X86_HAVE(OSXSAVE)) return 0;
    uint64_t x = xgetbv0(); if ((x & 6) != 6) return 0;                    /* the OS saves the YMM state */
    if (X86_HAVE(AVX512F) && (x & 0xE6) == 0xE6) return 2;                 /* ... and the opmask / ZMM state */
    return 1;
}
#elif defined(__aarch64__)
static void saxpy1(size_t n, float a, const float *x, float *y) {
    size_t i = 0; for (; i + 8 <= n; i += 8) { vst1q_f32(y + i, vfmaq_n_f32(vld1q_f32(y + i), vld1q_f32(x + i), a)); vst1q_f32(y + i + 4, vfmaq_n_f32(vld1q_f32(y + i + 4), vld1q_f32(x + i + 4), a)); }
    for (; i < n; i++) y[i] += a * x[i];
}
static float dot1(size_t n, const float *x, const float *y) {
    float32x4_t s0 = vdupq_n_f32(0), s1 = s0, s2 = s0, s3 = s0; size_t i = 0;
    for (; i + 16 <= n; i += 16) { s0 = vfmaq_f32(s0, vld1q_f32(x + i), vld1q_f32(y + i)); s1 = vfmaq_f32(s1, vld1q_f32(x + i + 4), vld1q_f32(y + i + 4)); s2 = vfmaq_f32(s2, vld1q_f32(x + i + 8), vld1q_f32(y + i + 8)); s3 = vfmaq_f32(s3, vld1q_f32(x + i + 12), vld1q_f32(y + i + 12)); }
    float s = vaddvq_f32(vaddq_f32(vaddq_f32(s0, s1), vaddq_f32(s2, s3))); for (; i < n; i++) s += x[i] * y[i]; return s;
}
static void matmul1(size_t m, size_t n, size_t k, const float *A, const float *B, float *C) {
    size_t mi = m & ~(size_t)3, nj = n & ~(size_t)7;
    for (size_t i = 0; i < mi; i += 4) for (size_t j = 0; j < nj; j += 8) {
        float32x4_t c00 = vdupq_n_f32(0), c01 = c00, c10 = c00, c11 = c00, c20 = c00, c21 = c00, c30 = c00, c31 = c00;
        for (size_t p = 0; p < k; p++) {
            float32x4_t b0 = vld1q_f32(B + p * n + j), b1 = vld1q_f32(B + p * n + j + 4);
            float a0 = A[(i + 0) * k + p], a1 = A[(i + 1) * k + p], a2 = A[(i + 2) * k + p], a3 = A[(i + 3) * k + p];
            c00 = vfmaq_n_f32(c00, b0, a0); c01 = vfmaq_n_f32(c01, b1, a0); c10 = vfmaq_n_f32(c10, b0, a1); c11 = vfmaq_n_f32(c11, b1, a1);
            c20 = vfmaq_n_f32(c20, b0, a2); c21 = vfmaq_n_f32(c21, b1, a2); c30 = vfmaq_n_f32(c30, b0, a3); c31 = vfmaq_n_f32(c31, b1, a3);
        }
        float *c = C + i * n + j;
        vst1q_f32(c, c00); vst1q_f32(c + 4, c01); vst1q_f32(c + n, c10); vst1q_f32(c + n + 4, c11); vst1q_f32(c + 2 * n, c20); vst1q_f32(c + 2 * n + 4, c21); vst1q_f32(c + 3 * n, c30); vst1q_f32(c + 3 * n + 4, c31);
    }
    mm_edges(m, n, k, A, B, C, mi, nj);
}
static int max_level(void) { return 1; }
#else
static int max_level(void) { return 0; }
#endif

int nk_haswell_ok(void) {
#if defined(__x86_64__)
    return max_level() >= 1 && X86_HAVE(BMI) && X86_HAVE(BMI2) && X86_HAVE(ABM) && X86_HAVE(POPCNT) && X86_HAVE(SSE4_2);
#else
    return 0;
#endif
}
static int g_level = -1;
static void (*p_saxpy)(size_t, float, const float *, float *) = saxpy0;
static float (*p_dot)(size_t, const float *, const float *) = dot0;
static void (*p_matmul)(size_t, size_t, size_t, const float *, const float *, float *) = matmul0;
int nk_init(void) {
    int want = max_level(); const char *e = getenv("WN_KERNEL_LEVEL"); if (e && *e) { int w = atoi(e); if (w < want) want = w < 0 ? 0 : w; }
    g_level = want;
#if defined(__x86_64__)
    if (want >= 1) { p_saxpy = saxpy1; p_dot = dot1; p_matmul = matmul1; }
    if (want >= 2) { p_saxpy = saxpy2; p_dot = dot2; p_matmul = matmul2; }
#elif defined(__aarch64__)
    if (want >= 1) { p_saxpy = saxpy1; p_dot = dot1; p_matmul = matmul1; }
#endif
    return g_level;
}
int nk_level(void) { return g_level < 0 ? nk_init() : g_level; }
const char *nk_level_name(void) {
    int l = nk_level();
#if defined(__x86_64__)
    return l == 2 ? "avx512f" : l == 1 ? "avx2+fma" : "baseline";
#elif defined(__aarch64__)
    return l == 1 ? "neon+fma" : "baseline";
#else
    return "baseline";
#endif
}
void nk_saxpy(size_t n, float a, const float *x, float *y) { p_saxpy(n, a, x, y); }
float nk_dot(size_t n, const float *x, const float *y) { return p_dot(n, x, y); }
void nk_matmul(size_t m, size_t n, size_t k, const float *A, const float *B, float *C) { p_matmul(m, n, k, A, B, C); }
