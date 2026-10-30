/* A host that gives wasm modules real threads through Wasmtime's C API now that Wasmtime (>= 47) no longer ships wasi-threads.
 * The module is built with wasi-sdk's wasm32-wasip1-threads target: it imports a SHARED memory and `wasi:thread-spawn`, and exports `wasi_thread_start`.
 * thread-spawn(start_arg) -> a new OS thread creates its own store + instance of the same module over the same shared memory and calls
 * wasi_thread_start(tid, start_arg). usage: threads-host <libwasmtime-path-or-link> module.wasm [args...] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <wasmtime.h>

typedef struct { wasm_engine_t *engine; wasmtime_module_t *module; wasmtime_sharedmemory_t *mem; char memmod[64], memname[64]; atomic_int next_tid;
                 pthread_t th[256]; int nth; pthread_mutex_t mu; } Shared;
static Shared G;

static void die(wasmtime_error_t *e, wasm_trap_t *t, const char *what) {
  wasm_byte_vec_t m; if (e) wasmtime_error_message(e, &m); else wasm_trap_message(t, &m);
  fprintf(stderr, "%s: %.*s\n", what, (int)m.size, m.data); exit(2);
}
static wasm_functype_t *ty_i32_i32(void) {
  wasm_valtype_t *p[1] = {wasm_valtype_new(WASM_I32)}, *r[1] = {wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t pv, rv; wasm_valtype_vec_new(&pv, 1, p); wasm_valtype_vec_new(&rv, 1, r); return wasm_functype_new(&pv, &rv);
}
static wasm_trap_t *spawn_cb(void *env, wasmtime_caller_t *caller, const wasmtime_val_t *args, size_t nargs, wasmtime_val_t *results, size_t nresults);

typedef struct { int tid; int start_arg; } ThreadArg;

/* store + linker with everything a module instance needs: WASI, the shared memory, thread-spawn */
static void build_instance(wasmtime_store_t **store_out, wasmtime_context_t **cx_out, wasmtime_instance_t *inst) {
  wasmtime_store_t *store = wasmtime_store_new(G.engine, NULL, NULL); wasmtime_context_t *cx = wasmtime_store_context(store);
  wasi_config_t *wc = wasi_config_new(); wasi_config_inherit_stdout(wc); wasi_config_inherit_stderr(wc);
  wasmtime_error_t *err = wasmtime_context_set_wasi(cx, wc); if (err) die(err, NULL, "set_wasi");
  wasmtime_linker_t *linker = wasmtime_linker_new(G.engine);
  err = wasmtime_linker_define_wasi(linker); if (err) die(err, NULL, "define_wasi");
  wasmtime_extern_t e; e.kind = WASMTIME_EXTERN_SHAREDMEMORY; e.of.sharedmemory = wasmtime_sharedmemory_clone(G.mem);
  err = wasmtime_linker_define(linker, cx, G.memmod, strlen(G.memmod), G.memname, strlen(G.memname), &e); if (err) die(err, NULL, "define memory");
  err = wasmtime_linker_define_func(linker, "wasi", 4, "thread-spawn", 12, ty_i32_i32(), spawn_cb, NULL, NULL); if (err) die(err, NULL, "define thread-spawn");
  wasm_trap_t *trap = NULL; err = wasmtime_linker_instantiate(linker, cx, G.module, inst, &trap); if (err || trap) die(err, trap, "instantiate");
  *store_out = store; *cx_out = cx;
}
static void *worker(void *p) {
  ThreadArg *ta = p; wasmtime_store_t *store; wasmtime_context_t *cx; wasmtime_instance_t inst; build_instance(&store, &cx, &inst);
  wasmtime_extern_t f; if (!wasmtime_instance_export_get(cx, &inst, "wasi_thread_start", 17, &f)) { fprintf(stderr, "no wasi_thread_start export\n"); return NULL; }
  wasmtime_val_t a[2]; a[0].kind = WASMTIME_I32; a[0].of.i32 = ta->tid; a[1].kind = WASMTIME_I32; a[1].of.i32 = ta->start_arg;
  wasm_trap_t *trap = NULL; wasmtime_error_t *err = wasmtime_func_call(cx, &f.of.func, a, 2, NULL, 0, &trap);
  if (err || trap) die(err, trap, "wasi_thread_start");
  free(ta); return NULL;
}
static wasm_trap_t *spawn_cb(void *env, wasmtime_caller_t *caller, const wasmtime_val_t *args, size_t nargs, wasmtime_val_t *results, size_t nresults) {
  (void)env; (void)caller; (void)nargs; (void)nresults;
  ThreadArg *ta = malloc(sizeof *ta); ta->start_arg = args[0].of.i32; ta->tid = atomic_fetch_add(&G.next_tid, 1) + 1;
  results[0].kind = WASMTIME_I32; results[0].of.i32 = ta->tid;
  pthread_mutex_lock(&G.mu);
  if (G.nth >= 256 || pthread_create(&G.th[G.nth], NULL, worker, ta)) { results[0].of.i32 = -1; free(ta); } else G.nth++;
  pthread_mutex_unlock(&G.mu);
  return NULL;
}
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s module.wasm [args]\n", argv[0]); return 1; }
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; } fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t *wasm = malloc(len); if (fread(wasm, 1, len, f) != (size_t)len) return 1; fclose(f);
  wasm_config_t *cfg = wasm_config_new(); wasmtime_config_wasm_threads_set(cfg, true); wasmtime_config_shared_memory_set(cfg, true);
  G.engine = wasm_engine_new_with_config(cfg); pthread_mutex_init(&G.mu, NULL);
  wasmtime_error_t *err = wasmtime_module_new(G.engine, wasm, len, &G.module); if (err) die(err, NULL, "module_new");
  /* find the imported (shared) memory and create one with the same limits */
  wasm_importtype_vec_t imps; wasmtime_module_imports(G.module, &imps); int found = 0;
  for (size_t i = 0; i < imps.size && !found; i++) {
    const wasm_externtype_t *et = wasm_importtype_type(imps.data[i]); const wasm_memorytype_t *mt = wasm_externtype_as_memorytype_const(et);
    if (!mt) continue;
    const wasm_name_t *m = wasm_importtype_module(imps.data[i]), *n = wasm_importtype_name(imps.data[i]);
    snprintf(G.memmod, sizeof G.memmod, "%.*s", (int)m->size, m->data); snprintf(G.memname, sizeof G.memname, "%.*s", (int)n->size, n->data);
    uint64_t mx = 0; bool has_max = wasmtime_memorytype_maximum(mt, &mx); wasm_memorytype_t *nt = NULL;
    err = wasmtime_memorytype_new(wasmtime_memorytype_minimum(mt), has_max, mx, wasmtime_memorytype_is64(mt), true, wasmtime_memorytype_page_size_log2(mt), &nt); if (err) die(err, NULL, "memorytype");
    err = wasmtime_sharedmemory_new(G.engine, nt, &G.mem); if (err) die(err, NULL, "sharedmemory_new");
    printf("host : shared memory %s.%s min=%llu pages max=%llu\n", G.memmod, G.memname, (unsigned long long)wasmtime_memorytype_minimum(mt), (unsigned long long)mx); found = 1;
  }
  if (!found) { puts("host : module does not import a memory (not a threads build)"); return 3; }
  wasmtime_store_t *store; wasmtime_context_t *cx; wasmtime_instance_t inst; build_instance(&store, &cx, &inst);
  wasmtime_extern_t start; if (!wasmtime_instance_export_get(cx, &inst, "_start", 6, &start)) { fprintf(stderr, "no _start\n"); return 3; }
  wasm_trap_t *trap = NULL; err = wasmtime_func_call(cx, &start.of.func, NULL, 0, NULL, 0, &trap);
  int rc = 0;
  if (err) { int code; if (wasmtime_error_exit_status(err, &code)) rc = code; else die(err, NULL, "call"); } else if (trap) die(NULL, trap, "trap");
  for (int i = 0; i < G.nth; i++) pthread_join(G.th[i], NULL);
  printf("host : guest finished rc=%d, %d worker threads\n", rc, G.nth);
  return rc;
}
