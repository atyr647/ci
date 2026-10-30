// Faster default mutex + condition variable for programs built with Cosmopolitan.
//
// Measured (Dawn built by Cosmopolitan, 2026-10-30): a default mutex lock+unlock costs 14-23 ns against 4-6 ns for glibc, through four stack frames
// (pthread_mutex_lock -> _pthread_mutex_lock -> pthread_mutex_lock_impl -> nsync_mu_lock). The library takes the nsync path because a condition variable on a plain
// private mutex uses nsync (pthread_cond_timedwait.c: can_use_nsync), which forces every such mutex onto the nsync word. The library also contains a futex-only
// implementation of both ("take 3" of Drepper's "Futexes are tricky" for the mutex; a sequence-counter condition variable, `_footek`), used for everything else.
//
// This file selects that futex-only pair for default, process-private mutexes and routes the condition variable wait onto it, so the two stay consistent:
//   - pthread_mutex_lock / unlock / trylock on a plain private mutex: Drepper futex on mutex->_futex, inlined (one compare-and-swap, one fetch-sub);
//   - pthread_cond_wait / timedwait with such a mutex: the library's own sequence-counter algorithm (copied from pthread_cond_timedwait_impl), unlocking and locking
//     through the functions above; the condition variable is marked `_footek` so the library's untouched pthread_cond_signal / broadcast use the same counter;
//   - everything else (recursive, error-checking, process-shared mutexes, Apple Silicon where the library already avoids nsync) goes to the library unchanged.
// A mutex must be used through these entry points only (never locked here and unlocked by library-internal code); libc++'s std::mutex / condition_variable,
// which Dawn uses, call the public pthread_* symbols. Not provided: thread cancellation inside the wait (the library's version is a cancellation point),
// pthread_mutex_timedlock / clocklock on a plain mutex (std::timed_mutex does not use them).
//
// Link: -Wl,--wrap=pthread_mutex_lock -Wl,--wrap=pthread_mutex_unlock -Wl,--wrap=pthread_mutex_trylock -Wl,--wrap=pthread_cond_wait -Wl,--wrap=pthread_cond_timedwait
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
extern int __real_pthread_mutex_trylock(pthread_mutex_t *);
extern int __real_pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
extern int __real_pthread_cond_timedwait(pthread_cond_t *, pthread_mutex_t *, const struct timespec *);

// word bits (libc/thread/lock.h): 0-1 type (0 = normal/default), 2 process-shared
static inline int plain(pthread_mutex_t *m) {
  return (atomic_load_explicit(&m->_word, memory_order_relaxed) & 7) == 0 && !IsXnu();
}

static inline void dlock(pthread_mutex_t *m) {
  atomic_int *f = (atomic_int *)&m->_futex;
  int val = 0;
  if (atomic_compare_exchange_strong_explicit(f, &val, 1, memory_order_acquire, memory_order_acquire))
    return;
  if (val == 1)
    val = atomic_exchange_explicit(f, 2, memory_order_acquire);
  while (val > 0) {
    cosmo_futex_wait(f, 2, 0, 0, 0);
    val = atomic_exchange_explicit(f, 2, memory_order_acquire);
  }
}

static inline void dunlock(pthread_mutex_t *m) {
  atomic_int *f = (atomic_int *)&m->_futex;
  if (atomic_fetch_sub_explicit(f, 1, memory_order_release) == 2) {
    atomic_store_explicit(f, 0, memory_order_release);
    cosmo_futex_wake(f, 1, 0);
  }
}

int __wrap_pthread_mutex_lock(pthread_mutex_t *m) {
  if (plain(m)) { dlock(m); return 0; }
  return __real_pthread_mutex_lock(m);
}

int __wrap_pthread_mutex_unlock(pthread_mutex_t *m) {
  if (plain(m)) { dunlock(m); return 0; }
  return __real_pthread_mutex_unlock(m);
}

int __wrap_pthread_mutex_trylock(pthread_mutex_t *m) {
  if (plain(m)) {
    int val = 0;
    return atomic_compare_exchange_strong_explicit((atomic_int *)&m->_futex, &val, 1, memory_order_acquire, memory_order_acquire) ? 0 : EBUSY;
  }
  return __real_pthread_mutex_trylock(m);
}

static int cond_wait_impl(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *abstime, int *handled) {
  *handled = 0;
  if (!plain(m) || c->_pshared) return 0;
  // the library decides once, at the first wait, whether a condition variable uses nsync (`_footek` = 0) or the sequence counter (`_footek` = 1)
  if (!atomic_load_explicit(&c->_waited, memory_order_acquire)) {
    c->_footek = 1;
    atomic_store_explicit(&c->_waited, 1, memory_order_release);
  } else if (!c->_footek) {
    return 0;   // this condition variable already works with nsync: leave it to the library
  }
  *handled = 1;
  uint32_t seq = atomic_load_explicit(&c->_sequence, memory_order_relaxed);
  atomic_fetch_add_explicit(&c->_waiters, 1, memory_order_acq_rel);
  dunlock(m);
  int rc = cosmo_futex_wait((atomic_int *)&c->_sequence, (int)seq, c->_pshared, c->_clock, abstime);
  dlock(m);
  atomic_fetch_sub_explicit(&c->_waiters, 1, memory_order_acq_rel);
  if (rc == -EAGAIN || rc == -EINTR) rc = 0;   // value changed already / interrupted: both are allowed spurious wake-ups
  return -rc;
}

int __wrap_pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *abstime) {
  int handled, rc = cond_wait_impl(c, m, abstime, &handled);
  return handled ? rc : __real_pthread_cond_timedwait(c, m, abstime);
}

int __wrap_pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) {
  int handled, rc = cond_wait_impl(c, m, 0, &handled);
  return handled ? rc : __real_pthread_cond_wait(c, m);
}
