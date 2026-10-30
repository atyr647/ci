/* Parallel kernel with pthreads, ONE source for: wasm32-wasip1-threads (run by the static Wasmtime, threads created by the host through wasi:thread-spawn) and native code (gcc/clang/cosmocc).
 * usage: par <threads> [scale|sync|waitnotify|trapthread]
 *   scale       integer-only work split in chunks taken from an atomic counter; prints "KERNEL par<N> <ms> <checksum>" (checksum must not depend on <N>)
 *   sync        mutex + condition variable (futex wait/notify in wasm): counter and ping-pong; prints "SYNC ..." and a verdict
 *   waitnotify  (wasm only) memory.atomic.wait32 result codes, timeout, notify wake-up
 *   trapthread  (wasm only) a spawned thread traps (out-of-bounds); the main thread must stay alive and continue */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHUNKS 128
#define ITERS 2000000u

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static uint64_t chunk(uint32_t id) {   /* integer only, depends on id alone, so the sum is the same for every thread count and every platform */
    uint32_t t[256]; uint64_t x = 0x9E3779B97F4A7C15ull * (id + 1), acc = 0;
    for (int i = 0; i < 256; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; t[i] = (uint32_t)x; }
    for (uint32_t i = 0; i < ITERS; i++) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        uint32_t k = (uint32_t)x & 255; t[k] = t[k] * 2654435761u + (uint32_t)(x >> 32); acc += t[k] ^ (acc >> 11);
    }
    return acc;
}
static atomic_uint next_chunk; static atomic_ullong total;
static void *scale_worker(void *arg) {
    (void)arg;
    for (;;) { uint32_t c = atomic_fetch_add(&next_chunk, 1); if (c >= CHUNKS) break; atomic_fetch_add(&total, chunk(c)); }
    return NULL;
}
static int run_scale(int nt) {
    pthread_t th[64]; if (nt > 64) nt = 64;
    atomic_store(&next_chunk, 0); atomic_store(&total, 0);
    double t0 = now_ms();
    for (int i = 0; i < nt; i++) if (pthread_create(&th[i], NULL, scale_worker, NULL)) { printf("pthread_create failed at %d\n", i); return 1; }
    for (int i = 0; i < nt; i++) pthread_join(th[i], NULL);
    double ms = now_ms() - t0;
    printf("KERNEL par%d %.3f %llu\n", nt, ms, (unsigned long long)atomic_load(&total));
    return 0;
}

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static long counter; static int turn;   /* turn: whose move in the ping-pong */
#define INCS 50000
#define ROUNDS 5000
static void *sync_worker(void *arg) {
    long id = (long)arg;
    for (int i = 0; i < INCS; i++) { pthread_mutex_lock(&mu); counter++; pthread_mutex_unlock(&mu); }
    if (id < 2) {   /* ping-pong between threads 0 and 1 through a condition variable */
        for (int r = 0; r < ROUNDS; r++) {
            pthread_mutex_lock(&mu);
            while (turn != id) pthread_cond_wait(&cv, &mu);
            turn = 1 - (int)id; pthread_cond_broadcast(&cv);
            pthread_mutex_unlock(&mu);
        }
    }
    return NULL;
}
static int run_sync(int nt) {
    if (nt < 2) nt = 2;
    pthread_t th[64]; if (nt > 64) nt = 64;
    counter = 0; turn = 0; double t0 = now_ms();
    for (long i = 0; i < nt; i++) pthread_create(&th[i], NULL, sync_worker, (void *)i);
    for (int i = 0; i < nt; i++) pthread_join(th[i], NULL);
    int okc = counter == (long)nt * INCS, okt = turn == 0;
    printf("SYNC threads=%d counter=%ld (expected %ld) turn=%d ms=%.1f -> %s\n", nt, counter, (long)nt * INCS, turn, now_ms() - t0, okc && okt ? "PASS" : "FAIL");
    return !(okc && okt);
}

#ifdef __wasm__
static int flag;   /* word in shared memory */
static void *setter(void *arg) { (void)arg; for (volatile int i = 0; i < 3000000; i++) {} __atomic_store_n(&flag, 1, __ATOMIC_SEQ_CST); int woken = __builtin_wasm_memory_atomic_notify(&flag, 1); (void)woken; return NULL; }
static int run_waitnotify(void) {
    int bad = 0;
    int r1 = __builtin_wasm_memory_atomic_wait32(&flag, 5, -1);           /* value differs: 1 immediately */
    double t0 = now_ms();
    int r2 = __builtin_wasm_memory_atomic_wait32(&flag, 0, 20 * 1000000LL); /* nobody notifies: 2 after >= 20 ms */
    double dt = now_ms() - t0;
    int n0 = __builtin_wasm_memory_atomic_notify(&flag, 10);               /* nobody waits: 0 */
    printf("WAITNOTIFY mismatch=%d (want 1) timeout=%d after %.1f ms (want 2, >=20) notify-none=%d (want 0)\n", r1, r2, dt, n0);
    bad |= r1 != 1 || r2 != 2 || dt < 19.0 || n0 != 0;
    pthread_t th; pthread_create(&th, NULL, setter, NULL);
    t0 = now_ms(); int r3 = __builtin_wasm_memory_atomic_wait32(&flag, 0, -1); dt = now_ms() - t0;   /* blocked until the other thread stores 1 and notifies: 0 (or 1 if it was faster) */
    pthread_join(th, NULL);
    printf("WAITNOTIFY blocked wait result=%d (want 0 or 1) flag=%d (want 1) after %.1f ms\n", r3, flag, dt);
    bad |= (r3 != 0 && r3 != 1) || flag != 1;
    printf("WAITNOTIFY -> %s\n", bad ? "FAIL" : "PASS");
    return bad;
}
static int tflag;
static void *trapper(void *arg) { (void)arg; __atomic_store_n(&tflag, 1, __ATOMIC_SEQ_CST); __builtin_wasm_memory_atomic_notify(&tflag, 1); *(volatile int *)0xFFFFFFF0u = 1; return NULL; }
static int run_trapthread(void) {
    pthread_t th; pthread_create(&th, NULL, trapper, NULL);   /* never joined: a trapped thread cannot finish */
    while (__atomic_load_n(&tflag, __ATOMIC_SEQ_CST) == 0) __builtin_wasm_memory_atomic_wait32(&tflag, 0, 10 * 1000000LL);
    int tmp = 0; __builtin_wasm_memory_atomic_wait32(&tmp, 0, 100 * 1000000LL);   /* give it time to trap */
    printf("TRAPTHREAD main thread alive after the spawned thread trapped -> PASS\n");
    return 0;
}
#endif

int main(int argc, char **argv) {
    int nt = argc > 1 ? atoi(argv[1]) : 1; const char *mode = argc > 2 ? argv[2] : "scale";
    if (nt < 1) nt = 1;
    if (!strcmp(mode, "scale")) return run_scale(nt);
    if (!strcmp(mode, "sync")) return run_sync(nt);
#ifdef __wasm__
    if (!strcmp(mode, "waitnotify")) return run_waitnotify();
    if (!strcmp(mode, "trapthread")) return run_trapthread();
#endif
    printf("unknown mode %s\n", mode); return 2;
}
