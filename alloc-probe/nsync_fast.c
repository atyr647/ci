// Inline fast path for the default mutex of Cosmopolitan's C library. Ship candidate.
//
// pthread_mutex_lock / unlock on a default, process-private mutex end in nsync_mu_lock / nsync_mu_unlock (libc/intrin/pthread_mutex_lock.c, pthread_mutex_unlock.c,
// cosmocc 4.0.2), after three more stack frames of dispatch. The first thing nsync does in either is one compare-and-swap on the 32-bit word at the start of
// `mutex->_nsync` (third_party/nsync/mu.c): lock 0 -> MU_WLOCK (1, acquire), unlock MU_WLOCK -> 0 (release); anything else is its slow path.
// This file does exactly those two compare-and-swaps in place and calls nsync_mu_lock / nsync_mu_unlock when they fail, so the mutex word goes through the same
// states as with the library's own code, in any mix: the library's condition variables (nsync), thread cancellation, robustness and contention behaviour are untouched.
// Other mutex kinds (recursive, error-checking, process-shared) and macOS (which does not use nsync mutexes) go to the library unchanged.
//
// Also provided because Cosmopolitan 4.0.2 has neither in its library: pthread_mutex_timedlock and pthread_mutex_clocklock (a try-lock poll with a growing sleep;
// nsync has no timed lock).
//
// Link: -Wl,--wrap=pthread_mutex_lock -Wl,--wrap=pthread_mutex_unlock
#define _COSMO_SOURCE
#include <cosmo.h>
#include <errno.h>
#include <libc/dce.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

extern int __real_pthread_mutex_lock(pthread_mutex_t *);
extern int __real_pthread_mutex_unlock(pthread_mutex_t *);
extern void nsync_mu_lock(void *);
extern void nsync_mu_unlock(void *);
extern int nsync_mu_trylock(void *);

#define MU_WLOCK 1u   // third_party/nsync/common.internal.h

// word bits (libc/thread/lock.h): 0-1 type (0 = normal/default), 2 process-shared
static inline int plain(pthread_mutex_t *m) {
  return (atomic_load_explicit(&m->_word, memory_order_relaxed) & 7) == 0 && !IsXnu();
}

int __wrap_pthread_mutex_lock(pthread_mutex_t *m) {
  if (plain(m)) {
    _Atomic uint32_t *w = (_Atomic uint32_t *)m->_nsync;
    uint32_t zero = 0;
    if (!atomic_compare_exchange_strong_explicit(w, &zero, MU_WLOCK, memory_order_acquire, memory_order_relaxed))
      nsync_mu_lock(m->_nsync);
    return 0;
  }
  return __real_pthread_mutex_lock(m);
}

int __wrap_pthread_mutex_unlock(pthread_mutex_t *m) {
  if (plain(m)) {
    _Atomic uint32_t *w = (_Atomic uint32_t *)m->_nsync;
    uint32_t held = MU_WLOCK;
    if (!atomic_compare_exchange_strong_explicit(w, &held, 0, memory_order_release, memory_order_relaxed))
      nsync_mu_unlock(m->_nsync);
    return 0;
  }
  return __real_pthread_mutex_unlock(m);
}

static int timedlock_impl(pthread_mutex_t *m, int clock, const struct timespec *abstime) {
  int use_nsync = plain(m);
  for (long us = 20;; us = us < 1000 ? us * 2 : us) {
    int rc;
    if (use_nsync) rc = nsync_mu_trylock(m->_nsync) ? 0 : EBUSY;
    else rc = pthread_mutex_trylock(m);
    if (rc != EBUSY) return rc;
    struct timespec now;
    if (clock_gettime(clock, &now)) return EINVAL;
    if (now.tv_sec > abstime->tv_sec || (now.tv_sec == abstime->tv_sec && now.tv_nsec >= abstime->tv_nsec)) return ETIMEDOUT;
    struct timespec nap = {0, us * 1000};
    nanosleep(&nap, 0);
  }
}

int pthread_mutex_timedlock(pthread_mutex_t *m, const struct timespec *abstime) { return timedlock_impl(m, CLOCK_REALTIME, abstime); }
int pthread_mutex_clocklock(pthread_mutex_t *m, int clock, const struct timespec *abstime) { return timedlock_impl(m, clock, abstime); }
