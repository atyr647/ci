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
extern "C" int gettid(void);   // Cosmopolitan declares it only under _COSMO_SOURCE (cosmocc's GCC driver defines that; the clang wrapper does not)
extern "C" {
unsigned long DawnCosmoForeignTcb();   // thread block to run foreign calls on for THIS thread; 0 = none needed (main thread, or not Linux)
void DawnCosmoForeignInit();           // call on the main thread before other threads call foreign code (idempotent)
void DawnCosmoWarmDriverHeap();        // Linux, glibc: populate the driver's heap (3 MiB) right before a burst of resource creation, on the main thread: the pages are paid for here instead of in the middle of the burst. Work the driver does in between (pipeline compiles) churns the heap again, so call it just before the burst, not at start-up
void DawnCosmoWarmDriverHeapKB(long kb);   // the same with a size in KiB (the burst of 4,000 buffers of 64 KiB grew the heap by about 2.6 MB)
extern int gDawnCosmoFsgsbase;         // x86-64: wrfsbase/rdfsbase can be used instead of arch_prctl
void DawnCosmoSeedDlopenHelper();   // Linux: put the pre-built dlopen helper where Cosmopolitan looks for it, so no C compiler is needed on the user's machine
void* DawnCosmoDlopen(const char* file, int mode);   // cosmo_dlopen, except that the Vulkan loader loaded ahead of time by the main thread is handed out without a foreign call
int DawnCosmoDlclose(void* handle);   // cosmo_dlclose, except for the built-in software ICD (nothing was loaded)
bool DawnCosmoStaticIcd();            // true once Dawn's Vulkan loader was bound to the Vulkan driver linked INTO this file (SwiftShader), which is native code: called directly, no foreign-call machinery
void* DawnCosmoDlsym(void* handle, const char* name);   // likewise for vkGetInstanceProcAddr (a foreign dlsym on a created thread would need the library's thread block, and cosmo_dlsym cannot be wrapped: most of it is Cosmopolitan code)
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
#include <initializer_list>
#include <sys/mman.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
int gDawnCosmoFsgsbase = 0;
extern "C" int madvise(void*, unsigned long, int);   // (declared by Cosmopolitan's headers only under _COSMO_SOURCE, which the clang driver wrapper does not define)
namespace {
constexpr int kPool = 64;
unsigned long gPool[kPool];
std::atomic<int> gUsed[kPool];
int gCount = 0;
bool gInitDone = false;
inline unsigned long ReadTp() {   // the thread pointer REGISTER (not %fs:0, which Cosmopolitan code reads as its own thread information)
    unsigned long tp;
#if defined(__x86_64__)
    if (gDawnCosmoFsgsbase) {
        __asm__ volatile("rdfsbase %0" : "=r"(tp));
    } else {
        tp = 0; long r; __asm__ volatile("syscall" : "=a"(r) : "0"(158L), "D"(0x1003L), "S"((unsigned long)&tp) : "rcx", "r11", "memory");
    }
#else
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
#endif
    return tp;
}
struct Slot { int idx = -1; unsigned long tcb = 0; ~Slot() { if (idx >= 0) gUsed[idx].store(0); } };
thread_local Slot gSlot;
thread_local bool gChecked = false;
}  // namespace

#include "src/dawn/native/vulkan/DawnCosmoDlopenHelper.h"
#include "src/dawn/native/vulkan/DawnCosmoDlopenHelperMusl.h"
#include <fcntl.h>
#include <sys/stat.h>
extern "C" void DawnCosmoSeedDlopenHelper() {
    static bool done = false;
    if (done) return;
    done = true;
    if (!IsLinux()) return;
    const char* dir = getenv("TMPDIR");
    if (!dir || !*dir) dir = getenv("HOME");
    if (!dir || !*dir) dir = ".";
    char d[4096], exe[4096], src[4096], tmp[4096];
    snprintf(d, sizeof d, "%s/.cosmo", dir); snprintf(exe, sizeof exe, "%s/dlopen-helper", d); snprintf(src, sizeof src, "%s.c", exe);
    struct stat st;
    if (stat(exe, &st) == 0 && stat(src, &st) == 0) return;   // already there (built by Cosmopolitan with cc, or seeded earlier)
    mkdir(d, 0755);
    auto put = [&](const char* path, const unsigned char* data, unsigned long n, int mode) {
        snprintf(tmp, sizeof tmp, "%s.seed%d", path, (int)getpid());
        int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
        if (fd < 0) return false;
        bool ok = write(fd, data, n) == (ssize_t)n;
        ok = (close(fd) == 0) && ok;
        if (!ok || rename(tmp, path) != 0) { unlink(tmp); return false; }
        return true;
    };
    // A musl system has the musl loader and not glibc's: then the helper must be the one linked against musl (its interpreter is what Cosmopolitan loads into the process).
    const bool glibc_loader = IsAarch64() ? access("/lib/ld-linux-aarch64.so.1", F_OK) == 0 : access("/lib64/ld-linux-x86-64.so.2", F_OK) == 0;
    const bool musl_loader = IsAarch64() ? access("/lib/ld-musl-aarch64.so.1", F_OK) == 0 : access("/lib/ld-musl-x86_64.so.1", F_OK) == 0;
    const bool use_musl = musl_loader && !glibc_loader;
    bool a = use_musl ? (IsAarch64() ? put(exe, kDlopenHelperMuslAarch64, kDlopenHelperMuslAarch64Size, 0755) : put(exe, kDlopenHelperMuslX86_64, kDlopenHelperMuslX86_64Size, 0755))
                      : IsAarch64() ? put(exe, kDlopenHelperArm64, kDlopenHelperArm64Size, 0755) : put(exe, kDlopenHelperX64, kDlopenHelperX64Size, 0755);
    bool b = put(src, kDlopenHelperSrc, kDlopenHelperSrcSize, 0600);
    if (getenv("DAWN_COSMO_DIAG")) fprintf(stderr, "dawn-cosmo: seeded the %s dlopen helper in %s (%d %d)\n", use_musl ? "musl" : "glibc", d, (int)a, (int)b);
}

// A Vulkan driver linked into this very file (SwiftShader, built by cosmocc: game/platform and .github/workflows/swiftshader-cosmo.yml) needs no dlopen, no system C library and no libvulkan.
// It is used when DAWN_COSMO_VK=software, or (unset) when no system Vulkan loader can be opened; DAWN_COSMO_VK=system never uses it. The symbols are weak, so a program that does not link the
// driver (link with -Wl,-u,vk_icdGetInstanceProcAddr -Wl,-u,vk_icdNegotiateLoaderICDInterfaceVersion plus the archive to include it) behaves exactly as before.
extern "C" {
__attribute__((weak)) int vk_icdNegotiateLoaderICDInterfaceVersion(unsigned int* version);
__attribute__((weak)) void* vk_icdGetInstanceProcAddr(void* instance, const char* name);
}
namespace {
char gStaticIcdTag;
bool gStaticIcd = false;
enum { kVkAuto, kVkSystem, kVkSoftware };
int VkMode() {
    static int m = [] { const char* e = getenv("DAWN_COSMO_VK"); return !e ? kVkAuto : !strcmp(e, "software") ? kVkSoftware : !strcmp(e, "system") ? kVkSystem : kVkAuto; }();
    return m;
}
bool IcdLinked() { return vk_icdGetInstanceProcAddr != nullptr && vk_icdNegotiateLoaderICDInterfaceVersion != nullptr; }
void* IcdGipa(void* instance, const char* name) {
    static const bool negotiated = [] { unsigned int v = 5; vk_icdNegotiateLoaderICDInterfaceVersion(&v); return true; }();   // 5: without it the driver accepts only Vulkan 1.0 instances (-9)
    (void)negotiated;
    return vk_icdGetInstanceProcAddr(instance, name);
}
void* gVkHandle = nullptr;
void* gVkGipa = nullptr;
}
extern "C" bool DawnCosmoStaticIcd() { return gStaticIcd; }
extern "C" int DawnCosmoDlclose(void* handle) { return handle == &gStaticIcdTag ? 0 : cosmo_dlclose(handle); }
extern "C" void* DawnCosmoDlopen(const char* file, int mode) {
    const bool vk = file && strstr(file, "vulkan");
    if (getenv("DAWN_COSMO_DIAG")) fprintf(stderr, "dawn-cosmo: dlopen(%s) vulkan=%d icd_linked=%d mode=%d\n", file ? file : "(null)", (int)vk, (int)IcdLinked(), VkMode());
    if (vk && IcdLinked() && VkMode() == kVkSoftware) { gStaticIcd = true; return &gStaticIcdTag; }   // nothing foreign is touched: no helper file, no dlopen
    if (!vk || VkMode() != kVkSoftware) DawnCosmoSeedDlopenHelper();
    if (gVkHandle && vk && strstr(file, "libvulkan")) return gVkHandle;
    void* h = cosmo_dlopen(file, mode);
    if (!h && vk && IcdLinked() && VkMode() == kVkAuto) { gStaticIcd = true; return &gStaticIcdTag; }   // no system Vulkan loader (or no glibc at all): the driver inside this file
    return h;
}
extern "C" void* DawnCosmoDlsym(void* handle, const char* name) {
    if (handle == &gStaticIcdTag) return !strcmp(name, "vkGetInstanceProcAddr") ? reinterpret_cast<void*>(&IcdGipa) : nullptr;
    if (handle && handle == gVkHandle && gVkGipa && !strcmp(name, "vkGetInstanceProcAddr")) return gVkGipa;
    return cosmo_dlsym(handle, name);
}
extern "C" void DawnCosmoForeignInit() {
    if (gInitDone) return;
    gInitDone = true;
    if (!IsLinux()) return;
    if (IcdLinked() && VkMode() == kVkSoftware) return;   // glibc-free mode: no helper, no libvulkan, no parked threads, nothing from the system C library
    DawnCosmoSeedDlopenHelper();
    if (gettid() != getpid()) { if (getenv("DAWN_COSMO_DIAG")) fprintf(stderr, "dawn-cosmo: DawnCosmoForeignInit was not called on the main thread; threads cannot call the driver\n"); return; }   // only the main thread has the library's own thread block to ask for pthread_self and to call pthread_create with
#if defined(__x86_64__)
    gDawnCosmoFsgsbase = (getauxval(AT_HWCAP2) & 2) ? 1 : 0;   // HWCAP2_FSGSBASE
#endif
    for (const char* n : {"libvulkan.so.1", "libvulkan.so"}) { void* v = cosmo_dlopen(n, RTLD_NOW); if (v) { gVkHandle = v; gVkGipa = cosmo_dlsym(v, "vkGetInstanceProcAddr"); break; } }   // on the main thread, for Dawn's loader code on other threads
    void* libc = cosmo_dlopen("libc.so.6", RTLD_NOW);
    if (!libc) return;
    auto pcreate = reinterpret_cast<int (*)(unsigned long*, const void*, void* (*)(void*), void*)>(cosmo_dltramp(cosmo_dlsym(libc, "pthread_create")));
    auto pself = reinterpret_cast<unsigned long (*)()>(cosmo_dltramp(cosmo_dlsym(libc, "pthread_self")));
    void* pauseFn = cosmo_dlsym(libc, "pause");   // runs inside the library only; called directly, not through a thunk
    if (!pcreate || !pself || !pauseFn) return;
    int poolN = kPool; if (const char* pe = getenv("DAWN_COSMO_POOL")) { poolN = atoi(pe); if (poolN < 0) poolN = 0; if (poolN > kPool) poolN = kPool; }   // diagnostic: how many parked blocks to make (0 = none: a thread other than the main one cannot then call the driver)
    sigset_t all, old; sigfillset(&all); pthread_sigmask(SIG_SETMASK, &all, &old);
#if defined(__x86_64__)
    // pthread_self() of the library is the thread pointer on x86-64
    for (int i = 0; i < poolN; i++) {
        unsigned long t = 0;
        if (pcreate(&t, nullptr, reinterpret_cast<void* (*)(void*)>(pauseFn), nullptr)) break;
        gPool[gCount++] = t;
    }
    unsigned long off = 0; (void)pself;
#else
    // arm64: the thread pointer is not pthread_self() and Cosmopolitan code cannot read the library's value, so each parked thread runs a few instructions that publish its own thread pointer and then
    // block in ppoll() for good:   mrs x1, tpidr_el0 ; str x1, [x0] ; loop: mov x8, #73 ; mov x0, #0 ; mov x1, #0 ; mov x2, #0 ; mov x3, #0 ; svc #0 ; b loop
    static const unsigned int code[] = {0xd53bd041, 0xf9000001, 0xd2800928, 0xd2800000, 0xd2800001, 0xd2800002, 0xd2800003, 0xd4000001, 0x17fffffa};
    unsigned int* page = static_cast<unsigned int*>(mmap(nullptr, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    unsigned long off = 0; (void)pself; (void)pauseFn;
    if (page != MAP_FAILED) {
        memcpy(page, code, sizeof code); __builtin___clear_cache(reinterpret_cast<char*>(page), reinterpret_cast<char*>(page) + sizeof code);
        static unsigned long published[kPool];
        for (int i = 0; i < poolN; i++) {
            published[i] = 0; unsigned long t = 0;
            if (pcreate(&t, nullptr, reinterpret_cast<void* (*)(void*)>(page), &published[i])) break;
            for (int k = 0; k < 5000 && !*reinterpret_cast<volatile unsigned long*>(&published[i]); k++) { struct timespec z = {0, 200000}; nanosleep(&z, nullptr); }
            if (!published[i]) break;
            gPool[gCount++] = published[i];
        }
    }
#endif
    pthread_sigmask(SIG_SETMASK, &old, nullptr);
    if (getenv("DAWN_COSMO_DIAG")) fprintf(stderr, "dawn-cosmo: %d parked thread blocks (fsgsbase %d), main thread pointer %#lx, offset %#lx, first block %#lx\n", gCount, gDawnCosmoFsgsbase, ReadTp(), off, gCount ? gPool[0] : 0UL);
}
// Pre-populate the system C library's heap (the driver's malloc); call it on the main thread right BEFORE the burst of resource creation it is meant for (measured: warming at device creation helps nothing when pipelines are compiled afterwards, the driver's compiler churns the heap). Linux only, a no-op elsewhere or without the system C library.
extern "C" void DawnCosmoWarmDriverHeapKB(long kb);
extern "C" void DawnCosmoWarmDriverHeap() { DawnCosmoWarmDriverHeapKB(-1); }
extern "C" void DawnCosmoWarmDriverHeapKB(long kb_arg) {
    if (!IsLinux() || DawnCosmoStaticIcd()) return;
    void* libc = cosmo_dlopen("libc.so.6", RTLD_NOW);
    if (!libc || !cosmo_dlsym(libc, "gnu_get_libc_version")) return;   // glibc only: its brk heap is what grows during the first burst; musl's allocator works differently (and crashed here on arm64 in the first try)
    // Pre-populate the system C library's heap (the driver's malloc). Natively Dawn and the driver share that heap, so the driver reuses pages that Dawn and Tint touched during start-up (every process pays for
    // those pages once, natively at start-up). In this build Dawn's frees go to this file's malloc, so the driver's heap starts nearly empty and the first burst of buffer creation grows it by about 2.6 MB:
    // about 700 page faults, 1.5-2.5 ms in the middle of a frame. Paying for the pages at start-up instead is what native Dawn does. Take 3 MiB from the library's heap in 64 KiB blocks (below its mmap
    // threshold), have the kernel populate them in one call each (MADV_POPULATE_WRITE, Linux 5.14; a write per page on older kernels), free them and tell the library not to give them back
    // (M_TRIM_THRESHOLD 64 MiB). Measured (game host, system lavapipe through this helper, 21 interleaved rounds, Linux x86-64): first burst of 4,000 buffers 8.03 -> 5.52 ms median, page faults 936 -> 261
    // (native Dawn: about 240), the population itself 1.5 ms once at start-up, so the total is lower too. DAWN_COSMO_PREFAULT_KB=<KiB> changes the size, 0 turns it off. (A first version used calloc, which does not write fresh heap memory,
    // so it pre-faulted nothing; the conclusion drawn from that run, "pre-faulting has no effect", was wrong.)
    {
        long kb = kb_arg >= 0 ? kb_arg : 3072; if (const char* pk = getenv("DAWN_COSMO_PREFAULT_KB")) kb = atol(pk);
        long mmapmb = 0; if (const char* pm = getenv("DAWN_COSMO_MMAP_THRESHOLD_MB")) mmapmb = atol(pm);   // glibc's mmap threshold: measured no effect on the first-loop page faults (0.171 vs 0.173 per call), so off
        auto pmallopt = reinterpret_cast<int (*)(int, int)>(cosmo_dltramp(cosmo_dlsym(libc, "mallopt")));
        auto pmalloc = reinterpret_cast<void* (*)(unsigned long)>(cosmo_dltramp(cosmo_dlsym(libc, "malloc")));
        auto pfree = reinterpret_cast<void (*)(void*)>(cosmo_dltramp(cosmo_dlsym(libc, "free")));
        if (mmapmb > 0 && pmallopt) { pmallopt(-3, (int)(mmapmb << 20)); pmallopt(-1, (int)(mmapmb << 21)); }   // M_MMAP_THRESHOLD, M_TRIM_THRESHOLD
        if (kb > 0 && pmallopt && pmalloc && pfree) {
            pmallopt(-1, 64 << 20);   // M_TRIM_THRESHOLD: keep freed heap memory
            const long n = (kb + 63) / 64; void** blocks = static_cast<void**>(malloc(sizeof(void*) * n)); long got = 0;
            if (blocks) {
                for (long i = 0; i < n; i++) {
                    void* b = pmalloc(65536 - 32); if (!b) break; blocks[got++] = b;
                    uintptr_t lo = ((uintptr_t)b + 4095) & ~(uintptr_t)4095, hi = ((uintptr_t)b + 65536 - 32) & ~(uintptr_t)4095;
                    if (madvise((void*)lo, hi - lo, 23 /* MADV_POPULATE_WRITE */) != 0) for (uintptr_t a = lo; a < hi; a += 4096) *(volatile char*)a = 0;
                }
                for (long i = 0; i < got; i++) pfree(blocks[i]);
                free(blocks);
            }
        }
    }
}
extern "C" unsigned long DawnCosmoForeignTcb() {
    if (gChecked) return gSlot.tcb;
    gChecked = true;
    if (!gInitDone || gCount == 0 || gettid() == getpid()) return 0;
    for (int i = 0; i < gCount; i++) {
        int zero = 0;
        if (gUsed[i].compare_exchange_strong(zero, 1)) {
            gSlot.idx = i; gSlot.tcb = gPool[i];
            if (getenv("DAWN_COSMO_DIAG")) fprintf(stderr, "dawn-cosmo: thread %d takes parked block %d (thread pointer %#lx), own thread pointer %#lx\n", (int)gettid(), i, gSlot.tcb, ReadTp());
            sigset_t m; sigfillset(&m); sigdelset(&m, SIGSEGV); sigdelset(&m, SIGBUS); sigdelset(&m, SIGFPE); sigdelset(&m, SIGILL); sigdelset(&m, SIGTRAP);
            pthread_sigmask(SIG_BLOCK, &m, nullptr);   // see the header comment: no Cosmopolitan signal handler while the library's thread pointer is in place
            return gSlot.tcb;
        }
    }
    fprintf(stderr, "dawn-cosmo: more threads call the driver than the %d parked thread blocks\n", gCount); abort();
}

#endif

