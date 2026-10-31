/* Native Windows host for a wasm game module, built with stock tools (MSVC / clang-cl, arm64 or x64) against the official Wasmtime C API.
 * usage: wt-host <module.wasm|module.cwasm> [rounds]   runs the module's _start (WASI stdout inherited) and prints the load time and the run time of each round. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <wasi.h>
#include <wasmtime.h>
#include "../wasmtime-nostd/host/native_kernels.h"
static double now_ms(void) { LARGE_INTEGER f, c; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&c); return 1e3 * (double)c.QuadPart / (double)f.QuadPart; }
static void die(const char *what, wasmtime_error_t *e, wasm_trap_t *t) {
  wasm_byte_vec_t m; if (e) wasmtime_error_message(e, &m); else wasm_trap_message(t, &m);
  fprintf(stderr, "%s: %.*s\n", what, (int)m.size, m.data); exit(2);
}

/* the "native" imports of the Cosmopolitan host (same names, same meaning): instruction-set specific kernels the wasm game calls instead of writing them in wasm */
static wasm_functype_t *ft(const char *sig) {   /* "iifi>f": i32 i32 f32 i32 -> f32 */
  wasm_valtype_vec_t p, r; size_t np = 0, nr = 0; const char *q = sig; for (; *q && *q != '>'; q++) np++; if (*q == '>') for (q++; *q; q++) nr++;
  wasm_valtype_vec_new_uninitialized(&p, np); wasm_valtype_vec_new_uninitialized(&r, nr); size_t i = 0, j = 0; int after = 0;
  for (q = sig; *q; q++) { if (*q == '>') { after = 1; continue; } wasm_valtype_t *v = wasm_valtype_new(*q == 'f' ? WASM_F32 : WASM_I32); if (after) r.data[j++] = v; else p.data[i++] = v; }
  return wasm_functype_new(&p, &r);
}
static int mem_of(wasmtime_caller_t *c, uint8_t **base, size_t *len) {
  wasmtime_extern_t e; if (!wasmtime_caller_export_get(c, "memory", 6, &e) || e.kind != WASMTIME_EXTERN_MEMORY) return 0;
  wasmtime_context_t *x = wasmtime_caller_context(c); *base = wasmtime_memory_data(x, &e.of.memory); *len = wasmtime_memory_data_size(x, &e.of.memory); return 1;
}
#define OK(p, bytes) ((uint64_t)(uint32_t)(p) + (uint64_t)(bytes) <= (uint64_t)len)
static wasm_trap_t *cb_level(void *env, wasmtime_caller_t *c, const wasmtime_val_t *a, size_t na, wasmtime_val_t *r, size_t nr) { (void)env; (void)c; (void)a; (void)na; (void)nr; r[0].kind = WASMTIME_I32; r[0].of.i32 = nk_level(); return NULL; }
static wasm_trap_t *cb_saxpy(void *env, wasmtime_caller_t *c, const wasmtime_val_t *a, size_t na, wasmtime_val_t *r, size_t nr) {
  (void)env; (void)na; (void)r; (void)nr; uint8_t *m; size_t len; uint32_t n = (uint32_t)a[0].of.i32, x = (uint32_t)a[2].of.i32, y = (uint32_t)a[3].of.i32;
  if (!mem_of(c, &m, &len) || !OK(x, 4ull * n) || !OK(y, 4ull * n)) return wasmtime_trap_new("saxpy_f32 out of bounds", 23);
  nk_saxpy(n, a[1].of.f32, (const float *)(m + x), (float *)(m + y)); return NULL;
}
static wasm_trap_t *cb_dot(void *env, wasmtime_caller_t *c, const wasmtime_val_t *a, size_t na, wasmtime_val_t *r, size_t nr) {
  (void)env; (void)na; (void)nr; uint8_t *m; size_t len; uint32_t n = (uint32_t)a[0].of.i32, x = (uint32_t)a[1].of.i32, y = (uint32_t)a[2].of.i32;
  if (!mem_of(c, &m, &len) || !OK(x, 4ull * n) || !OK(y, 4ull * n)) return wasmtime_trap_new("dot_f32 out of bounds", 21);
  r[0].kind = WASMTIME_F32; r[0].of.f32 = nk_dot(n, (const float *)(m + x), (const float *)(m + y)); return NULL;
}
static wasm_trap_t *cb_matmul(void *env, wasmtime_caller_t *c, const wasmtime_val_t *a, size_t na, wasmtime_val_t *r, size_t nr) {
  (void)env; (void)na; (void)r; (void)nr; uint8_t *m; size_t len; uint32_t M = (uint32_t)a[0].of.i32, N = (uint32_t)a[1].of.i32, K = (uint32_t)a[2].of.i32, A = (uint32_t)a[3].of.i32, B = (uint32_t)a[4].of.i32, C = (uint32_t)a[5].of.i32;
  if (!mem_of(c, &m, &len) || !OK(A, 4ull * M * K) || !OK(B, 4ull * K * N) || !OK(C, 4ull * M * N)) return wasmtime_trap_new("matmul_f32 out of bounds", 24);
  nk_matmul(M, N, K, (const float *)(m + A), (const float *)(m + B), (float *)(m + C)); return NULL;
}
static void define_native(wasmtime_linker_t *l) {
  wasmtime_error_t *e;
  if ((e = wasmtime_linker_define_func(l, "native", 6, "cpu_level", 9, ft(">i"), cb_level, NULL, NULL))) die("define", e, NULL);
  if ((e = wasmtime_linker_define_func(l, "native", 6, "saxpy_f32", 9, ft("ifii"), cb_saxpy, NULL, NULL))) die("define", e, NULL);
  if ((e = wasmtime_linker_define_func(l, "native", 6, "dot_f32", 7, ft("iii>f"), cb_dot, NULL, NULL))) die("define", e, NULL);
  if ((e = wasmtime_linker_define_func(l, "native", 6, "matmul_f32", 10, ft("iiiiii"), cb_matmul, NULL, NULL))) die("define", e, NULL);
}
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: wt-host module [rounds] | wt-host --precompile in.wasm out.cwasm\n"); return 1; }
  if (!strcmp(argv[1], "--precompile") && argc > 3) {   /* ahead-of-time compile with this engine's own configuration, so the result always loads in it */
    FILE *in = fopen(argv[2], "rb"); if (!in) { perror("open"); return 1; }
    fseek(in, 0, SEEK_END); long wn = ftell(in); fseek(in, 0, SEEK_SET); uint8_t *wb = malloc(wn); fread(wb, 1, wn, in); fclose(in);
    wasm_engine_t *pe = wasm_engine_new(); wasmtime_module_t *pm = NULL; wasmtime_error_t *perr = wasmtime_module_new(pe, wb, wn, &pm);
    if (perr) die("compile", perr, NULL);
    wasm_byte_vec_t out; if ((perr = wasmtime_module_serialize(pm, &out))) die("serialize", perr, NULL);
    FILE *of = fopen(argv[3], "wb"); fwrite(out.data, 1, out.size, of); fclose(of);
    fprintf(stderr, "precompiled %s -> %s (%zu bytes)\n", argv[2], argv[3], out.size); return 0;
  }
  int rounds = argc > 2 ? atoi(argv[2]) : 1;
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror("open"); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); uint8_t *buf = malloc(n); fread(buf, 1, n, f); fclose(f);
  wasm_config_t *cfg = wasm_config_new();
  wasm_engine_t *engine = wasm_engine_new_with_config(cfg);
  double t0 = now_ms();
  wasmtime_module_t *mod = NULL; wasmtime_error_t *err;
  if (n > 4 && !memcmp(buf, "\0asm", 4)) err = wasmtime_module_new(engine, buf, n, &mod); else err = wasmtime_module_deserialize(engine, buf, n, &mod);
  if (err) die("module", err, NULL);
  fprintf(stderr, "load %s: %.1f ms (%s)\n", argv[1], now_ms() - t0, !memcmp(buf, "\0asm", 4) ? "compiled from wasm" : "precompiled");
  for (int r = 0; r < rounds; r++) {
    wasmtime_store_t *store = wasmtime_store_new(engine, NULL, NULL); wasmtime_context_t *ctx = wasmtime_store_context(store);
    wasi_config_t *wc = wasi_config_new(); wasi_config_inherit_stdout(wc); wasi_config_inherit_stderr(wc); wasi_config_set_argv(wc, 1, (const char *[]){"game"});
    if ((err = wasmtime_context_set_wasi(ctx, wc))) die("wasi", err, NULL);
    wasmtime_linker_t *linker = wasmtime_linker_new(engine); if ((err = wasmtime_linker_define_wasi(linker))) die("linker", err, NULL); define_native(linker);
    wasm_trap_t *trap = NULL; wasmtime_instance_t inst;
    if ((err = wasmtime_linker_instantiate(linker, ctx, mod, &inst, &trap)) || trap) die("instantiate", err, trap);
    wasmtime_extern_t ext;
    if (!wasmtime_instance_export_get(ctx, &inst, "_start", 6, &ext)) { fprintf(stderr, "no _start\n"); return 3; }
    double t1 = now_ms();
    err = wasmtime_func_call(ctx, &ext.of.func, NULL, 0, NULL, 0, &trap);
    fprintf(stderr, "round %d: _start %.1f ms\n", r, now_ms() - t1);
    if (err) { wasmtime_error_message(err, &(wasm_byte_vec_t){0}); }
    wasmtime_linker_delete(linker); wasmtime_store_delete(store);
  }
  return 0;
}
