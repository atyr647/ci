// Shorter path for the common mutex in Cosmopolitan's C library.
//
// pthread_mutex_lock/unlock go wrapper -> _pthread_mutex_lock -> pthread_mutex_lock_impl -> nsync_mu_lock for a default, process-private mutex (profile of Dawn built by
// Cosmopolitan, 2026-10-30: five stack frames, 14-18 ns per lock+unlock against 4-6 ns for glibc). For exactly that mutex kind the result is a call to nsync_mu_lock/unlock
// (see libc/intrin/pthread_mutex_lock.c and pthread_mutex_unlock.c, cosmocc 4.0.2), so do it directly. Every other kind (recursive, error-checking, process-shared) and
// Apple Silicon (where the library uses ulock-based futexes instead of nsync) goes to the library unchanged. Linked with -Wl,--wrap=pthread_mutex_lock -Wl,--wrap=pthread_mutex_unlock.
#define _COSMO_SOURCE
#include <cosmo.h>
#include <libc/dce.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>

extern int __real_pthread_mutex_lock(pthread_mutex_t *);
extern int __real_pthread_mutex_unlock(pthread_mutex_t *);
extern void nsync_mu_lock(void *);
extern void nsync_mu_unlock(void *);

// word bits (libc/thread/lock.h): 0-1 type (0 = normal/default), 2 process-shared
#define MUTEX_PLAIN(word) (((word) & 7) == 0)

int __wrap_pthread_mutex_lock(pthread_mutex_t *m) {
  uint64_t word = atomic_load_explicit(&m->_word, memory_order_relaxed);
  if (MUTEX_PLAIN(word) && !IsXnu()) {
    nsync_mu_lock(m->_nsync);
    return 0;
  }
  return __real_pthread_mutex_lock(m);
}

int __wrap_pthread_mutex_unlock(pthread_mutex_t *m) {
  uint64_t word = atomic_load_explicit(&m->_word, memory_order_relaxed);
  if (MUTEX_PLAIN(word) && !IsXnu()) {
    nsync_mu_unlock(m->_nsync);
    return 0;
  }
  return __real_pthread_mutex_unlock(m);
}
