/* Plain-C host for a WASI p2 or p3 COMPONENT via the Wasmtime C API. No Rust written here.
 * usage: p3-host <component.wasm> p2|p3
 *   p2 -> wasmtime_component_linker_add_wasip2_async   (in the official C API)
 *   p3 -> wasmtime_component_linker_add_wasip3         (added by wasmtime-c-api-wasip3.patch, 7 lines of Rust)
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <wasmtime.h>
wasmtime_error_t *wasmtime_component_linker_add_wasip3(wasmtime_component_linker_t *linker);   /* declared by the patched header; repeated so this file also compiles (and reports a clear error) against an unpatched one */

static void die(wasmtime_error_t *e, const char *what) {
  wasm_byte_vec_t m; wasmtime_error_message(e, &m); fprintf(stderr, "%s: %.*s\n", what, (int)m.size, m.data); exit(2);
}
static void drive(wasmtime_call_future_t *f) { while (!wasmtime_call_future_poll(f)) { /* the host could do other work here: this is where an event loop or GPU poll goes */ } wasmtime_call_future_delete(f); }

int main(int argc, char **argv) {
  if (argc < 3) return 1;
  int p3 = !strcmp(argv[2], "p3");
  FILE *fp = fopen(argv[1], "rb"); if (!fp) { perror("component"); return 1; }
  fseek(fp, 0, SEEK_END); long len = ftell(fp); fseek(fp, 0, SEEK_SET); uint8_t *bytes = malloc(len); if (fread(bytes, 1, len, fp) != (size_t)len) return 1; fclose(fp);

  wasm_config_t *cfg = wasm_config_new();
  wasmtime_config_wasm_component_model_set(cfg, true);
  wasmtime_config_wasm_component_model_async_set(cfg, true);
  wasm_engine_t *engine = wasm_engine_new_with_config(cfg);
  wasmtime_store_t *store = wasmtime_store_new(engine, NULL, NULL); wasmtime_context_t *cx = wasmtime_store_context(store);
  wasi_config_t *wc = wasi_config_new(); wasi_config_inherit_stdout(wc); wasi_config_inherit_stderr(wc);
  wasmtime_error_t *err = wasmtime_context_set_wasi(cx, wc); if (err) die(err, "set_wasi");

  wasmtime_component_t *comp = NULL; err = wasmtime_component_new(engine, bytes, len, &comp); if (err) die(err, "component_new");
  wasmtime_component_linker_t *linker = wasmtime_component_linker_new(engine);
  err = p3 ? wasmtime_component_linker_add_wasip3(linker) : wasmtime_component_linker_add_wasip2_async(linker); if (err) die(err, "add_wasi");

  wasmtime_component_instance_t inst; err = NULL;
  drive(wasmtime_component_linker_instantiate_async(linker, cx, comp, &inst, &err)); if (err) die(err, "instantiate");

  const char *iface = p3 ? "wasi:cli/run@0.3.0" : "wasi:cli/run@0.2.12";
  wasmtime_component_export_index_t *ii = wasmtime_component_get_export_index(comp, NULL, iface, strlen(iface));
  if (!ii) { fprintf(stderr, "no export %s\n", iface); return 3; }
  wasmtime_component_export_index_t *fi = wasmtime_component_get_export_index(comp, ii, "run", 3);
  wasmtime_component_func_t run; if (!fi || !wasmtime_component_instance_get_func(&inst, cx, fi, &run)) { fprintf(stderr, "no run func\n"); return 3; }

  wasmtime_component_val_t res; memset(&res, 0, sizeof res); err = NULL;
  drive(wasmtime_component_func_call_async(&run, cx, NULL, 0, &res, 1, &err)); if (err) die(err, "call run");
  int ok = res.kind == WASMTIME_COMPONENT_RESULT && res.of.result.is_ok;
  printf("host : %s run() returned %s\n", p3 ? "wasip3" : "wasip2", ok ? "ok" : "err");
  puts(ok ? "RESULT PASS" : "RESULT FAIL"); return ok ? 0 : 4;
}
