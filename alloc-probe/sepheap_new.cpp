// Experiment: Dawn's operator new/delete come from a private heap that is separate from the C library's malloc heap (which the Vulkan driver uses), like in the Cosmopolitan build,
// where Dawn allocates from Cosmopolitan's heap and the driver from the system C library's. Size classes of 16 bytes up to 4 KiB with per-thread free lists, carved from 1 MiB mmap chunks that are
// never returned; larger blocks go to malloc. Used only to test whether separate heaps cost page faults and time (native build + this file = "native-sepheap").
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <new>
#include <sys/mman.h>

namespace {
struct Node { Node *next; };
constexpr size_t kClasses = 256, kHdr = 16;
thread_local Node *tl_free[kClasses + 1];
thread_local char *tl_cur; thread_local size_t tl_left;
void *carve(size_t total) {
    if (tl_left < total) {
        const size_t chunk = 1u << 20;
        void *p = mmap(nullptr, chunk, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) return nullptr;
        tl_cur = static_cast<char *>(p); tl_left = chunk;
    }
    void *r = tl_cur; tl_cur += total; tl_left -= total; return r;
}
void *alloc(size_t n) {
    size_t cls = (n + 15) / 16; if (!cls) cls = 1;
    if (cls <= kClasses) {
        if (Node *f = tl_free[cls]) { tl_free[cls] = f->next; return f; }
        char *b = static_cast<char *>(carve(cls * 16 + kHdr)); if (!b) return nullptr;
        *reinterpret_cast<size_t *>(b) = cls; return b + kHdr;
    }
    char *b = static_cast<char *>(malloc(n + kHdr)); if (!b) return nullptr;
    *reinterpret_cast<size_t *>(b) = 0; return b + kHdr;
}
void release(void *p) {
    if (!p) return;
    char *b = static_cast<char *>(p) - kHdr; size_t cls = *reinterpret_cast<size_t *>(b);
    if (!cls) { free(b); return; }
    Node *nd = static_cast<Node *>(p); nd->next = tl_free[cls]; tl_free[cls] = nd;
}
}
void *operator new(size_t n) { void *p = alloc(n); if (!p) throw std::bad_alloc(); return p; }
void *operator new[](size_t n) { void *p = alloc(n); if (!p) throw std::bad_alloc(); return p; }
void *operator new(size_t n, const std::nothrow_t &) noexcept { return alloc(n); }
void *operator new[](size_t n, const std::nothrow_t &) noexcept { return alloc(n); }
void operator delete(void *p) noexcept { release(p); }
void operator delete[](void *p) noexcept { release(p); }
void operator delete(void *p, size_t) noexcept { release(p); }
void operator delete[](void *p, size_t) noexcept { release(p); }
void operator delete(void *p, const std::nothrow_t &) noexcept { release(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { release(p); }
void *operator new(size_t n, std::align_val_t a) { void *p = nullptr; if (posix_memalign(&p, static_cast<size_t>(a) < sizeof(void *) ? sizeof(void *) : static_cast<size_t>(a), n)) throw std::bad_alloc(); return p; }
void *operator new[](size_t n, std::align_val_t a) { return operator new(n, a); }
void operator delete(void *p, std::align_val_t) noexcept { free(p); }
void operator delete[](void *p, std::align_val_t) noexcept { free(p); }
void operator delete(void *p, size_t, std::align_val_t) noexcept { free(p); }
void operator delete[](void *p, size_t, std::align_val_t) noexcept { free(p); }
