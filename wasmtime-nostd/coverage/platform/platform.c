/* COVERAGE COPY of ../../platform/platform.c: the mmap family also puts the host x28 in around its C library calls (arm64). Platform layer for Wasmtime's custom-platform build, written for Cosmopolitan: one implementation for every OS the file runs on.
 * Derived from Wasmtime's examples/min-platform/embedding/wasmtime-platform.c (Apache-2.0 WITH LLVM-exception); Cosmopolitan's mmap/mprotect/sigaction translate to the host OS. */
#define _COSMO_SOURCE 1
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <unistd.h>
#include <cosmo.h>
#include <libc/calls/ucontext.h>
#include "wasmtime-platform.h"

#ifdef __aarch64__
extern uint64_t wn_host_x28;   /* Rust side: the value x28 had when the host called into wasm */
#define FIX_X28() __asm__ volatile("mov x28, %0" :: "r"(wn_host_x28) : "memory")
/* Entered from wasm (libcall) or from Rust running on the way out of wasm, x28 may hold anything: save it, put the host value in for the C library, restore on the way out. */
#define ENTER() uint64_t _sv = 0; if (wn_host_x28) { __asm__ volatile("mov %0, x28" : "=r"(_sv)); FIX_X28(); }
#define LEAVE() if (wn_host_x28) __asm__ volatile("mov x28, %0" :: "r"(_sv) : "memory")
#else
#define FIX_X28()
#define ENTER()
#define LEAVE()
#endif

static int to_prot(uint32_t f) { return ((f & WASMTIME_PROT_READ) ? PROT_READ : 0) | ((f & WASMTIME_PROT_WRITE) ? PROT_WRITE : 0) | ((f & WASMTIME_PROT_EXEC) ? PROT_EXEC : 0); }

int32_t wasmtime_mmap_new(uintptr_t size, uint32_t prot, uint8_t **ret) {
    ENTER();
    void *p = mmap(NULL, size, to_prot(prot), MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    int32_t r = 0;
    if (p == MAP_FAILED) r = errno ? errno : 1; else *ret = p;
    LEAVE(); return r;
}
int32_t wasmtime_mmap_remap(uint8_t *addr, uintptr_t size, uint32_t prot) {
    ENTER();
    void *p = mmap(addr, size, to_prot(prot), MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    int32_t r = p == MAP_FAILED ? (errno ? errno : 1) : 0;
    LEAVE(); return r;
}
int32_t wasmtime_munmap(uint8_t *ptr, uintptr_t size) { ENTER(); int32_t r = munmap(ptr, size) ? (errno ? errno : 1) : 0; LEAVE(); return r; }
int32_t wasmtime_mprotect(uint8_t *ptr, uintptr_t size, uint32_t prot) { ENTER(); int32_t r = mprotect(ptr, size, to_prot(prot)) ? (errno ? errno : 1) : 0; LEAVE(); return r; }
uintptr_t wasmtime_page_size(void) { ENTER(); uintptr_t r = sysconf(_SC_PAGESIZE); LEAVE(); return r; }

int32_t wasmtime_memory_image_new(const uint8_t *ptr, uintptr_t len, struct wasmtime_memory_image **ret) { *ret = NULL; return 0; }   /* no copy-on-write images: memories are initialised by copying */
int32_t wasmtime_memory_image_map_at(struct wasmtime_memory_image *image, uint8_t *addr, uintptr_t len) { abort(); }
void wasmtime_memory_image_free(struct wasmtime_memory_image *image) { abort(); }

/* one pointer of thread-local state per slot (Cosmopolitan implements thread-locals on every OS) */
/* Plain statics, not thread-locals: on arm64 Cosmopolitan reaches its thread-local storage through x28, which Cranelift-generated code uses as an ordinary register.
 * (One wasm thread per process; several threads would need a lookup that does not depend on x28.) */
static uint8_t *tls[2];

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
    uintptr_t fault = (uintptr_t)info->si_addr;
    /* Cosmopolitan on Windows reports the INSTRUCTION address in si_addr for an access violation (measured: si_addr == ip), not the address that was accessed.
     * Use the CR2 slot of the context if it carries something else; otherwise say "address unknown" (Wasmtime then skips its extra check that the address lies in a linear memory). */
#ifdef __x86_64__
    uintptr_t cr2 = (uintptr_t)cx->uc_mcontext.cr2;
#else
    uintptr_t cr2 = (uintptr_t)cx->uc_mcontext.fault_address;
#endif
    if (IsWindows()) { if (cr2 && cr2 != ip) fault = cr2; else has_addr = false; }
    if (getenv("WN_TRACE")) fprintf(stderr, "[wn] signal %d code %d ip %p fp %p si_addr %p cr2 %p -> %s %p\n", signo, info->si_code, (void *)ip, (void *)fp, info->si_addr, (void *)cr2, has_addr ? "fault address" : "no address", (void *)fault);
    g_handler(ip, fp, has_addr, has_addr ? fault : 0);
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
