/* Stress guest: compute, host calls, memory.grow and deliberate traps. Reactor exports; the host calls them from many OS threads at once. */
#include <stdint.h>
#include "kernels.h"
__attribute__((import_module("stress"), import_name("mix"))) uint32_t host_mix(uint32_t a, uint32_t b);
static volatile int zero;
static volatile int sink;
#define EXPORT(n) __attribute__((export_name(n)))
EXPORT("ok") int ok(void) { return 42; }
EXPORT("compute") uint64_t compute(uint32_t seed, uint32_t iters) { return wn_compute(seed, iters); }
EXPORT("hostmix") uint32_t hostmix(uint32_t seed, uint32_t n) { uint32_t r = seed; for (uint32_t i = 0; i < n; i++) r = host_mix(r, i); return r; }
EXPORT("grow") uint32_t grow(uint32_t n) {   /* memory.grow is a call from wasm into the runtime ("libcall"), made with whatever the wasm code left in its registers */
    uint32_t okc = 0, pages = 0;
    for (uint32_t i = 0; i < n; i++) { int old = __builtin_wasm_memory_grow(0, 1); if (old < 0) return 0xFFFFFFFFu; ((volatile uint8_t *)((uintptr_t)old * 65536))[0] = (uint8_t)i; okc++; pages += 1; }
    return pages * 1000 + okc;
}
EXPORT("oob") int oob(void) { return *(volatile int *)0xFFFFFFF0u; }                        /* base + 0xFFFFFFF0: 16 bytes below 4 GiB */
static volatile uint32_t oob2_base = 0xFFFFFFF0u;   /* a variable: with a constant clang folds 0xFFFFFFF0 + 80 modulo 2^32 into the in-bounds address 0x40 and nothing traps */
EXPORT("oob2") int oob2(void) { return ((volatile int *)(uintptr_t)oob2_base)[20]; }   /* load with static offset 80 on base 0xFFFFFFF0: effective address 0x100000040, beyond 4 GiB, inside the 2 GiB guard region */
EXPORT("oob3") int oob3(void) { return *(volatile int *)(__builtin_wasm_memory_size(0) * 65536u); }   /* first byte after the current end of the memory */
EXPORT("div0") int div0(void) { return 100 / zero; }
EXPORT("unreach") void unreach(void) { __builtin_trap(); }
static int (*volatile self_fp)(int);   /* an indirect call: clang turns a direct "return f(n+1)+1" into a loop (accumulator recursion elimination) */
__attribute__((noinline)) static int rec_impl(int n) { sink = n; return self_fp(n + 1) + 1; }
EXPORT("recurse") int recurse(int n) { self_fp = rec_impl; return rec_impl(n); }          /* never returns: the wasm call stack overflows */
