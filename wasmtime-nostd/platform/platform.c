/* Platform layer for Wasmtime's custom-platform build, written for Cosmopolitan: one implementation for every OS the file runs on.
 * Derived from Wasmtime's examples/min-platform/embedding/wasmtime-platform.c (Apache-2.0 WITH LLVM-exception); Cosmopolitan's mmap/mprotect/sigaction translate to the host OS.
 * Beyond the minimal example: many threads (locks, per-thread trap state, atomic wait/notify for the wasm threads proposal) and the real faulting address on Windows. */
#define _COSMO_SOURCE 1
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <cosmo.h>
#include <libc/calls/ucontext.h>
#include "wasmtime-platform.h"
#include "wn-platform.h"
#ifdef __x86_64__
/* the part of the Windows exception record we read (declared here so no Cosmopolitan NT header is needed) */
struct NtExceptionRecord { uint32_t ExceptionCode, ExceptionFlags; void *ExceptionRecord; void *ExceptionAddress; uint32_t NumberParameters; uint64_t ExceptionInformation[15]; };
struct NtExceptionPointers { struct NtExceptionRecord *ExceptionRecord; void *ContextRecord; };
int64_t AddVectoredExceptionHandler(uint32_t First, int32_t (*Handler)(struct NtExceptionPointers *));
#endif

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

/* One pointer of thread-local state per slot. Thread-locals in Cosmopolitan are reached through the thread pointer (x28 on arm64), which is intact because the wasm compiler
 * (patched Cranelift) never allocates x28; with an unpatched compiler see lib.rs (wn_x28_save). */
static _Thread_local uint8_t *tls[2];
uint8_t *wasmtime_tls_get(uintptr_t slot) { return tls[slot]; }
void wasmtime_tls_set(uintptr_t slot, uint8_t *v) { tls[slot] = v; }

