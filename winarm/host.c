/* Native Windows host for a wasm game module, built with stock tools (MSVC / clang-cl, arm64 or x64) against the official Wasmtime C API.
 * usage: wt-host <module.wasm|module.cwasm> [rounds]   runs the module's _start (WASI stdout inherited) and prints the load time and the run time of each round. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <wasi.h>
#include <wasmtime.h>
static double now_ms(void) { LARGE_INTEGER f, c; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&c); return 1e3 * (double)c.QuadPart / (double)f.QuadPart; }
static void die(const char *what, wasmtime_error_t *e, wasm_trap_t *t) {
  wasm_byte_vec_t m; if (e) wasmtime_error_message(e, &m); else wasm_trap_message(t, &m);
  fprintf(stderr, "%s: %.*s\n", what, (int)m.size, m.data); exit(2);
}
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: wt-host module [rounds]\n"); return 1; }
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
    wasmtime_linker_t *linker = wasmtime_linker_new(engine); if ((err = wasmtime_linker_define_wasi(linker))) die("linker", err, NULL);
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
