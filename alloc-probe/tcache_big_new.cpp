// EXPERIMENT (tcache_big_new.cpp): tcache_new.cpp plus retention of larger blocks (4 KiB to 8 MiB, power-of-two classes, kBigKeep blocks per class per thread), to test whether
// Cosmopolitan's malloc returning large freed blocks to the kernel (and the page faults of getting them back) is what makes Tint-heavy work slower than natively.
// Replacement for the global operator new/delete: a lock-free per-thread cache of small blocks in front of malloc/free.
// Why: in the Cosmopolitan C library every malloc/free takes a global lock (about 40 ns per pair single-threaded, 400+ ns with four threads); Dawn allocates and frees
// small reference-counted objects all the time. Blocks of up to kMax bytes are kept in per-thread free lists by 16-byte size class; everything else, and overflow,
// goes to malloc/free. A 16-byte header holds the size class so delete does not need the size. Memory a thread keeps in its lists is bounded by kKeep blocks per class.
#include <cstdint>
#include <cstdlib>
#include <new>
namespace {
constexpr size_t kMax = 1024, kClasses = kMax / 16 + 1, kKeep = 128, kLarge = ~size_t(0);
constexpr size_t kBigMin = 4096, kBigMaxLog = 23, kBigKeep = 6;   // classes 2^12 .. 2^23
constexpr size_t kBigBase = 1000;   // header values kBigBase + log2 mark a big class
thread_local void *g_big[kBigMaxLog + 1]; thread_local unsigned g_bigcount[kBigMaxLog + 1];
struct Block { Block *next; };
thread_local Block *g_head[kClasses];
thread_local unsigned g_count[kClasses];
inline void *alloc(size_t n) {
    if (n == 0) n = 1;
    if (n <= kMax) {
        size_t c = (n + 15) / 16;
        if (Block *b = g_head[c]) { g_head[c] = b->next; g_count[c]--; return b; }
        void *base = malloc(c * 16 + 16);
        if (!base) return nullptr;
        *(size_t *)base = c;
        return (char *)base + 16;
    }
    if (n >= kBigMin && n <= (size_t(1) << kBigMaxLog)) {
        unsigned lg = 12; while ((size_t(1) << lg) < n) lg++;
        if (void *b = g_big[lg]) { g_big[lg] = *(void **)b; g_bigcount[lg]--; return b; }
        void *base = malloc((size_t(1) << lg) + 16);
        if (!base) return nullptr;
        *(size_t *)base = kBigBase + lg;
        return (char *)base + 16;
    }
    void *base = malloc(n + 16);
    if (!base) return nullptr;
    *(size_t *)base = kLarge;
    return (char *)base + 16;
}
inline void release(void *p) {
    if (!p) return;
    void *base = (char *)p - 16;
    size_t c = *(size_t *)base;
    if (c >= kBigBase && c != kLarge) { unsigned lg = (unsigned)(c - kBigBase); if (g_bigcount[lg] < kBigKeep) { *(void **)p = g_big[lg]; g_big[lg] = p; g_bigcount[lg]++; return; } free(base); return; }
    if (c != kLarge && g_count[c] < kKeep) { Block *b = (Block *)p; b->next = g_head[c]; g_head[c] = b; g_count[c]++; return; }
    free(base);
}
}  // namespace
void *operator new(size_t n) { void *p = alloc(n); if (!p) abort(); return p; }
void *operator new[](size_t n) { void *p = alloc(n); if (!p) abort(); return p; }
void *operator new(size_t n, const std::nothrow_t &) noexcept { return alloc(n); }
void *operator new[](size_t n, const std::nothrow_t &) noexcept { return alloc(n); }
void operator delete(void *p) noexcept { release(p); }
void operator delete[](void *p) noexcept { release(p); }
void operator delete(void *p, size_t) noexcept { release(p); }
void operator delete[](void *p, size_t) noexcept { release(p); }
void operator delete(void *p, const std::nothrow_t &) noexcept { release(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { release(p); }
