/* Embedder for hostcall_guest.wasm using the Wasmtime C API. Provides the "h" imports, in two calling conventions (argv[2]: checked = wasmtime_func_new style with typed values,
 * unchecked = wasmtime_func_new_unchecked, raw values), with host kernels chosen by CPU feature detection at start-up (AVX-512 / AVX2+FMA / NEON / portable C).
 * The kernels work directly on the module's linear memory (zero copy); every import checks that its pointer ranges lie inside the memory before touching them. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <wasm.h>
#include <wasmtime.h>
#if defined(__x86_64__)
#include <immintrin.h>
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif

/* ---- kernels (same math as the guest's SIMD128 versions; matmul sums are exact for the test data) ---- */
static void saxpy_c(float a, const float *x, float *y, int n) { for (int i = 0; i < n; i++) y[i] += a * x[i]; }
static float sdot_c(const float *x, const float *y, int n) { float s = 0; for (int i = 0; i < n; i++) s += x[i] * y[i]; return s; }
static void matmul_c(const float *A, const float *B, float *C, int n) { memset(C, 0, (size_t)n * n * 4); for (int i = 0; i < n; i++) for (int k = 0; k < n; k++) { float a = A[i * n + k]; for (int j = 0; j < n; j++) C[i * n + j] += a * B[k * n + j]; } }
#if defined(__x86_64__)
__attribute__((target("avx2,fma"))) static void saxpy_avx2(float a, const float *x, float *y, int n) {
    __m256 av = _mm256_set1_ps(a); int i = 0;
    for (; i + 32 <= n; i += 32) { for (int u = 0; u < 4; u++) _mm256_storeu_ps(y + i + 8 * u, _mm256_fmadd_ps(av, _mm256_loadu_ps(x + i + 8 * u), _mm256_loadu_ps(y + i + 8 * u))); }
    for (; i + 8 <= n; i += 8) _mm256_storeu_ps(y + i, _mm256_fmadd_ps(av, _mm256_loadu_ps(x + i), _mm256_loadu_ps(y + i)));
    for (; i < n; i++) y[i] += a * x[i];
}
__attribute__((target("avx2,fma"))) static float sdot_avx2(const float *x, const float *y, int n) {
    __m256 s0 = _mm256_setzero_ps(), s1 = s0, s2 = s0, s3 = s0; int i = 0;
    for (; i + 32 <= n; i += 32) { s0 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i), _mm256_loadu_ps(y + i), s0); s1 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i + 8), _mm256_loadu_ps(y + i + 8), s1); s2 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i + 16), _mm256_loadu_ps(y + i + 16), s2); s3 = _mm256_fmadd_ps(_mm256_loadu_ps(x + i + 24), _mm256_loadu_ps(y + i + 24), s3); }
    s0 = _mm256_add_ps(_mm256_add_ps(s0, s1), _mm256_add_ps(s2, s3)); float t[8]; _mm256_storeu_ps(t, s0); float r = t[0] + t[1] + t[2] + t[3] + t[4] + t[5] + t[6] + t[7];
    for (; i < n; i++) r += x[i] * y[i]; return r;
}
__attribute__((target("avx2,fma"))) static void matmul_avx2(const float *A, const float *B, float *C, int n) {   /* 2 rows x 32 columns (8 ymm accumulators) */
    for (int i = 0; i < n; i += 2) { int j = 0;
        for (; j + 32 <= n; j += 32) { __m256 c[2][4]; for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) c[r][u] = _mm256_setzero_ps();
            for (int k = 0; k < n; k++) { __m256 b[4]; for (int u = 0; u < 4; u++) b[u] = _mm256_loadu_ps(B + k * n + j + 8 * u);
                for (int r = 0; r < 2; r++) { __m256 a = _mm256_set1_ps(A[(i + r) * n + k]); for (int u = 0; u < 4; u++) c[r][u] = _mm256_fmadd_ps(a, b[u], c[r][u]); } }
            for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) _mm256_storeu_ps(C + (i + r) * n + j + 8 * u, c[r][u]); }
        for (; j + 8 <= n; j += 8) { __m256 c0 = _mm256_setzero_ps(), c1 = c0; for (int k = 0; k < n; k++) { __m256 b = _mm256_loadu_ps(B + k * n + j); c0 = _mm256_fmadd_ps(_mm256_set1_ps(A[i * n + k]), b, c0); c1 = _mm256_fmadd_ps(_mm256_set1_ps(A[(i + 1) * n + k]), b, c1); }
            _mm256_storeu_ps(C + i * n + j, c0); _mm256_storeu_ps(C + (i + 1) * n + j, c1); } }
}
__attribute__((target("avx512f"))) static void saxpy_avx512(float a, const float *x, float *y, int n) {
    __m512 av = _mm512_set1_ps(a); int i = 0;
    for (; i + 64 <= n; i += 64) { for (int u = 0; u < 4; u++) _mm512_storeu_ps(y + i + 16 * u, _mm512_fmadd_ps(av, _mm512_loadu_ps(x + i + 16 * u), _mm512_loadu_ps(y + i + 16 * u))); }
    for (; i + 16 <= n; i += 16) _mm512_storeu_ps(y + i, _mm512_fmadd_ps(av, _mm512_loadu_ps(x + i), _mm512_loadu_ps(y + i)));
    for (; i < n; i++) y[i] += a * x[i];
}
__attribute__((target("avx512f"))) static float sdot_avx512(const float *x, const float *y, int n) {
    __m512 s0 = _mm512_setzero_ps(), s1 = s0, s2 = s0, s3 = s0; int i = 0;
    for (; i + 64 <= n; i += 64) { s0 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i), _mm512_loadu_ps(y + i), s0); s1 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i + 16), _mm512_loadu_ps(y + i + 16), s1); s2 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i + 32), _mm512_loadu_ps(y + i + 32), s2); s3 = _mm512_fmadd_ps(_mm512_loadu_ps(x + i + 48), _mm512_loadu_ps(y + i + 48), s3); }
    float r = _mm512_reduce_add_ps(_mm512_add_ps(_mm512_add_ps(s0, s1), _mm512_add_ps(s2, s3))); for (; i < n; i++) r += x[i] * y[i]; return r;
}
__attribute__((target("avx512f"))) static void matmul_avx512(const float *A, const float *B, float *C, int n) {   /* 2 rows x 64 columns (8 zmm accumulators) */
    for (int i = 0; i < n; i += 2) { int j = 0;
        for (; j + 64 <= n; j += 64) { __m512 c[2][4]; for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) c[r][u] = _mm512_setzero_ps();
            for (int k = 0; k < n; k++) { __m512 b[4]; for (int u = 0; u < 4; u++) b[u] = _mm512_loadu_ps(B + k * n + j + 16 * u);
                for (int r = 0; r < 2; r++) { __m512 a = _mm512_set1_ps(A[(i + r) * n + k]); for (int u = 0; u < 4; u++) c[r][u] = _mm512_fmadd_ps(a, b[u], c[r][u]); } }
            for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) _mm512_storeu_ps(C + (i + r) * n + j + 16 * u, c[r][u]); }
        for (; j + 16 <= n; j += 16) { __m512 c0 = _mm512_setzero_ps(), c1 = c0; for (int k = 0; k < n; k++) { __m512 b = _mm512_loadu_ps(B + k * n + j); c0 = _mm512_fmadd_ps(_mm512_set1_ps(A[i * n + k]), b, c0); c1 = _mm512_fmadd_ps(_mm512_set1_ps(A[(i + 1) * n + k]), b, c1); }
            _mm512_storeu_ps(C + i * n + j, c0); _mm512_storeu_ps(C + (i + 1) * n + j, c1); }
        for (; j + 8 <= n; j += 8) { __m256 c0 = _mm256_setzero_ps(), c1 = c0; for (int k = 0; k < n; k++) { __m256 b = _mm256_loadu_ps(B + k * n + j); c0 = _mm256_add_ps(c0, _mm256_mul_ps(_mm256_set1_ps(A[i * n + k]), b)); c1 = _mm256_add_ps(c1, _mm256_mul_ps(_mm256_set1_ps(A[(i + 1) * n + k]), b)); }
            _mm256_storeu_ps(C + i * n + j, c0); _mm256_storeu_ps(C + (i + 1) * n + j, c1); } }
}
#elif defined(__aarch64__)
static void saxpy_neon(float a, const float *x, float *y, int n) {
    int i = 0; for (; i + 16 <= n; i += 16) { for (int u = 0; u < 4; u++) vst1q_f32(y + i + 4 * u, vfmaq_n_f32(vld1q_f32(y + i + 4 * u), vld1q_f32(x + i + 4 * u), a)); }
    for (; i + 4 <= n; i += 4) vst1q_f32(y + i, vfmaq_n_f32(vld1q_f32(y + i), vld1q_f32(x + i), a)); for (; i < n; i++) y[i] += a * x[i];
}
static float sdot_neon(const float *x, const float *y, int n) {
    float32x4_t s0 = vdupq_n_f32(0), s1 = s0, s2 = s0, s3 = s0; int i = 0;
    for (; i + 16 <= n; i += 16) { s0 = vfmaq_f32(s0, vld1q_f32(x + i), vld1q_f32(y + i)); s1 = vfmaq_f32(s1, vld1q_f32(x + i + 4), vld1q_f32(y + i + 4)); s2 = vfmaq_f32(s2, vld1q_f32(x + i + 8), vld1q_f32(y + i + 8)); s3 = vfmaq_f32(s3, vld1q_f32(x + i + 12), vld1q_f32(y + i + 12)); }
    float r = vaddvq_f32(vaddq_f32(vaddq_f32(s0, s1), vaddq_f32(s2, s3))); for (; i < n; i++) r += x[i] * y[i]; return r;
}
static void matmul_neon(const float *A, const float *B, float *C, int n) {   /* 2 rows x 16 columns (8 q accumulators) */
    for (int i = 0; i < n; i += 2) { int j = 0;
        for (; j + 16 <= n; j += 16) { float32x4_t c[2][4]; for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) c[r][u] = vdupq_n_f32(0);
            for (int k = 0; k < n; k++) { float32x4_t b[4]; for (int u = 0; u < 4; u++) b[u] = vld1q_f32(B + k * n + j + 4 * u);
                for (int r = 0; r < 2; r++) { float a = A[(i + r) * n + k]; for (int u = 0; u < 4; u++) c[r][u] = vfmaq_n_f32(c[r][u], b[u], a); } }
            for (int r = 0; r < 2; r++) for (int u = 0; u < 4; u++) vst1q_f32(C + (i + r) * n + j + 4 * u, c[r][u]); }
        for (; j + 4 <= n; j += 4) { float32x4_t c0 = vdupq_n_f32(0), c1 = c0; for (int k = 0; k < n; k++) { float32x4_t b = vld1q_f32(B + k * n + j); c0 = vfmaq_n_f32(c0, b, A[i * n + k]); c1 = vfmaq_n_f32(c1, b, A[(i + 1) * n + k]); }
            vst1q_f32(C + i * n + j, c0); vst1q_f32(C + (i + 1) * n + j, c1); } }
}
#endif
static void (*k_saxpy)(float, const float *, float *, int) = saxpy_c; static float (*k_sdot)(const float *, const float *, int) = sdot_c; static void (*k_matmul)(const float *, const float *, float *, int) = matmul_c;
static int g_kind = 0;
static void pick_kernels(void) {
    const char *force = getenv("HOSTKERNEL");   /* portable | avx2 | avx512 | neon : override the detection */
#if defined(__x86_64__)
    __builtin_cpu_init();
    int a512 = __builtin_cpu_supports("avx512f"), a2 = __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma");
    if (force) { if (!strcmp(force, "portable")) a512 = a2 = 0; else if (!strcmp(force, "avx2")) a512 = 0; }
    if (a512) { k_saxpy = saxpy_avx512; k_sdot = sdot_avx512; k_matmul = matmul_avx512; g_kind = 2; }
    else if (a2) { k_saxpy = saxpy_avx2; k_sdot = sdot_avx2; k_matmul = matmul_avx2; g_kind = 1; }
#elif defined(__aarch64__)
    if (!(force && !strcmp(force, "portable"))) { k_saxpy = saxpy_neon; k_sdot = sdot_neon; k_matmul = matmul_neon; g_kind = 3; }
#endif
}

