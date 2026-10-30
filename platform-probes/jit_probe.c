/* Can a Cosmopolitan program create executable memory on this OS (what a JIT, or a loader for ahead-of-time compiled wasm code, needs)?
 * Tries: map read-write, write machine code, switch to read-execute, call it; map read-write-execute directly; map with MAP_JIT (Apple). Prints one line per attempt. */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
#include <cosmo.h>
#ifdef __x86_64__
static const unsigned char code[] = {0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3};            /* mov eax, 42 ; ret */
#else
static const unsigned char code[] = {0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6}; /* mov w0, #42 ; ret */
#endif
#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif
static void attempt(const char *name, int prot_first, int flags, int then_protect) {
    void *p = mmap(0, 65536, prot_first, MAP_PRIVATE | MAP_ANONYMOUS | flags, -1, 0);
    if (p == MAP_FAILED) { printf("%-40s mmap failed: errno=%d %s\n", name, errno, strerror(errno)); return; }
    if (prot_first & PROT_WRITE) memcpy(p, code, sizeof code);
    if (then_protect && mprotect(p, 65536, PROT_READ | PROT_EXEC)) { printf("%-40s mprotect(RX) failed: errno=%d %s\n", name, errno, strerror(errno)); munmap(p, 65536); return; }
    __builtin___clear_cache((char *)p, (char *)p + sizeof code);
    int r = ((int (*)(void))p)();
    printf("%-40s OK, called generated code, result=%d\n", name, r);
    munmap(p, 65536);
}
int main(void) {
    printf("platform: %s, arch: %s\n", IsWindows() ? "Windows" : IsXnu() ? "macOS" : IsLinux() ? "Linux" : "other", IsAarch64() ? "arm64" : "x86-64");
    fflush(stdout);
    attempt("RW, write, mprotect RX", PROT_READ | PROT_WRITE, 0, 1);
    attempt("RWX mapped directly", PROT_READ | PROT_WRITE | PROT_EXEC, 0, 0);
    attempt("MAP_JIT RWX", PROT_READ | PROT_WRITE | PROT_EXEC, MAP_JIT, 0);
    attempt("MAP_JIT RW, write, mprotect RX", PROT_READ | PROT_WRITE, MAP_JIT, 1);
    return 0;
}
