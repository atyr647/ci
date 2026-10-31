// A "foreign" library built by the platform's own compiler (glibc, normal register use). Functions here do what real driver code may do:
// use x28 as a general register, and use thread-local storage of its own.
#include <stdint.h>
#ifdef __aarch64__
// keeps a counter in x28 for n iterations (x28 is callee-saved, so the compiler saves and restores it around the asm; during the loop it holds a small integer, not a pointer)
long clobber_spin(long n) {
  long out;
  __asm__ volatile("mov x28, %1\n1: subs x28, x28, #1\n b.ne 1b\n mov %0, x28" : "=r"(out) : "r"(n) : "x28", "cc");
  return out;
}
#else
long clobber_spin(long n) { volatile long x = n; while (x > 0) x--; return 0; }
#endif
long clobber_nop(long v) { return v + 1; }
static __thread long tls_value;     // glibc TLS of this library (the thread register of the foreign code)
long clobber_tls(long add) { tls_value += add; return tls_value; }

/* ---- a battery of ordinary C library use by foreign code (what drivers do), each returning 0 when it behaved ---- */
#include <ctype.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
long fb_ctype(long n) { long bad = 0; for (long i = 0; i < n; i++) { int c = 'a' + (int)(i % 26); if (!isalpha(c) || toupper(c) != c - 32 || isdigit(c)) bad++; } return bad; }
long fb_malloc(long n) { long bad = 0; void *p[64]; for (long i = 0; i < n; i++) { for (int k = 0; k < 64; k++) { p[k] = malloc(16 + (i * 7 + k) % 900); if (!p[k]) bad++; else memset(p[k], 0x5a, 16); } for (int k = 0; k < 64; k++) free(p[k]); } return bad; }
long fb_errno(long n) { long bad = 0; for (long i = 0; i < n; i++) { errno = (int)(i % 200) + 1; if (errno != (int)(i % 200) + 1) bad++; FILE *f = fopen("/nonexistent/x", "r"); if (f || errno != ENOENT) bad++; } return bad; }
long fb_format(long n) { long bad = 0; char b[64]; for (long i = 0; i < n; i++) { snprintf(b, sizeof b, "%ld %.3f", i, i * 0.5); if (strtod(b + strcspn(b, " ") + 1, 0) != i * 0.5) bad++; } return bad; }
static pthread_mutex_t fm = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t fc = PTHREAD_COND_INITIALIZER; static int fready;
long fb_mutex(long n) { long bad = 0; for (long i = 0; i < n; i++) { if (pthread_mutex_lock(&fm)) bad++; if (pthread_mutex_unlock(&fm)) bad++; }
  struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_nsec += 20000000; if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
  pthread_mutex_lock(&fm); int r = pthread_cond_timedwait(&fc, &fm, &ts); pthread_mutex_unlock(&fm); if (r != ETIMEDOUT) bad++; return bad; }
static void *fth(void *a) { pthread_mutex_lock(&fm); fready = 1; pthread_cond_broadcast(&fc); pthread_mutex_unlock(&fm); return a; }
long fb_spawn_join(long n) { long bad = 0; for (long i = 0; i < n; i++) { pthread_t t; fready = 0; if (pthread_create(&t, 0, fth, (void *)i)) { bad++; continue; } void *r = 0; if (pthread_join(t, &r) || r != (void *)i) bad++; } return bad; }
static pthread_once_t fo = PTHREAD_ONCE_INIT; static int fonce; static void foinit(void) { fonce++; }
long fb_once(long n) { for (long i = 0; i < n; i++) pthread_once(&fo, foinit); return fonce == 1 ? 0 : 1; }
long fb_self(long n) { long bad = 0; pthread_t me = pthread_self(); for (long i = 0; i < n; i++) if (!pthread_equal(me, pthread_self())) bad++; return bad; }
