/* Cosmopolitan APE host: dlopens the OFFICIAL prebuilt Wasmtime C-API library (no Rust built or written by us), runs a wasm guest, serves its imports from C.
 * usage: wt-host <libwasmtime.{so,dylib,dll}> <guest.wasm>
 * One source, every OS: System V call path through cosmo_dltramp, Microsoft x64 path (typed pointers + ms_abi callbacks) on Windows. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <cosmo.h>
#include <dlfcn.h>
#include <wasmtime.h>
#ifdef WT_STATIC
/* Wasmtime linked straight into this executable (libwasmtime.a built from source): no dlopen, no ABI shim */
#define WT_CB(f, T) ((T)(void *)(f))
static int wt_load(void *h) { (void)h; return 0; }
#else
#include "wt_shim.h"
#endif

static char g_reply[64]; static int g_reply_len;

/* Host function: sample:wire/transport send(ptr,len)->i32. Reads guest memory, stores a reply for recv. */
#define CALLBACK_BODY_SEND \
  wasmtime_context_t *cx = wasmtime_caller_context(caller); wasmtime_extern_t mem; \
  if (!wasmtime_caller_export_get(caller, "memory", 6, &mem)) return 0; \
  uint8_t *base = wasmtime_memory_data(cx, &mem.of.memory); uint32_t p = args[0].of.i32, n = args[1].of.i32; \
  printf("host : wire.send got %u bytes: \"%.*s\"\n", n, (int)n, base + p); \
  g_reply_len = snprintf(g_reply, sizeof g_reply, "pong (%u)", n); results[0].kind = WASMTIME_I32; results[0].of.i32 = 0; return 0;
#define CALLBACK_BODY_RECV \
  wasmtime_context_t *cx = wasmtime_caller_context(caller); wasmtime_extern_t mem; \
  if (!wasmtime_caller_export_get(caller, "memory", 6, &mem)) return 0; \
  uint8_t *base = wasmtime_memory_data(cx, &mem.of.memory); uint32_t p = args[0].of.i32, mx = args[1].of.i32; \
  int n = g_reply_len < (int)mx ? g_reply_len : (int)mx; memcpy(base + p, g_reply, n); results[0].kind = WASMTIME_I32; results[0].of.i32 = n; return 0;
#define CB_ARGS void *env, wasmtime_caller_t *caller, const wasmtime_val_t *args, size_t nargs, wasmtime_val_t *results, size_t nresults
/* aarch64: Cosmopolitan keeps its thread pointer in x28. Wasmtime is free to use x28 for anything, so a callback arriving from it must put ours back first and give theirs back on return
 * (hypothesis for the intermittent SIGSEGV right after the first callback on Linux arm64; x86-64 uses %fs and is untouched). */
static void *g_tls;
#ifdef __aarch64__
#define TLS_ENTER void *foreign_x28; __asm__ volatile("mov %0, x28\n\tmov x28, %1" : "=&r"(foreign_x28) : "r"(g_tls) : "memory")
#define TLS_LEAVE __asm__ volatile("mov x28, %0" :: "r"(foreign_x28) : "memory")
#else
#define TLS_ENTER
#define TLS_LEAVE
#endif
static wasm_trap_t *send_body(CB_ARGS) { CALLBACK_BODY_SEND }
static wasm_trap_t *recv_body(CB_ARGS) { CALLBACK_BODY_RECV }
static wasm_trap_t *cb_send(CB_ARGS) { TLS_ENTER; wasm_trap_t *r = send_body(env, caller, args, nargs, results, nresults); TLS_LEAVE; return r; }
static wasm_trap_t *cb_recv(CB_ARGS) { TLS_ENTER; wasm_trap_t *r = recv_body(env, caller, args, nargs, results, nresults); TLS_LEAVE; return r; }
static __attribute__((ms_abi)) wasm_trap_t *cb_send_ms(CB_ARGS) { CALLBACK_BODY_SEND }
static __attribute__((ms_abi)) wasm_trap_t *cb_recv_ms(CB_ARGS) { CALLBACK_BODY_RECV }

static void die(wasmtime_error_t *e, wasm_trap_t *t, const char *what) {
  wasm_byte_vec_t m; if (e) wasmtime_error_message(e, &m); else wasm_trap_message(t, &m);
  fprintf(stderr, "%s: %.*s\n", what, (int)m.size, m.data); exit(2);
}
static wasm_functype_t *mk_i32i32_i32(void) {   /* (i32, i32) -> i32 */
  wasm_valtype_t *ps[2] = {wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32)}, *rs[1] = {wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t pv, rv; wasm_valtype_vec_new(&pv, 2, ps); wasm_valtype_vec_new(&rv, 1, rs); return wasm_functype_new(&pv, &rv);
}

