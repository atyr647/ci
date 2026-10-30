/* Asyncify test: a call chain DEPTH frames deep ends in a host import that "waits"; after wasm-opt --asyncify the host can unwind the whole wasm stack, do other work, and rewind it.
 * The same source built without asyncify, with a plain synchronous host function, is the baseline. N awaits per run. */
#ifndef DEPTH
#define DEPTH 0
#endif
#ifndef N
#define N 20000
#endif
__attribute__((import_module("env"), import_name("await_host"))) int await_host(int);
static struct { int cur, end; char stack[1 << 16]; } asy_data;
__attribute__((export_name("asyncify_data_addr"))) void *asyncify_data_addr(void) { return &asy_data; }
__attribute__((noinline)) static int chain(int d, int x) { if (d == 0) return await_host(x); return chain(d - 1, x) + 1; }
__attribute__((export_name("run"))) int run(void) { int sum = 0; for (int i = 0; i < N; i++) sum += chain(DEPTH, i); return sum; }
/* expected: sum over i of (2i+1+DEPTH) = N*N + N*DEPTH (fits in int for N=20000: 4e8 + ...) */
__attribute__((export_name("expected"))) int expected(void) { return N * N + N * DEPTH; }
__attribute__((export_name("t_matches")) ) int t_matches(void) { return run() == expected(); }
