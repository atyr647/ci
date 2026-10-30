/* Do wasm threads work, and do they scale? N worker threads each run the same fixed amount of floating-point work; wall time should drop with N.
 * Built for wasm32-wasip1-threads (shared memory + atomics + wasi-threads) and natively. usage: threads <nthreads> */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <time.h>
#include <math.h>
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
#define TOTAL (1 << 26)
static volatile uint64_t shared_counter;
static double partial[64];
typedef struct { int id, n; } arg_t;
static void *work(void *p) {
  arg_t *a = p; double s = 0; long begin = (long)((long long)TOTAL * a->id / a->n), end = (long)((long long)TOTAL * (a->id + 1) / a->n);
  for (long i = begin; i < end; i++) s += sqrt((double)i + 1.0) * 1e-6;
  partial[a->id] = s; __atomic_fetch_add(&shared_counter, (uint64_t)(end - begin), __ATOMIC_SEQ_CST); return 0;
}
int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 1; if (n < 1 || n > 64) n = 1;
  pthread_t th[64]; arg_t args[64]; double t0 = now_ms();
  for (int i = 0; i < n; i++) { args[i].id = i; args[i].n = n; if (pthread_create(&th[i], 0, work, &args[i])) { puts("pthread_create failed"); return 1; } }
  for (int i = 0; i < n; i++) pthread_join(th[i], 0);
  double sum = 0; for (int i = 0; i < n; i++) sum += partial[i];
  printf("threads=%d time=%.0f ms counter=%llu sum=%.4f\n", n, now_ms() - t0, (unsigned long long)shared_counter, sum);
  return shared_counter == TOTAL ? 0 : 2;
}