/* ---- locks for Wasmtime's shared structures (the storage word starts as 0 and is initialised on first use) ---- */
static void *lazy(uintptr_t *slot, size_t size, int rw) {
    uintptr_t cur = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (cur) return (void *)cur;
    void *m = malloc(size);
    if (rw) pthread_rwlock_init(m, NULL); else pthread_mutex_init(m, NULL);
    uintptr_t expect = 0;
    if (__atomic_compare_exchange_n(slot, &expect, (uintptr_t)m, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return m;
    if (rw) pthread_rwlock_destroy(m); else pthread_mutex_destroy(m);
    free(m); return (void *)expect;
}
void wasmtime_sync_lock_acquire(uintptr_t *l) { pthread_mutex_lock(lazy(l, sizeof(pthread_mutex_t), 0)); }
void wasmtime_sync_lock_release(uintptr_t *l) { pthread_mutex_unlock((pthread_mutex_t *)*l); }
void wasmtime_sync_lock_free(uintptr_t *l) { if (*l) { pthread_mutex_destroy((pthread_mutex_t *)*l); free((void *)*l); *l = 0; } }
void wasmtime_sync_rwlock_read(uintptr_t *l) { pthread_rwlock_rdlock(lazy(l, sizeof(pthread_rwlock_t), 1)); }
void wasmtime_sync_rwlock_read_release(uintptr_t *l) { pthread_rwlock_unlock((pthread_rwlock_t *)*l); }
void wasmtime_sync_rwlock_write(uintptr_t *l) { pthread_rwlock_wrlock(lazy(l, sizeof(pthread_rwlock_t), 1)); }
void wasmtime_sync_rwlock_write_release(uintptr_t *l) { pthread_rwlock_unlock((pthread_rwlock_t *)*l); }
void wasmtime_sync_rwlock_free(uintptr_t *l) { if (*l) { pthread_rwlock_destroy((pthread_rwlock_t *)*l); free((void *)*l); *l = 0; } }

/* ---- memory.atomic.wait32/wait64 and memory.atomic.notify (wasm threads proposal; called from the patched shared_memory.rs) ----
 * One global lock and a FIFO list of waiters keyed by address: the comparison and the enqueue happen under the lock that notify takes, so a wake-up cannot be lost. */
struct waiter { struct waiter *next; const uint8_t *addr; pthread_cond_t cv; int notified; };
static pthread_mutex_t park_mu = PTHREAD_MUTEX_INITIALIZER; static struct waiter *park_head, *park_tail;
int32_t wn_atomic_wait(const uint8_t *addr, uint32_t size, uint64_t expected, int64_t timeout_ns) {
    struct waiter w; memset(&w, 0, sizeof w); w.addr = addr; pthread_cond_init(&w.cv, NULL);
    struct timespec dl = {0, 0};
    if (timeout_ns >= 0) { clock_gettime(CLOCK_REALTIME, &dl); int64_t ns = dl.tv_nsec + timeout_ns % 1000000000; dl.tv_sec += timeout_ns / 1000000000 + ns / 1000000000; dl.tv_nsec = ns % 1000000000; }
    pthread_mutex_lock(&park_mu);
    uint64_t cur = size == 4 ? __atomic_load_n((const uint32_t *)addr, __ATOMIC_SEQ_CST) : __atomic_load_n((const uint64_t *)addr, __ATOMIC_SEQ_CST);
    if (size == 4) expected = (uint32_t)expected;
    if (cur != expected) { pthread_mutex_unlock(&park_mu); pthread_cond_destroy(&w.cv); return 1; }
    if (park_tail) park_tail->next = &w; else park_head = &w;
    park_tail = &w;
    int result = 0;
    while (!w.notified) {
        if (timeout_ns < 0) { pthread_cond_wait(&w.cv, &park_mu); continue; }
        if (pthread_cond_timedwait(&w.cv, &park_mu, &dl) == ETIMEDOUT && !w.notified) {
            struct waiter **pp = &park_head, *prev = NULL;   /* still queued: unlink */
            while (*pp && *pp != &w) { prev = *pp; pp = &(*pp)->next; }
            if (*pp) { *pp = w.next; if (park_tail == &w) park_tail = prev; }
            result = 2; break;
        }
    }
    pthread_mutex_unlock(&park_mu);
    pthread_cond_destroy(&w.cv);
    return result;
}
uint32_t wn_atomic_notify(const uint8_t *addr, uint32_t count) {
    uint32_t n = 0;
    pthread_mutex_lock(&park_mu);
    struct waiter **pp = &park_head, *prev = NULL;
    while (*pp && n < count) {
        struct waiter *w = *pp;
        if (w->addr == addr) { *pp = w->next; if (park_tail == w) park_tail = prev; w->notified = 1; pthread_cond_signal(&w->cv); n++; }
        else { prev = w; pp = &w->next; }
    }
    pthread_mutex_unlock(&park_mu);
    return n;
}

/* ---- traps ---- */
static wasmtime_trap_handler_t g_handler;
static _Thread_local struct WnFault g_fault;
const struct WnFault *wn_last_fault(void) { return &g_fault; }
extern uint8_t wn_x28_save;
#ifdef __aarch64__
extern uint64_t wn_host_x28;   /* Rust side: the value x28 had when the host called into wasm (only with wn_x28_save) */
#define FIX_X28() do { if (wn_x28_save) __asm__ volatile("mov x28, %0" :: "r"(wn_host_x28) : "memory"); } while (0)
#else
#define FIX_X28()
#endif

#ifdef __x86_64__
/* Windows: Cosmopolitan's own vectored exception handler (libc/intrin/sig.c, __sig_crash) turns an access violation into SIGSEGV with si_addr = ExceptionAddress, the INSTRUCTION address;
 * the data address is in ExceptionRecord->ExceptionInformation[1] and is dropped. Our handler is registered later with First=1, so it runs first on the faulting thread; it only records
 * what Windows reported and lets Cosmopolitan's handler continue (EXCEPTION_CONTINUE_SEARCH = 0). The signal handler below picks the record up (same thread, same fault). */
static _Thread_local struct { uintptr_t ip, addr, kind; int valid; } g_veh;
__attribute__((__ms_abi__)) static int32_t wn_veh(struct NtExceptionPointers *ep) {
    struct NtExceptionRecord *r = ep->ExceptionRecord;
    if (r->ExceptionCode == 0xC0000005u && r->NumberParameters >= 2) {   /* STATUS_ACCESS_VIOLATION: [0] 0 read, 1 write, 8 execute; [1] address */
        g_veh.ip = (uintptr_t)r->ExceptionAddress; g_veh.kind = (uintptr_t)r->ExceptionInformation[0]; g_veh.addr = (uintptr_t)r->ExceptionInformation[1]; g_veh.valid = 1;
    }
    return 0;
}
#endif

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
    int source = 0;   /* 0 si_addr, 1 Windows exception record, 2 unknown */
#ifdef __x86_64__
    if (IsWindows()) {
        if (has_addr && g_veh.valid && g_veh.ip == ip) { fault = g_veh.addr; source = 1; }
        else if (has_addr) { has_addr = false; source = 2; }
        g_veh.valid = 0;
    }
#endif
    g_fault.signo = signo; g_fault.code = info->si_code; g_fault.ip = ip; g_fault.si_addr = (uintptr_t)info->si_addr; g_fault.addr = has_addr ? fault : 0; g_fault.has_addr = has_addr; g_fault.source = source;
    if (getenv("WN_TRACE")) fprintf(stderr, "[wn] signal %d code %d ip %p fp %p si_addr %p -> %s %p (source %s)\n", signo, info->si_code, (void *)ip, (void *)fp, info->si_addr, has_addr ? "fault address" : "no address", (void *)fault, source == 1 ? "windows exception record" : source == 2 ? "unknown" : "si_addr");
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
#ifdef __x86_64__
    if (IsWindows()) AddVectoredExceptionHandler(1, (int32_t (*)(struct NtExceptionPointers *))wn_veh);
#endif
    return 0;
}
