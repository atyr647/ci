// Thread-safe function-local statics (__cxa_guard_acquire / release): many threads race the first use of 600 different statics that each allocate; every thread must see a fully built object,
// and each constructor must run exactly once. exit 0 = no violation.
#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <utility>
#include <vector>
static std::atomic<int> ctor_runs[600];
template <int N> struct S { std::vector<int> v; S() : v(64, N) { ctor_runs[N]++; } };
template <int N> const S<N> &get() { static const S<N> s; return s; }
using Fn = int (*)();
template <int N> int probe() { const S<N> &s = get<N>(); return (s.v.size() == 64 && s.v[0] == N && s.v[63] == N) ? 0 : 1; }
template <int... I> constexpr std::array<Fn, sizeof...(I)> table(std::integer_sequence<int, I...>) { return {{&probe<I>...}}; }
int main(int argc, char **argv) {
    int nt = argc > 1 ? atoi(argv[1]) : 12; auto fns = table(std::make_integer_sequence<int, 600>{});
    std::atomic<int> go{0}, bad{0}; std::vector<std::thread> th;
    for (int t = 0; t < nt; t++) th.emplace_back([&, t] { while (!go.load()) {} for (size_t i = 0; i < fns.size(); i++) bad += fns[(i + t * 37) % fns.size()](); });
    go = 1; for (auto &x : th) x.join();
    int dup = 0; for (auto &c : ctor_runs) if (c.load() != 1) dup++;
    printf("RESULT static_init_race threads=%d statics=600 partially_built_seen=%d constructors_not_run_exactly_once=%d\n", nt, (int)bad, dup); return (bad || dup) ? 1 : 0;
}
