// Correctness test for the mutex / condition variable replacements in fast_sync.c (and for the library's own, as the control): prints OK/FAIL lines and a few timings.
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>
using namespace std::chrono;
static int fails = 0;
#define CHECK(c, what) do { if (!(c)) { printf("FAIL %s\n", what); fails++; } else printf("OK   %s\n", what); } while (0)
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
    std::mutex m; std::condition_variable notEmpty, notFull; std::deque<int> q; const size_t cap = 16; const int per = 50000; long sum = 0; std::atomic<int> done{0};
    auto prod = [&] { for (int i = 1; i <= per; i++) { std::unique_lock<std::mutex> l(m); notFull.wait(l, [&] { return q.size() < cap; }); q.push_back(i); notEmpty.notify_one(); } done++; };
    auto cons = [&] { for (;;) { std::unique_lock<std::mutex> l(m); notEmpty.wait(l, [&] { return !q.empty() || done == 2; }); if (q.empty()) return; sum += q.front(); q.pop_front(); notFull.notify_all(); } };
    std::thread p1(prod), p2(prod), c1(cons), c2(cons); p1.join(); p2.join(); { std::lock_guard<std::mutex> l(m); notEmpty.notify_all(); } c1.join(); c2.join();
    CHECK(sum == 2L * per * (per + 1) / 2, "producer/consumer sum");
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
  printf(fails ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", fails);
  return fails != 0;
}
