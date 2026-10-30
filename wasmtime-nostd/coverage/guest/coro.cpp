// C++20 coroutines are stackless: the compiler turns them into state machines, so they need nothing from the host. Checks that they work and measures a resume.
#include <coroutine>
#include <cstdint>
#include <cstdio>
#include <utility>

struct Gen {
    struct promise_type {
        uint64_t cur = 0;
        Gen get_return_object() { return Gen{std::coroutine_handle<promise_type>::from_promise(*this)}; }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        std::suspend_always yield_value(uint64_t v) noexcept { cur = v; return {}; }
        void return_void() noexcept {}
        void unhandled_exception() noexcept {}
    };
    std::coroutine_handle<promise_type> h;
    explicit Gen(std::coroutine_handle<promise_type> h) : h(h) {}
    Gen(Gen&& o) noexcept : h(std::exchange(o.h, {})) {}
    ~Gen() { if (h) h.destroy(); }
    bool next() { h.resume(); return !h.done(); }
    uint64_t value() const { return h.promise().cur; }
};

__attribute__((noinline)) Gen counter(uint64_t n) { for (uint64_t i = 0; i < n; i++) co_yield i * 3 + 1; }

// a tiny round-robin scheduler of coroutine tasks that each yield a few times
struct Task {
    struct promise_type {
        Task get_return_object() { return Task{std::coroutine_handle<promise_type>::from_promise(*this)}; }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        void return_void() noexcept {}
        void unhandled_exception() noexcept {}
    };
    std::coroutine_handle<promise_type> h;
};
static uint64_t g_sched_total;
__attribute__((noinline)) Task worker(int id, int steps) { for (int i = 0; i < steps; i++) { g_sched_total += (uint64_t)(id * 100 + i); co_await std::suspend_always{}; } }

extern "C" {
__attribute__((export_name("t_generator"))) int t_generator(void) {
    uint64_t n = 1000, s = 0; Gen g = counter(n); while (g.next()) s += g.value();
    return s == 3 * (n * (n - 1) / 2) + n;
}
__attribute__((export_name("t_scheduler"))) int t_scheduler(void) {
    g_sched_total = 0; Task t[4] = { worker(1, 5), worker(2, 3), worker(3, 7), worker(4, 1) };
    bool any = true; while (any) { any = false; for (auto& x : t) if (!x.h.done()) { x.h.resume(); if (!x.h.done()) any = true; } }
    for (auto& x : t) x.h.destroy();
    uint64_t want = 0; int steps[4] = {5, 3, 7, 1}; for (int k = 0; k < 4; k++) for (int i = 0; i < steps[k]; i++) want += (uint64_t)((k + 1) * 100 + i);
    return g_sched_total == want;
}
__attribute__((export_name("s_coro"))) uint64_t s_coro(uint64_t n) { uint64_t s = 0; Gen g = counter(n); while (g.next()) s += g.value(); return s; }
__attribute__((noinline)) static uint64_t plain_term(uint64_t i) { return i * 3 + 1; }
__attribute__((export_name("s_plain"))) uint64_t s_plain(uint64_t n) { uint64_t s = 0; for (uint64_t i = 0; i < n; i++) s += plain_term(i); return s; }
}