/* ---- imports ---- */
static wasmtime_memory_t g_mem; static wasmtime_context_t *g_ctx;
static wasm_trap_t *oob(void) { return wasmtime_trap_new("host kernel: pointer range outside linear memory", 48); }
#define RANGE(m, sz, p, len) ((uint64_t)(uint32_t)(p) + (uint64_t)(len) <= (sz))
static wasm_trap_t *do_nop(void) { return NULL; }
static wasm_trap_t *do_nopmem(wasmtime_caller_t *c) { wasmtime_extern_t it; if (!wasmtime_caller_export_get(c, "memory", 6, &it)) return NULL; volatile uint8_t *b = wasmtime_memory_data(wasmtime_caller_context(c), &it.of.memory); (void)b; return NULL; }
static wasm_trap_t *do_nopcached(void) { volatile uint8_t *b = wasmtime_memory_data(g_ctx, &g_mem); (void)b; return NULL; }
static wasm_trap_t *do_saxpy(float a, uint32_t xp, uint32_t yp, int32_t n) {
    uint8_t *m = wasmtime_memory_data(g_ctx, &g_mem); size_t sz = wasmtime_memory_data_size(g_ctx, &g_mem); uint64_t len = (uint64_t)(uint32_t)n * 4;
    if (n < 0 || !RANGE(m, sz, xp, len) || !RANGE(m, sz, yp, len)) return oob(); k_saxpy(a, (const float *)(m + xp), (float *)(m + yp), n); return NULL; }
