// Correctness and speed test for a replacement malloc: threads allocate blocks of random sizes, fill them with a pattern, hand them to another thread that verifies and frees them,
// realloc grows/shrinks with content checks, calloc returns zeroes, aligned allocations are aligned, a big block works, and Tint-like churn (many small blocks freed together) is timed.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
using namespace std::chrono;
static std::atomic<int> fails{0};
#define CHECK(c, what) do { if (!(c)) { printf("FAIL %s\n", what); fails++; } } while (0)
struct Item { unsigned char *p; size_t n; unsigned char tag; };
static std::mutex qm; static std::vector<Item> q; static std::atomic<bool> done{false};
static uint64_t rng(uint64_t &s) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static void producer(int id) {
    uint64_t s = 88172645463325252ull + id * 7919;
    for (int i = 0; i < 200000; i++) {
        size_t n = 1 + rng(s) % (rng(s) % 16 == 0 ? 70000 : 600); unsigned char tag = (unsigned char)(rng(s) | 1);
        unsigned char *p = (unsigned char *)malloc(n); CHECK(p, "malloc returned null"); if (!p) return;
        CHECK(((uintptr_t)p & 15) == 0, "16-byte alignment"); memset(p, tag, n);
        if (rng(s) % 3 == 0) { size_t n2 = 1 + rng(s) % 2000; unsigned char *r = (unsigned char *)realloc(p, n2); CHECK(r, "realloc null"); if (!r) return; size_t m = n < n2 ? n : n2; for (size_t k = 0; k < m; k++) if (r[k] != tag) { CHECK(false, "realloc kept content"); break; } memset(r, tag, n2); p = r; n = n2; }
        std::lock_guard<std::mutex> g(qm); q.push_back({p, n, tag});
    }
}
static void consumer() {
    for (;;) {
        Item it; { std::lock_guard<std::mutex> g(qm); if (q.empty()) { if (done) return; continue; } it = q.back(); q.pop_back(); }
        for (size_t k = 0; k < it.n; k++) if (it.p[k] != it.tag) { CHECK(false, "content changed between threads"); break; }
        free(it.p);
    }
}
int main() {
    { std::vector<std::thread> t; for (int i = 0; i < 4; i++) t.emplace_back(producer, i); for (int i = 0; i < 3; i++) t.emplace_back(consumer); for (int i = 0; i < 4; i++) t[i].join(); done = true; for (size_t i = 4; i < t.size(); i++) t[i].join(); }
    printf("OK   cross-thread produce/consume\n");
    { unsigned char *z = (unsigned char *)calloc(1000, 17); bool ok = z; for (int i = 0; ok && i < 17000; i++) ok = z[i] == 0; CHECK(ok, "calloc zero"); free(z); }
    for (size_t al : {16, 64, 256, 4096, 65536}) { void *p = nullptr; int rc = posix_memalign(&p, al, 1000); CHECK(rc == 0 && ((uintptr_t)p % al) == 0, "posix_memalign alignment"); free(p); void *a = aligned_alloc(al, al * 2); CHECK(a && ((uintptr_t)a % al) == 0, "aligned_alloc alignment"); free(a); }
    { size_t big = 256u << 20; unsigned char *b = (unsigned char *)malloc(big); CHECK(b, "256 MiB malloc"); if (b) { b[0] = 1; b[big - 1] = 2; CHECK(b[0] == 1 && b[big - 1] == 2, "256 MiB block usable"); free(b); } }
    { void *p = malloc(0); free(p); free(nullptr); void *r = realloc(nullptr, 100); CHECK(r, "realloc(null)"); free(r); }
    printf("OK   calloc / aligned / big / edge cases\n");
    // Tint-like churn: allocate 200,000 small and medium blocks of mixed sizes, then free them all, repeated
    { auto t0 = steady_clock::now(); uint64_t s = 1234567; std::vector<void *> v; v.reserve(200000);
      for (int round = 0; round < 20; round++) { for (int i = 0; i < 200000; i++) v.push_back(malloc(16 + rng(s) % (i % 10 == 0 ? 3000 : 200))); for (void *p : v) free(p); v.clear(); }
      printf("TIME churn 20 x 200000 blocks: %.1f ms\n", duration<double, std::milli>(steady_clock::now() - t0).count()); }
    { auto t0 = steady_clock::now(); std::vector<std::thread> t; for (int i = 0; i < 4; i++) t.emplace_back([] { uint64_t s = 99; for (int i = 0; i < 2000000; i++) { void *p = malloc(32 + rng(s) % 400); free(p); } }); for (auto &x : t) x.join();
      printf("TIME 4 threads x 2,000,000 malloc/free pairs: %.1f ms\n", duration<double, std::milli>(steady_clock::now() - t0).count()); }
    printf("RESULT %s\n", fails ? "FAIL" : "PASS"); return fails ? 1 : 0;
}
