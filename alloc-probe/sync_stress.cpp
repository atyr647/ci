// Correctness test for the mutex / condition variable replacements in fast_sync.c (and for the library's own, as the control): prints OK/FAIL lines and a few timings.
#include <atomic>
#include <cerrno>
#include <ctime>
#include <pthread.h>
#include <signal.h>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>
#if defined(__COSMOPOLITAN__)
extern "C" int pthread_mutex_timedlock(pthread_mutex_t *, const struct timespec *);   // not declared by Cosmopolitan 4.0.2's headers (and not in its library: fast_sync.c provides it)
#endif
using namespace std::chrono;
static int fails = 0;
#define CHECK(c, what) do { if (!(c)) { printf("FAIL %s\n", what); fails++; } else printf("OK   %s\n", what); } while (0)

#ifndef _WIN32
// ---- thread cancellation inside condition-variable waits (POSIX: cancellation point; the mutex is re-acquired before the cleanup handlers run)
static pthread_mutex_t cm = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cc = PTHREAD_COND_INITIALIZER;
static std::atomic<int> cstate{0}, cheld{-1}, cflag{0};
static void cleanup_handler(void *) {
  if (pthread_mutex_trylock(&cm) == EBUSY) { cheld = 1; pthread_mutex_unlock(&cm); }   // still locked by this (cancelled) thread, as required
  else { cheld = 0; pthread_mutex_unlock(&cm); }
}
static void *waiter(void *arg) {
  int mode = (int)(long)arg;   // 0 wait, 1 timedwait, 2 cancel pending before the wait, 3 cancellation disabled around the wait
  pthread_mutex_lock(&cm);
  pthread_cleanup_push(cleanup_handler, 0);
  if (mode == 2) { int old; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old); cstate = 1; while (!cflag) { pthread_mutex_unlock(&cm); std::this_thread::sleep_for(milliseconds(1)); pthread_mutex_lock(&cm); } pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, &old); }
  if (mode == 3) { int old; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &old); }
  cstate = 1;
  for (;;) {
    if (mode == 1) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 30; pthread_cond_timedwait(&cc, &cm, &ts); }
    else pthread_cond_wait(&cc, &cm);
    if (mode == 3) { cflag = 2; int old; pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, &old); pthread_testcancel(); break; }
  }
  pthread_cleanup_pop(0);
  pthread_mutex_unlock(&cm);
  return (void *)7;
}
static bool run_cancel(int mode, const char *what) {
  cstate = 0; cheld = -1; cflag = 0; pthread_t t; pthread_create(&t, 0, waiter, (void *)(long)mode);
  while (cstate != 1) std::this_thread::sleep_for(milliseconds(1));
  std::this_thread::sleep_for(milliseconds(50));   // now inside the wait (mode 2: waiting for the flag with cancellation disabled)
  pthread_cancel(t);
  if (mode == 2) { cflag = 1; }
  if (mode == 3) { std::this_thread::sleep_for(milliseconds(20)); pthread_mutex_lock(&cm); pthread_cond_signal(&cc); pthread_mutex_unlock(&cm); }
  auto t0 = steady_clock::now(); void *ret = 0;
  std::atomic<int> joined{0}; std::thread j([&] { pthread_join(t, &ret); joined = 1; });
  while (!joined && duration<double>(steady_clock::now() - t0).count() < 5) std::this_thread::sleep_for(milliseconds(1));
  if (!joined) { printf("FAIL %s: thread did not finish within 5 s (cancellation not delivered)\n", what); fails++; _exit(3); }   // cannot join: leave
  j.join();
  bool ok = ret == PTHREAD_CANCELED && cheld == 1;
  char buf[160]; snprintf(buf, sizeof buf, "%s (result %s, mutex held by the cancelled thread when its cleanup ran: %d)", what, ret == PTHREAD_CANCELED ? "cancelled" : "not cancelled", (int)cheld);
  CHECK(ok, buf);
  CHECK(pthread_mutex_trylock(&cm) == 0, "mutex usable after the cancellation"); pthread_mutex_unlock(&cm);
  return ok;
}
#endif
int main() {
  {   // contended counter
    std::mutex m; long c = 0; const int T = 8, N = 200000; std::vector<std::thread> v;
    auto t0 = steady_clock::now();
    for (int i = 0; i < T; i++) v.emplace_back([&] { for (int k = 0; k < N; k++) { std::lock_guard<std::mutex> l(m); c++; } });
    for (auto &t : v) t.join();
    CHECK(c == (long)T * N, "contended counter");
    printf("TIME contended 8 threads x 200000: %.1f ms\n", duration<double, std::milli>(steady_clock::now() - t0).count());
  }
  {   // bounded queue, 2 producers 2 consumers, notify_one and notify_all
    std::mutex m; std::condition_variable notEmpty, notFull; std::deque<int> q; const size_t cap = 16; const int per = 50000; long long sum = 0; std::atomic<int> done{0};
    auto prod = [&] { for (int i = 1; i <= per; i++) { std::unique_lock<std::mutex> l(m); notFull.wait(l, [&] { return q.size() < cap; }); q.push_back(i); notEmpty.notify_one(); } done++; };
    auto cons = [&] { for (;;) { std::unique_lock<std::mutex> l(m); notEmpty.wait(l, [&] { return !q.empty() || done == 2; }); if (q.empty()) return; sum += q.front(); q.pop_front(); notFull.notify_all(); } };
    std::thread p1(prod), p2(prod), c1(cons), c2(cons); p1.join(); p2.join(); { std::lock_guard<std::mutex> l(m); notEmpty.notify_all(); } c1.join(); c2.join();
    CHECK(sum == 2LL * per * (per + 1) / 2, "producer/consumer sum");   // long long: `long` is 32 bits on Windows and 2.5e9 does not fit
  }
  {   // timed wait: times out, and wakes early when notified
    std::mutex m; std::condition_variable cv; bool flag = false; std::unique_lock<std::mutex> l(m);
    auto t0 = steady_clock::now(); bool r = cv.wait_for(l, milliseconds(30), [&] { return flag; }); double ms = duration<double, std::milli>(steady_clock::now() - t0).count();
    CHECK(!r && ms >= 25 && ms < 500, "wait_for times out");
    l.unlock(); std::thread n([&] { std::this_thread::sleep_for(milliseconds(20)); { std::lock_guard<std::mutex> g(m); flag = true; } cv.notify_one(); });
    l.lock(); t0 = steady_clock::now(); r = cv.wait_for(l, seconds(5), [&] { return flag; }); ms = duration<double, std::milli>(steady_clock::now() - t0).count(); n.join();
    CHECK(r && ms < 1000, "wait_for wakes early");
  }
  {   // try_lock
    std::mutex m; CHECK(m.try_lock(), "try_lock free"); bool other = true; std::thread t([&] { other = m.try_lock(); }); t.join(); CHECK(!other, "try_lock held"); m.unlock();
    CHECK(m.try_lock(), "try_lock after unlock"); m.unlock();
  }
  {   // recursive mutex and condition_variable_any (must keep working: library path)
    std::recursive_mutex rm; long c = 0; std::vector<std::thread> v;
    for (int i = 0; i < 4; i++) v.emplace_back([&] { for (int k = 0; k < 50000; k++) { std::lock_guard<std::recursive_mutex> a(rm); std::lock_guard<std::recursive_mutex> b(rm); c++; } });
    for (auto &t : v) t.join(); CHECK(c == 200000, "recursive mutex");
    std::condition_variable_any cva; std::mutex m; bool go = false; std::thread t([&] { std::unique_lock<std::mutex> l(m); cva.wait(l, [&] { return go; }); });
    std::this_thread::sleep_for(milliseconds(10)); { std::lock_guard<std::mutex> l(m); go = true; } cva.notify_all(); t.join(); CHECK(true, "condition_variable_any");
  }
  {   // call_once and thread-safe statics
    std::once_flag f; std::atomic<int> n{0}; std::vector<std::thread> v;
    for (int i = 0; i < 8; i++) v.emplace_back([&] { std::call_once(f, [&] { n++; std::this_thread::sleep_for(milliseconds(5)); }); static int s = (n++, 7); (void)s; });
    for (auto &t : v) t.join(); CHECK(n == 2, "call_once + static init");
  }
  {   // many short-lived waiters on one condition variable (broadcast)
    std::mutex m; std::condition_variable cv; bool go = false; std::atomic<int> woke{0}; std::vector<std::thread> v;
    for (int i = 0; i < 16; i++) v.emplace_back([&] { std::unique_lock<std::mutex> l(m); cv.wait(l, [&] { return go; }); woke++; });
    std::this_thread::sleep_for(milliseconds(30)); { std::lock_guard<std::mutex> l(m); go = true; } cv.notify_all(); for (auto &t : v) t.join(); CHECK(woke == 16, "broadcast wakes all");
  }
  {   // ping-pong
    std::mutex m; std::condition_variable cv; int turn = 0; const int n = 20000; auto t0 = steady_clock::now();
    std::thread o([&] { for (int i = 0; i < n; i++) { std::unique_lock<std::mutex> l(m); cv.wait(l, [&] { return turn == 1; }); turn = 0; cv.notify_one(); } });
    for (int i = 0; i < n; i++) { std::unique_lock<std::mutex> l(m); turn = 1; cv.notify_one(); cv.wait(l, [&] { return turn == 0; }); }
    o.join(); printf("TIME ping-pong: %.2f us per round trip\n", duration<double, std::micro>(steady_clock::now() - t0).count() / n);
  }

#ifndef _WIN32
  run_cancel(0, "cancel a thread blocked in pthread_cond_wait");
  run_cancel(1, "cancel a thread blocked in pthread_cond_timedwait");
  run_cancel(2, "cancellation pending when the wait starts");
  run_cancel(3, "cancellation disabled around the wait: the wake-up is delivered, cancel acts afterwards");
#ifdef HAVE_TIMEDLOCK
  {   // lock with a deadline
    pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER; struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts); CHECK(pthread_mutex_timedlock(&m, &ts) == 0, "timedlock on a free mutex"); pthread_mutex_unlock(&m);
    pthread_mutex_lock(&m); clock_gettime(CLOCK_REALTIME, &ts); ts.tv_nsec += 30000000; if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
    auto t0 = steady_clock::now(); int rc = pthread_mutex_timedlock(&m, &ts); double ms = duration<double, std::milli>(steady_clock::now() - t0).count();
    CHECK(rc == ETIMEDOUT && ms >= 25 && ms < 1000, "timedlock times out on a held mutex");
    std::thread rel([&] { std::this_thread::sleep_for(milliseconds(20)); pthread_mutex_unlock(&m); });
    clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 5; CHECK(pthread_mutex_timedlock(&m, &ts) == 0, "timedlock acquires when the holder releases"); rel.join(); pthread_mutex_unlock(&m);
    pthread_mutexattr_t a; pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE); pthread_mutex_t r; pthread_mutex_init(&r, &a);
    pthread_mutex_lock(&r); std::atomic<int> rrc{-1}; std::thread o([&] { struct timespec t2; clock_gettime(CLOCK_REALTIME, &t2); t2.tv_nsec += 30000000; if (t2.tv_nsec >= 1000000000) { t2.tv_sec++; t2.tv_nsec -= 1000000000; } rrc = pthread_mutex_timedlock(&r, &t2); });
    o.join(); CHECK(rrc == ETIMEDOUT, "timedlock on a recursive mutex held by another thread times out"); pthread_mutex_unlock(&r);
  }
#endif
#endif
  printf(fails ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", fails);
  return fails != 0;
}