static wasm_trap_t *do_sdot(uint32_t xp, uint32_t yp, int32_t n, float *out) {
    uint8_t *m = wasmtime_memory_data(g_ctx, &g_mem); size_t sz = wasmtime_memory_data_size(g_ctx, &g_mem); uint64_t len = (uint64_t)(uint32_t)n * 4;
    if (n < 0 || !RANGE(m, sz, xp, len) || !RANGE(m, sz, yp, len)) return oob(); *out = k_sdot((const float *)(m + xp), (const float *)(m + yp), n); return NULL; }
static wasm_trap_t *do_matmul(uint32_t ap, uint32_t bp, uint32_t cp, int32_t n) {
    uint8_t *m = wasmtime_memory_data(g_ctx, &g_mem); size_t sz = wasmtime_memory_data_size(g_ctx, &g_mem); uint64_t len = (uint64_t)n * n * 4;
    if (n < 0 || n > 4096 || !RANGE(m, sz, ap, len) || !RANGE(m, sz, bp, len) || !RANGE(m, sz, cp, len)) return oob(); k_matmul((const float *)(m + ap), (const float *)(m + bp), (float *)(m + cp), n); return NULL; }
/* unchecked (raw) callbacks */
#define U(name) static wasm_trap_t *u_##name(void *e, wasmtime_caller_t *c, wasmtime_val_raw_t *a, size_t n)
U(nop) { return do_nop(); }
U(nop3) { a[0].i32 = a[0].i32 + a[1].i32 + a[2].i32; return NULL; }
U(nopmem) { return do_nopmem(c); }
U(nopcached) { return do_nopcached(); }
U(kind) { a[0].i32 = g_kind; return NULL; }
U(saxpy) { return do_saxpy(a[0].f32, a[1].i32, a[2].i32, a[3].i32); }
U(sdot) { float r; wasm_trap_t *t = do_sdot(a[0].i32, a[1].i32, a[2].i32, &r); a[0].f32 = r; return t; }
U(matmul) { return do_matmul(a[0].i32, a[1].i32, a[2].i32, a[3].i32); }
/* checked callbacks */
#define C(name) static wasm_trap_t *c_##name(void *e, wasmtime_caller_t *c, const wasmtime_val_t *a, size_t na, wasmtime_val_t *r, size_t nr)
C(nop) { return do_nop(); }
C(nop3) { r[0].kind = WASMTIME_I32; r[0].of.i32 = a[0].of.i32 + a[1].of.i32 + a[2].of.i32; return NULL; }
C(nopmem) { return do_nopmem(c); }
C(nopcached) { return do_nopcached(); }
C(kind) { r[0].kind = WASMTIME_I32; r[0].of.i32 = g_kind; return NULL; }
C(saxpy) { return do_saxpy(a[0].of.f32, a[1].of.i32, a[2].of.i32, a[3].of.i32); }
C(sdot) { float x; wasm_trap_t *t = do_sdot(a[0].of.i32, a[1].of.i32, a[2].of.i32, &x); r[0].kind = WASMTIME_F32; r[0].of.f32 = x; return t; }
C(matmul) { return do_matmul(a[0].of.i32, a[1].of.i32, a[2].of.i32, a[3].of.i32); }

