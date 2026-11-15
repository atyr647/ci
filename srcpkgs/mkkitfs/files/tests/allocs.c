/* allocs.c -- LD_PRELOAD shim for the allocation test (tests/run.sh): counts the allocations made
 * on behalf of each library of the server, by the first caller outside libc, libstdc++, libgcc and
 * this shim.  When $ALLOCS_OUT.go appears it writes "<object> <count>" lines to $ALLOCS_OUT, resets
 * the counts and removes the .go file (a thread of its own looks every 50 ms).  With $ALLOCS_TOTAL
 * set it only counts them all ("total"), without walking the stack for each one.
 * Built with: cc -shared -fPIC -O1 -o allocs.so allocs.c -ldl */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

static void *(*real_malloc)(size_t), *(*real_calloc)(size_t, size_t), *(*real_realloc)(void *, size_t);
static void (*real_free)(void *);
static char early[65536];
static size_t used;
static int resolving;
static void resolve(void) {
  if (real_free || resolving) return;
  resolving = 1;
  real_malloc = dlsym(RTLD_NEXT, "malloc");
  real_calloc = dlsym(RTLD_NEXT, "calloc");
  real_realloc = dlsym(RTLD_NEXT, "realloc");
  real_free = dlsym(RTLD_NEXT, "free");
  resolving = 0;
}
static void *bump(size_t n) {   /* what dlsym allocates before the real functions are known */
  void *p = early + used;
  used += (n + 15) & ~(size_t)15;
  return p;
}
static int isEarly(void *p) { return (char *)p >= early && (char *)p < early + sizeof early; }
static __thread int busy;
static volatile int ready;
#define N 16
static const char *names[N];
static unsigned long counts[N];
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

static int skipped(const char *f) {
  return !f || strstr(f, "libc.so") || strstr(f, "libstdc++") || strstr(f, "libgcc") || strstr(f, "allocs.so") || strstr(f, "ld-linux");
}

static int nobt;
static void count(void) {
  if (!ready || busy) return;
  if (nobt) { __atomic_add_fetch(&counts[0], 1, __ATOMIC_RELAXED); return; }
  busy = 1;
  void *bt[12];
  int n = backtrace(bt, 12);
  const char *who = "?";
  for (int i = 1; i < n; ++i) {
    Dl_info di;
    if (dladdr(bt[i], &di) && !skipped(di.dli_fname)) { who = di.dli_fname; break; }
  }
  pthread_mutex_lock(&mu);
  for (int i = 0; i < N; ++i) {
    if (!names[i]) names[i] = who;
    if (names[i] == who || !strcmp(names[i], who)) { counts[i]++; break; }
  }
  pthread_mutex_unlock(&mu);
  busy = 0;
}

static void dump(const char *p) {
  FILE *f = fopen(p, "w");
  if (!f) return;
  busy = 1;
  pthread_mutex_lock(&mu);
  for (int i = 0; i < N && names[i]; ++i) { fprintf(f, "%s %lu\n", names[i], counts[i]); counts[i] = 0; }
  pthread_mutex_unlock(&mu);
  fclose(f);
  busy = 0;
}

static void *watch(void *arg) {
  (void)arg;
  busy = 1;   /* this thread's own allocations are not counted */
  const char *p = getenv("ALLOCS_OUT");
  if (!p) return NULL;
  char go[4096];
  snprintf(go, sizeof go, "%s.go", p);
  for (;;) {
    if (access(go, F_OK) == 0) { dump(p); unlink(go); }
    usleep(50000);
  }
}

__attribute__((constructor)) static void init(void) {
  resolve();
  nobt = getenv("ALLOCS_TOTAL") != NULL;   /* just one total, no attribution (cheap) */
  if (nobt) names[0] = "total";
  void *bt[2];
  busy = 1;
  backtrace(bt, 2);   /* loads libgcc_s now, not inside malloc */
  busy = 0;
  pthread_t t;
  pthread_create(&t, NULL, watch, NULL);
  ready = 1;
}

void *malloc(size_t n) { resolve(); if (!real_malloc) return bump(n); count(); return real_malloc(n); }
void *calloc(size_t a, size_t b) { resolve(); if (!real_calloc) return bump(a * b); count(); return real_calloc(a, b); }
void *realloc(void *p, size_t n) {
  resolve();
  if (isEarly(p) || !real_realloc) { void *q = real_malloc ? real_malloc(n) : bump(n); if (p) memcpy(q, p, n); return q; }
  count();
  return real_realloc(p, n);
}
void free(void *p) { if (isEarly(p)) return; resolve(); if (real_free) real_free(p); }
