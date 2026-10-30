// Why is allocation / locking 3-4x slower in the Cosmopolitan build of Dawn? Micro-benchmarks of the pieces, in the same process:
//   malloc/free and operator new/delete (whatever this binary links), mimalloc's mi_malloc/mi_free if linked in (-DHAVE_MIMALLOC), std::mutex, a plain pthread mutex,
//   a minimal futex-less test-and-set lock, and the same allocation loop on 4 threads. Prints "PROBE <name> <ns per op>".
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <pthread.h>
#include <thread>
#include <vector>
#ifdef HAVE_MIMALLOC
#include "mimalloc.h"
#endif
using Clock = std::chrono::steady_clock;
static double since(Clock::time_point t) { return std::chrono::duration<double, std::nano>(Clock::now() - t).count(); }
static void report(const char *name, double ns, long n) { printf("PROBE %-34s %8.2f ns/op\n", name, ns / n); fflush(stdout); }
template <class F> static double best_of(F f, long n) { double best = 1e30; for (int r = 0; r < 5; r++) { auto t = Clock::now(); f(n); double x = since(t); if (x < best) best = x; } return best; }
static void *volatile g_sink;
struct SpinLock { std::atomic<int> f{0}; void lock() { while (f.exchange(1, std::memory_order_acquire)) { } } void unlock() { f.store(0, std::memory_order_release); } };

template <class Alloc, class Free> static void alloc_loop(long n, Alloc a, Free fr) {   // the pattern of Dawn's ref-counted objects: a small ring of live blocks of mixed sizes
    void *ring[64] = {}; 
    for (long i = 0; i < n; i++) { void *&p = ring[i & 63]; if (p) fr(p); p = a(48 + (i & 63) * 3); }
    for (void *p : ring) if (p) fr(p);
}
int main() {
    const long N = 4000000;
    report("malloc/free", best_of([&](long n) { alloc_loop(n, [](size_t s) { return malloc(s); }, [](void *p) { free(p); }); }, N), N);
    report("operator new/delete", best_of([&](long n) { alloc_loop(n, [](size_t s) { return ::operator new(s); }, [](void *p) { ::operator delete(p); }); }, N), N);
#ifdef HAVE_MIMALLOC
    report("mi_malloc/mi_free", best_of([&](long n) { alloc_loop(n, [](size_t s) { return mi_malloc(s); }, [](void *p) { mi_free(p); }); }, N), N);
#endif
    { std::mutex m; volatile long x = 0; const long M = 20000000;
      report("std::mutex lock+unlock", best_of([&](long n) { for (long i = 0; i < n; i++) { m.lock(); x = x + 1; m.unlock(); } }, M), M); }
    { pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER; volatile long x = 0; const long M = 20000000;
      report("pthread_mutex_t normal", best_of([&](long n) { for (long i = 0; i < n; i++) { pthread_mutex_lock(&m); x = x + 1; pthread_mutex_unlock(&m); } }, M), M); }
    { SpinLock m; volatile long x = 0; const long M = 20000000;
      report("test-and-set lock (reference)", best_of([&](long n) { for (long i = 0; i < n; i++) { m.lock(); x = x + 1; m.unlock(); } }, M), M); }
    { const long per = 1000000; double best = 1e30;
      for (int r = 0; r < 3; r++) { auto t = Clock::now(); std::vector<std::thread> th; for (int k = 0; k < 4; k++) th.emplace_back([&] { alloc_loop(per, [](size_t s) { return malloc(s); }, [](void *p) { free(p); }); }); for (auto &x : th) x.join(); double x = since(t); if (x < best) best = x; }
      report("malloc/free, 4 threads (per op, wall/4)", best, per * 4 / 4 * 1); }
    { const long per = 1000000; double best = 1e30;
      for (int r = 0; r < 3; r++) { auto t = Clock::now(); std::vector<std::thread> th; for (int k = 0; k < 4; k++) th.emplace_back([&] { alloc_loop(per, [](size_t s) { return ::operator new(s); }, [](void *p) { ::operator delete(p); }); }); for (auto &x : th) x.join(); double x = since(t); if (x < best) best = x; }
      report("operator new/delete, 4 threads", best, per); }
#ifdef HAVE_MIMALLOC
    { const long per = 1000000; double best = 1e30;
      for (int r = 0; r < 3; r++) { auto t = Clock::now(); std::vector<std::thread> th; for (int k = 0; k < 4; k++) th.emplace_back([&] { alloc_loop(per, [](size_t s) { return mi_malloc(s); }, [](void *p) { mi_free(p); }); }); for (auto &x : th) x.join(); double x = since(t); if (x < best) best = x; }
      report("mi_malloc/mi_free, 4 threads", best, per); }
#endif
    return g_sink != nullptr;
}
