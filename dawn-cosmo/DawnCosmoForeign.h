// Foreign (driver) calls from threads the C library created, on Linux.
//
// Found by measurement (dawn-cosmo/direct-call): the system C library the driver is loaded with initialises per-thread state (locale and ctype pointers, errno, malloc cache) in a thread block
// that only its own pthread_create makes. A thread made by Cosmopolitan has no such block: on x86-64 the library reads garbage (SIGSEGV in ctype, errno, thread creation), on arm64 its thread-local
// variables overlay Cosmopolitan's own (heap corruption in operator new). The main thread has a proper block, so it works.
//
// Fix: the main thread makes a pool of PARKED threads with the library's own pthread_create (signals blocked, sleeping in pause()). A thread that calls into foreign code takes one parked thread's
// thread block and puts its thread pointer there (wrfsbase / arch_prctl on x86-64, tpidr_el0 on arm64) for exactly the duration of each foreign call. Asynchronous signals stay blocked on such threads, because
// a Cosmopolitan signal handler must not run with the library's thread pointer. Tested in the harness with ctype, malloc, errno, formatting, mutexes, once, pthread_self and foreign thread creation.
#ifndef DAWN_COSMO_FOREIGN_H
#define DAWN_COSMO_FOREIGN_H
#ifdef __COSMOPOLITAN__
extern "C" {
unsigned long DawnCosmoForeignTcb();   // thread block to run foreign calls on for THIS thread; 0 = none needed (main thread, or not Linux)
void DawnCosmoForeignInit();           // call on the main thread before other threads call foreign code (idempotent)
extern int gDawnCosmoFsgsbase;         // x86-64: wrfsbase/rdfsbase can be used instead of arch_prctl
}
static inline __attribute__((always_inline)) unsigned long DawnCosmoSwapIn(unsigned long tcb) {
    unsigned long saved;
#if defined(__x86_64__)
    if (gDawnCosmoFsgsbase) {
        __asm__ volatile("rdfsbase %0" : "=r"(saved) :: "memory");
        __asm__ volatile("wrfsbase %0" :: "r"(tcb) : "memory");
    } else {
        long r; saved = 0;
        __asm__ volatile("syscall" : "=a"(r) : "0"(158L), "D"(0x1003L), "S"((unsigned long)&saved) : "rcx", "r11", "memory");
        __asm__ volatile("syscall" : "=a"(r) : "0"(158L), "D"(0x1002L), "S"(tcb) : "rcx", "r11", "memory");
    }
#else
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(saved) :: "memory");
    __asm__ volatile("msr tpidr_el0, %0" :: "r"(tcb) : "memory");
#endif
    return saved;
}
static inline __attribute__((always_inline)) void DawnCosmoSwapOut(unsigned long saved) {
#if defined(__x86_64__)
    if (gDawnCosmoFsgsbase) {
        __asm__ volatile("wrfsbase %0" :: "r"(saved) : "memory");
    } else {
        long r; __asm__ volatile("syscall" : "=a"(r) : "0"(158L), "D"(0x1002L), "S"(saved) : "rcx", "r11", "memory");
    }
#else
    __asm__ volatile("msr tpidr_el0, %0" :: "r"(saved) : "memory");
#endif
}
struct DawnCosmoForeignScope {
    unsigned long saved;
    explicit DawnCosmoForeignScope(unsigned long tcb) : saved(DawnCosmoSwapIn(tcb)) {}
    ~DawnCosmoForeignScope() { DawnCosmoSwapOut(saved); }
};


#endif  // __COSMOPOLITAN__
#endif  // DAWN_COSMO_FOREIGN_H

#if defined(__COSMOPOLITAN__) && defined(DAWN_COSMO_FOREIGN_IMPL) && !defined(DAWN_COSMO_FOREIGN_IMPL_DONE)
#define DAWN_COSMO_FOREIGN_IMPL_DONE
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <sys/auxv.h>
#include <time.h>
#include <unistd.h>
int gDawnCosmoFsgsbase = 0;
namespace {
constexpr int kPool = 64;
unsigned long gPool[kPool];
std::atomic<int> gUsed[kPool];
int gCount = 0;
bool gInitDone = false;
inline unsigned long ReadTp() {
    unsigned long tp;
#if defined(__x86_64__)
    __asm__ volatile("mov %%fs:0, %0" : "=r"(tp));
#else
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
#endif
    return tp;
}
struct Slot { int idx = -1; unsigned long tcb = 0; ~Slot() { if (idx >= 0) gUsed[idx].store(0); } };
thread_local Slot gSlot;
thread_local bool gChecked = false;
}  // namespace
extern "C" void DawnCosmoForeignInit() {
    if (gInitDone) return;
    gInitDone = true;
    if (!IsLinux() || gettid() != getpid()) return;   // only the main thread has the library's own thread block to ask for pthread_self and to call pthread_create with
#if defined(__x86_64__)
    gDawnCosmoFsgsbase = (getauxval(AT_HWCAP2) & 2) ? 1 : 0;   // HWCAP2_FSGSBASE
#endif
    void* libc = cosmo_dlopen("libc.so.6", RTLD_NOW);
    if (!libc) return;
    auto pcreate = reinterpret_cast<int (*)(unsigned long*, const void*, void* (*)(void*), void*)>(cosmo_dltramp(cosmo_dlsym(libc, "pthread_create")));
    auto pself = reinterpret_cast<unsigned long (*)()>(cosmo_dltramp(cosmo_dlsym(libc, "pthread_self")));
    void* pauseFn = cosmo_dlsym(libc, "pause");   // runs inside the library only; called directly, not through a thunk
    if (!pcreate || !pself || !pauseFn) return;
    unsigned long off = ReadTp() - pself();       // 0 on x86-64; the size of the library's struct pthread on arm64
    sigset_t all, old; sigfillset(&all); pthread_sigmask(SIG_SETMASK, &all, &old);
    for (int i = 0; i < kPool; i++) {
        unsigned long t = 0;
        if (pcreate(&t, nullptr, reinterpret_cast<void* (*)(void*)>(pauseFn), nullptr)) break;
        gPool[gCount++] = t + off;
    }
    pthread_sigmask(SIG_SETMASK, &old, nullptr);
}
extern "C" unsigned long DawnCosmoForeignTcb() {
    if (gChecked) return gSlot.tcb;
    gChecked = true;
    if (!gInitDone || gCount == 0 || gettid() == getpid()) return 0;
    for (int i = 0; i < gCount; i++) {
        int zero = 0;
        if (gUsed[i].compare_exchange_strong(zero, 1)) {
            gSlot.idx = i; gSlot.tcb = gPool[i];
            sigset_t m; sigfillset(&m); sigdelset(&m, SIGSEGV); sigdelset(&m, SIGBUS); sigdelset(&m, SIGFPE); sigdelset(&m, SIGILL); sigdelset(&m, SIGTRAP);
            pthread_sigmask(SIG_BLOCK, &m, nullptr);   // see the header comment: no Cosmopolitan signal handler while the library's thread pointer is in place
            return gSlot.tcb;
        }
    }
    fprintf(stderr, "dawn-cosmo: more threads call the driver than the %d parked thread blocks\n", gCount); abort();
}

#endif

