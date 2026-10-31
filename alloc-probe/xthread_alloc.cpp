// Cross-thread allocate/free stress: every block is allocated by one thread, handed to another through an atomic slot, checked there and freed there.
// Detects a race in the allocator (corrupted chunk headers, double handout) without involving Dawn or a driver. exit 0 = no corruption seen.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
static std::atomic<void *> slots[256];
static std::atomic<long> bad{0}, ops{0};
static void worker(int id, double seconds) {
    uint64_t x = 0x9E3779B97F4A7C15ull * (id + 1); auto t0 = std::chrono::steady_clock::now();
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < seconds) {
        for (int k = 0; k < 2000; k++) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17;
            size_t sz = 16 + (x % (k % 50 == 0 ? 70000 : 600));   // mostly small, now and then larger than the small-block range
            uint8_t *p = (uint8_t *)malloc(sz); if (!p) { bad++; continue; }
            uint64_t tag = (uint64_t)(uintptr_t)p * 0x100000001B3ull ^ sz; memcpy(p, &tag, 8); if (sz >= 16) memcpy(p + sz - 8, &tag, 8);
            void *q = slots[(x >> 20) & 255].exchange(p);
            if (q) {
                uint8_t *r = (uint8_t *)q; size_t rs = 0; (void)rs;
                // the block's size is not stored, so only the first word is checked: it must equal the tag computed from the block's own address (low bits of the size are unknown) -> compare modulo the size by recomputing for the possible tag
                uint64_t got; memcpy(&got, r, 8); uint64_t base = (uint64_t)(uintptr_t)r * 0x100000001B3ull;
                if (((got ^ base) >= 70016)) bad++;   // sz <= 70015 for every block
                free(r);
            }
            ops++;
        }
    }
}
int main(int argc, char **argv) {
    int nt = argc > 1 ? atoi(argv[1]) : 6; double sec = argc > 2 ? atof(argv[2]) : 4.0; std::vector<std::thread> th;
    for (int i = 0; i < nt; i++) th.emplace_back(worker, i, sec);
    for (auto &t : th) t.join();
    for (auto &s : slots) { void *q = s.exchange(nullptr); free(q); }
    printf("RESULT xthread_alloc threads=%d operations=%ld corrupted=%ld\n", nt, (long)ops, (long)bad); return bad ? 1 : 0;
}