static wasm_functype_t *ty(const char *p, const char *r) {
    wasm_valtype_vec_t pv, rv; wasm_valtype_vec_new_uninitialized(&pv, strlen(p)); wasm_valtype_vec_new_uninitialized(&rv, strlen(r));
    for (size_t i = 0; i < strlen(p); i++) pv.data[i] = wasm_valtype_new(p[i] == 'f' ? WASM_F32 : WASM_I32);
    for (size_t i = 0; i < strlen(r); i++) rv.data[i] = wasm_valtype_new(r[i] == 'f' ? WASM_F32 : WASM_I32);
    return wasm_functype_new(&pv, &rv);
}
static void die(const char *what, wasmtime_error_t *e, wasm_trap_t *t) {
    wasm_byte_vec_t m; if (e) wasmtime_error_message(e, &m); else if (t) wasm_trap_message(t, &m); else { fprintf(stderr, "%s\n", what); exit(1); }
    fprintf(stderr, "%s: %.*s\n", what, (int)m.size, m.data); exit(1);
}
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: host guest.wasm checked|unchecked\n"); return 2; }
    int unchecked = !strcmp(argv[2], "unchecked"); pick_kernels();
    FILE *f = fopen(argv[1], "rb"); if (!f) { perror("open"); return 1; } fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET); uint8_t *buf = malloc(len); if (fread(buf, 1, len, f) != (size_t)len) return 1; fclose(f);
    const char *cfgenv = getenv("HOSTCFG");   /* epoch | fuel | explicit : engine settings whose cost is being measured (default: none) */
    wasm_config_t *cfg = wasm_config_new();
    if (cfgenv && !strcmp(cfgenv, "epoch")) wasmtime_config_epoch_interruption_set(cfg, true);
    if (cfgenv && !strcmp(cfgenv, "fuel")) wasmtime_config_consume_fuel_set(cfg, true);
    if (cfgenv && !strcmp(cfgenv, "explicit")) wasmtime_config_signals_based_traps_set(cfg, false);
    printf("ENGINE %s\n", cfgenv ? cfgenv : "default");
    wasm_engine_t *eng = wasm_engine_new_with_config(cfg); wasmtime_store_t *st = wasmtime_store_new(eng, NULL, NULL); g_ctx = wasmtime_store_context(st);
    if (cfgenv && !strcmp(cfgenv, "epoch")) wasmtime_context_set_epoch_deadline(g_ctx, 1ull << 60);
    if (cfgenv && !strcmp(cfgenv, "fuel")) { wasmtime_error_t *fe = wasmtime_context_set_fuel(g_ctx, 1ull << 62); if (fe) die("fuel", fe, NULL); }
    wasi_config_t *wc = wasi_config_new(); wasi_config_inherit_stdout(wc); wasi_config_inherit_stderr(wc); wasmtime_error_t *e = wasmtime_context_set_wasi(g_ctx, wc); if (e) die("wasi", e, NULL);
    wasmtime_linker_t *lk = wasmtime_linker_new(eng); e = wasmtime_linker_define_wasi(lk); if (e) die("define_wasi", e, NULL);
