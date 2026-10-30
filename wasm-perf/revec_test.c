/* Freestanding module for probing V8's experimental 128->256-bit revectoriser: the same L1-resident f32 kernel (c = a*b + c) written with 1, 2 and 4 independent
 * adjacent v128 operations per iteration, which is the pattern an SLP-style pass can merge into 256-bit operations. */
#include <wasm_simd128.h>
#define N 2048   /* floats, 8 KB per array: stays in L1 */
static float A[N], B[N], C[N];
#define EXP(n) __attribute__((export_name(n)))
EXP("init") void init(void) { for (int i = 0; i < N; i++) { A[i] = i * 0.5f; B[i] = 1.0f + (i & 7); C[i] = 0; } }
EXP("sum") float sum(void) { float s = 0; for (int i = 0; i < N; i++) s += C[i]; return s; }
EXP("run1") void run1(int iters) { for (int r = 0; r < iters; r++) for (int i = 0; i < N; i += 4) { v128_t c = wasm_v128_load(C + i); c = wasm_f32x4_add(wasm_f32x4_mul(wasm_v128_load(A + i), wasm_v128_load(B + i)), c); wasm_v128_store(C + i, c); } }
EXP("run2") void run2(int iters) { for (int r = 0; r < iters; r++) for (int i = 0; i < N; i += 8) {
    v128_t c0 = wasm_v128_load(C + i), c1 = wasm_v128_load(C + i + 4);
    c0 = wasm_f32x4_add(wasm_f32x4_mul(wasm_v128_load(A + i), wasm_v128_load(B + i)), c0); c1 = wasm_f32x4_add(wasm_f32x4_mul(wasm_v128_load(A + i + 4), wasm_v128_load(B + i + 4)), c1);
    wasm_v128_store(C + i, c0); wasm_v128_store(C + i + 4, c1); } }
EXP("run4") void run4(int iters) { for (int r = 0; r < iters; r++) for (int i = 0; i < N; i += 16) {
    v128_t c0 = wasm_v128_load(C + i), c1 = wasm_v128_load(C + i + 4), c2 = wasm_v128_load(C + i + 8), c3 = wasm_v128_load(C + i + 12);
    c0 = wasm_f32x4_add(wasm_f32x4_mul(wasm_v128_load(A + i), wasm_v128_load(B + i)), c0); c1 = wasm_f32x4_add(wasm_f32x4_mul(wasm_v128_load(A + i + 4), wasm_v128_load(B + i + 4)), c1);
    c2 = wasm_f32x4_add(wasm_f32x4_mul(wasm_v128_load(A + i + 8), wasm_v128_load(B + i + 8)), c2); c3 = wasm_f32x4_add(wasm_f32x4_mul(wasm_v128_load(A + i + 12), wasm_v128_load(B + i + 12)), c3);
    wasm_v128_store(C + i, c0); wasm_v128_store(C + i + 4, c1); wasm_v128_store(C + i + 8, c2); wasm_v128_store(C + i + 12, c3); } }
