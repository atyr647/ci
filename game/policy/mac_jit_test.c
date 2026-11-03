// macOS: what the hardened runtime does to the memory patterns this project uses. Run unsigned, signed ad hoc with the hardened runtime, and with each entitlement that changes the answer.
//   A: mmap read+write, write code, mprotect read+execute (what Wasmtime does when it loads precompiled code)
//   B: MAP_JIT mapping, write with pthread_jit_write_protect_np, run (the sanctioned JIT route)
//   C: mmap read+write+execute without MAP_JIT
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
static const unsigned ret_insn = 0xD65F03C0;   // ret
static int run(void *p) { __builtin___clear_cache(p, (char *)p + 4); return ((int (*)(void))p)(), 0; }
int main(void) {
    void *a = mmap(0, 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (a == MAP_FAILED) printf("A: mmap rw failed: %s\n", strerror(errno)); else { memcpy(a, &ret_insn, 4); int r = mprotect(a, 16384, PROT_READ | PROT_EXEC); if (r) printf("A: write then mprotect(r-x): DENIED (%s)\n", strerror(errno)); else { run(a); printf("A: write then mprotect(r-x): allowed and ran\n"); } }
    void *b = mmap(0, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (b == MAP_FAILED) printf("B: MAP_JIT mapping: DENIED (%s)\n", strerror(errno)); else { pthread_jit_write_protect_np(0); memcpy(b, &ret_insn, 4); pthread_jit_write_protect_np(1); sys_icache_invalidate(b, 4); ((int (*)(void))b)(); printf("B: MAP_JIT write-protect toggle: allowed and ran\n"); }
    void *c = mmap(0, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (c == MAP_FAILED) printf("C: rwx mapping without MAP_JIT: DENIED (%s)\n", strerror(errno)); else { memcpy(c, &ret_insn, 4); sys_icache_invalidate(c, 4); ((int (*)(void))c)(); printf("C: rwx mapping without MAP_JIT: allowed and ran\n"); }
    return 0;
}