#ifndef WT_STATIC
/* --bundled: the official library for THIS OS/arch is stored inside the executable (it is a zip archive); copy it out once and dlopen the copy */
static const char *bundled_name(void) {
  if (IsWindows()) return "wasmtime-x64.dll";                 /* Windows on ARM runs this file as x86-64 under emulation */
  if (IsXnu()) return "libwasmtime-arm64.dylib";
#ifdef __aarch64__
  return "libwasmtime-arm64.so";
#else
  return "libwasmtime-x64.so";
#endif
}
static int extract_bundled(char *out, size_t outsz) {
  char src[256]; snprintf(src, sizeof src, "/zip/wasmtime/%s", bundled_name());
  FILE *in = fopen(src, "rb"); if (!in) { fprintf(stderr, "not bundled: %s\n", src); return 0; }
  const char *t = getenv("TMPDIR"); if (!t) t = getenv("TEMP"); if (!t) t = "/tmp";
  snprintf(out, outsz, "%s/wt-bundled-%s", t, bundled_name());
  fseek(in, 0, SEEK_END); long n = ftell(in); fseek(in, 0, SEEK_SET);
  FILE *chk = fopen(out, "rb"); long have = -1; if (chk) { fseek(chk, 0, SEEK_END); have = ftell(chk); fclose(chk); }
  if (have != n) {
    FILE *o = fopen(out, "wb"); if (!o) { perror(out); fclose(in); return 0; }
    char buf[1 << 16]; size_t k; while ((k = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, k, o);
    fclose(o); fprintf(stderr, "extracted %ld bytes to %s\n", n, out);
  } else fprintf(stderr, "already extracted: %s\n", out);
  fclose(in); return 1;
}
#endif
int main(int argc, char **argv) {
#ifdef WT_STATIC
  if (argc < 2) { fprintf(stderr, "usage: %s <guest.wasm>\n", argv[0]); return 1; }
  const char *guest = argv[1];
#else
  if (argc < 3) { fprintf(stderr, "usage: %s <libwasmtime | --bundled> <guest.wasm>\n", argv[0]); return 1; }
  const char *guest = argv[2];
#endif
  setvbuf(stdout, NULL, _IONBF, 0);
#ifdef __aarch64__
  __asm__ volatile("mov %0, x28" : "=r"(g_tls));
#endif
#define STAGE(s) fprintf(stderr, "stage: %s\n", s)
  STAGE("dlopen");
#ifdef WT_STATIC
  void *h = 0;
#else
  char extracted[512]; const char *libpath = argv[1];
  if (!strcmp(libpath, "--bundled")) { if (!extract_bundled(extracted, sizeof extracted)) return 7; libpath = extracted; }
  void *h = cosmo_dlopen(libpath, RTLD_NOW); if (!h) { printf("dlopen failed: %s\n", cosmo_dlerror()); return 8; }
#endif
  STAGE("load symbols"); { int r = wt_load(h); if (r) return r; }
  FILE *f = fopen(guest, "rb"); if (!f) { perror("guest"); return 1; } fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t *wasm = malloc(len); if (fread(wasm, 1, len, f) != (size_t)len) return 1; fclose(f);

  STAGE("engine_new");
  /* WT_OPT: comma list of nomach (no Mach exception port thread on macOS), nosignals (explicit bounds checks instead of signal-based traps), pulley (interpreter instead of JIT) */
  const char *opt = getenv("WT_OPT"); if (!opt) opt = ""; fprintf(stderr, "stage: WT_OPT=%s\n", opt);
  wasm_config_t *cfg = wasm_config_new(); wasmtime_error_t *cerr = NULL;
  if (strstr(opt, "nomach")) wasmtime_config_macos_use_mach_ports_set(cfg, false);
  if (strstr(opt, "nosignals")) wasmtime_config_signals_based_traps_set(cfg, false);
  if (strstr(opt, "pulley")) { cerr = wasmtime_config_target_set(cfg, "pulley64"); if (cerr) die(cerr, NULL, "target pulley64"); }
  wasm_engine_t *engine = wasm_engine_new_with_config(cfg); STAGE("store_new"); wasmtime_store_t *store = wasmtime_store_new(engine, NULL, NULL); wasmtime_context_t *cx = wasmtime_store_context(store);
  wasi_config_t *wc = wasi_config_new(); wasi_config_inherit_stdout(wc); wasi_config_inherit_stderr(wc);
  wasmtime_error_t *err = wasmtime_context_set_wasi(cx, wc); if (err) die(err, NULL, "set_wasi");
  STAGE("linker"); wasmtime_linker_t *linker = wasmtime_linker_new(engine);
  err = wasmtime_linker_define_wasi(linker); if (err) die(err, NULL, "define_wasi");
  const char *mod = "sample:wire/transport@0.1.0";
  wasm_functype_t *ty = mk_i32i32_i32(), *ty2 = mk_i32i32_i32();
  err = wasmtime_linker_define_func(linker, mod, strlen(mod), "send", 4, ty, WT_CB(cb_send, wasmtime_func_callback_t), NULL, NULL); if (err) die(err, NULL, "define send");
  err = wasmtime_linker_define_func(linker, mod, strlen(mod), "recv", 4, ty2, WT_CB(cb_recv, wasmtime_func_callback_t), NULL, NULL); if (err) die(err, NULL, "define recv");
  STAGE("module_new"); wasmtime_module_t *module = NULL; err = wasmtime_module_new(engine, wasm, len, &module); if (err) die(err, NULL, "module_new");
  wasmtime_instance_t inst; wasm_trap_t *trap = NULL; err = wasmtime_linker_instantiate(linker, cx, module, &inst, &trap); if (err || trap) die(err, trap, "instantiate");
  STAGE("run _start"); wasmtime_extern_t start; if (!wasmtime_instance_export_get(cx, &inst, "_start", 6, &start)) { fprintf(stderr, "no _start\n"); return 3; }
  err = wasmtime_func_call(cx, &start.of.func, NULL, 0, NULL, 0, &trap);
  if (err) { int code; if (wasmtime_error_exit_status(err, &code)) { printf("host : guest exited with status %d\n", code); puts(code == 0 ? "RESULT PASS" : "RESULT FAIL"); return code; } die(err, NULL, "call"); }
  if (trap) die(NULL, trap, "trap");
  puts("host : guest returned"); puts("RESULT PASS"); return 0;
}
