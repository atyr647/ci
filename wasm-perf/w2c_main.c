/* Host for a wasm2c-translated wasi-libc module (shootout.wasm): a minimal WASI (stdout/stderr writes, clock, exit) around the generated C.
 * Build: cc -O3 -DW2C_NAME=so -include so.h w2c_main.c so.c wasm-rt-impl.c wasm-rt-mem-impl.c ... (see .github/workflows/wasm-shootout.yml) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include <setjmp.h>
#include "wasm-rt.h"
#include W2C_HEADER

#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
#define MOD CAT(w2c_, W2C_NAME)
#define EXPORT(x) CAT(MOD, CAT(_, x))
#define WASI(x) w2c_wasi__snapshot__preview1_##x

static jmp_buf g_trap; void w2c_trap_handler(wasm_rt_trap_t code) { longjmp(g_trap, (int)code + 1); }   /* -DWASM_RT_TRAP_HANDLER=w2c_trap_handler */
struct w2c_wasi__snapshot__preview1 { MOD *inst; };
static struct w2c_wasi__snapshot__preview1 wasi;

static uint8_t *mem(void) { return EXPORT(memory)(wasi.inst)->data; }
u32 WASI(fd_write)(struct w2c_wasi__snapshot__preview1 *w, u32 fd, u32 iovs, u32 n, u32 nwritten) {
    uint8_t *m = mem(); u32 total = 0;
    for (u32 i = 0; i < n; i++) { u32 p, l; memcpy(&p, m + iovs + 8 * i, 4); memcpy(&l, m + iovs + 8 * i + 4, 4); fwrite(m + p, 1, l, fd == 2 ? stderr : stdout); total += l; }
    memcpy(m + nwritten, &total, 4); return 0;
}
u32 WASI(clock_time_get)(struct w2c_wasi__snapshot__preview1 *w, u32 id, u64 prec, u32 out) {
    struct timespec t; clock_gettime(id == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &t); uint64_t ns = (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; memcpy(mem() + out, &ns, 8); return 0;
}
void WASI(proc_exit)(struct w2c_wasi__snapshot__preview1 *w, u32 code) { fflush(stdout); exit((int)code); }
u32 WASI(args_sizes_get)(struct w2c_wasi__snapshot__preview1 *w, u32 argc, u32 sz) { u32 z = 0; memcpy(mem() + argc, &z, 4); memcpy(mem() + sz, &z, 4); return 0; }
u32 WASI(args_get)(struct w2c_wasi__snapshot__preview1 *w, u32 a, u32 b) { return 0; }
u32 WASI(environ_sizes_get)(struct w2c_wasi__snapshot__preview1 *w, u32 c, u32 sz) { u32 z = 0; memcpy(mem() + c, &z, 4); memcpy(mem() + sz, &z, 4); return 0; }
u32 WASI(environ_get)(struct w2c_wasi__snapshot__preview1 *w, u32 a, u32 b) { return 0; }
u32 WASI(fd_close)(struct w2c_wasi__snapshot__preview1 *w, u32 fd) { return 0; }
u32 WASI(fd_seek)(struct w2c_wasi__snapshot__preview1 *w, u32 fd, u64 off, u32 whence, u32 out) { return 70; }
u32 WASI(fd_fdstat_get)(struct w2c_wasi__snapshot__preview1 *w, u32 fd, u32 out) { memset(mem() + out, 0, 24); mem()[out] = 2; return 0; }   /* character device */

int main(void) {
    wasm_rt_init();
    MOD inst;
    CAT(wasm2c_, CAT(W2C_NAME, _instantiate))(&inst, &wasi);
    wasi.inst = &inst;
    int code = setjmp(g_trap);
    if (code) { fprintf(stderr, "trap %d\n", code - 1); return 1; }
    CAT(MOD, _0x5Fstart)(&inst);
    CAT(wasm2c_, CAT(W2C_NAME, _free))(&inst);
    wasm_rt_free();
    return 0;
}