#define DEF(nm, p, r) do { wasm_functype_t *t = ty(p, r); e = unchecked ? wasmtime_linker_define_func_unchecked(lk, "h", 1, #nm, strlen(#nm), t, u_##nm, NULL, NULL) : wasmtime_linker_define_func(lk, "h", 1, #nm, strlen(#nm), t, c_##nm, NULL, NULL); if (e) die("define " #nm, e, NULL); wasm_functype_delete(t); } while (0)
    DEF(nop, "", ""); DEF(nop3, "iii", "i"); DEF(nopmem, "i", ""); DEF(nopcached, "i", ""); DEF(kind, "", "i"); DEF(saxpy, "fiii", ""); DEF(sdot, "iii", "f"); DEF(matmul, "iiii", "");
    wasmtime_module_t *mod; e = wasmtime_module_new(eng, buf, len, &mod); if (e) die("module", e, NULL);
    wasmtime_instance_t inst; wasm_trap_t *trap = NULL; e = wasmtime_linker_instantiate(lk, g_ctx, mod, &inst, &trap); if (e || trap) die("instantiate", e, trap);
    wasmtime_extern_t it; if (!wasmtime_instance_export_get(g_ctx, &inst, "memory", 6, &it) || it.kind != WASMTIME_EXTERN_MEMORY) { fprintf(stderr, "no memory export\n"); return 1; } g_mem = it.of.memory;
    if (!wasmtime_instance_export_get(g_ctx, &inst, "_start", 6, &it)) { fprintf(stderr, "no _start\n"); return 1; }
    printf("CONVENTION %s\n", unchecked ? "unchecked" : "checked");
    e = wasmtime_func_call(g_ctx, &it.of.func, NULL, 0, NULL, 0, &trap); if (e || trap) die("run", e, trap);
    return 0;
}
