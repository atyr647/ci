/* Platform layer for Wasmtime's custom-platform build, written for Cosmopolitan: one implementation for every OS the file runs on.
 * Derived from Wasmtime's examples/min-platform/embedding/wasmtime-platform.c (Apache-2.0 WITH LLVM-exception); Cosmopolitan's mmap/mprotect/sigaction translate to the host OS. */
#define _COSMO_SOURCE 1
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libc/calls/ucontext.h>
#include "wasmtime-platform.h"

static int to_prot(uint32_t f) { return ((f & WASMTIME_PROT_READ) ? PROT_READ : 0) | ((f & WASMTIME_PROT_WRITE) ? PROT_WRITE : 0) | ((f & WASMTIME_PROT_EXEC) ? PROT_EXEC : 0); }

int32_t wasmtime_mmap_new(uintptr_t size, uint32_t prot, uint8_t **ret) {
    void *p = mmap(NULL, size, to_prot(prot), MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return errno ? errno : 1;
    *ret = p; return 0;
}
int32_t wasmtime_mmap_remap(uint8_t *addr, uintptr_t size, uint32_t prot) {
    void *p = mmap(addr, size, to_prot(prot), MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? (errno ? errno : 1) : 0;
}
int32_t wasmtime_munmap(uint8_t *ptr, uintptr_t size) { return munmap(ptr, size) ? (errno ? errno : 1) : 0; }
int32_t wasmtime_mprotect(uint8_t *ptr, uintptr_t size, uint32_t prot) { return mprotect(ptr, size, to_prot(prot)) ? (errno ? errno : 1) : 0; }
uintptr_t wasmtime_page_size(void) { return sysconf(_SC_PAGESIZE); }

int32_t wasmtime_memory_image_new(const uint8_t *ptr, uintptr_t len, struct wasmtime_memory_image **ret) { *ret = NULL; return 0; }   /* no copy-on-write images: memories are initialised by copying */
int32_t wasmtime_memory_image_map_at(struct wasmtime_memory_image *image, uint8_t *addr, uintptr_t len) { abort(); }
void wasmtime_memory_image_free(struct wasmtime_memory_image *image) { abort(); }

/* one pointer of thread-local state per slot (Cosmopolitan implements thread-locals on every OS) */
/* Plain statics, not thread-locals: on arm64 Cosmopolitan reaches its thread-local storage through x28, which Cranelift-generated code uses as an ordinary register.
 * (One wasm thread per process; several threads would need a lookup that does not depend on x28.) */
static uint8_t *tls[2];
#ifdef __aarch64__
extern uint64_t wn_host_x28;   /* Rust side: the value x28 had when the host called into wasm */
#define FIX_X28() __asm__ volatile("mov x28, %0" :: "r"(wn_host_x28) : "memory")
#else
#define FIX_X28()
#endif
uint8_t *wasmtime_tls_get(uintptr_t slot) { return tls[slot]; }
void wasmtime_tls_set(uintptr_t slot, uint8_t *v) { tls[slot] = v; }

static wasmtime_trap_handler_t g_handler;
static void on_signal(int signo, siginfo_t *info, void *context) {
    FIX_X28();
    ucontext_t *cx = context; uintptr_t ip, fp;
#if defined(__aarch64__)
    ip = cx->uc_mcontext.pc; fp = cx->uc_mcontext.regs[29];
#else
    ip = cx->uc_mcontext.rip; fp = cx->uc_mcontext.rbp;
#endif
    bool has_addr = signo == SIGSEGV || signo == SIGBUS;
    g_handler(ip, fp, has_addr, has_addr ? (uintptr_t)info->si_addr : 0);
    /* not a trap of ours: fall back to the default action (crash with the original signal) */
    signal(signo, SIG_DFL);
}
int32_t wasmtime_init_traps(wasmtime_trap_handler_t handler) {
    g_handler = handler;
    struct sigaction a; memset(&a, 0, sizeof a);
    a.sa_sigaction = on_signal; a.sa_flags = SA_SIGINFO | SA_NODEFER; sigemptyset(&a.sa_mask);
    int sigs[] = {SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGTRAP};
    for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) if (sigaction(sigs[i], &a, NULL)) return errno ? errno : 1;
    return 0;
}
