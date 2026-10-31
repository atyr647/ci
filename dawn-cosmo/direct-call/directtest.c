// Is it safe to call foreign (driver) code on arm64 without the signal-blocking trampoline of cosmo_dltramp?
//   The trampoline blocks ALL signals around every foreign call (2 rt_sigprocmask system calls), because foreign code may use x28 (Cosmopolitan's thread register on arm64):
//   a signal handler of ours that runs while x28 holds foreign data would read thread-local storage through garbage.
// Modes (each in its own process, see the workflow):
//   tramp            via cosmo_dltramp, signal storm (SIGALRM every 1 ms)                          -> must work
//   direct-open      raw pointer, async signals not blocked, same storm                            -> shows the hazard (expected to crash or misbehave)
//   direct-blocked   raw pointer, this thread blocks async signals, a helper thread receives them -> must work, main thread handles none
//   direct-poll      raw pointer, this thread blocks async signals, no helper: signals are taken at safe points with sigtimedwait -> must work, all signals seen
//   cost             ns per call: trampoline vs raw pointer vs raw pointer with a thread-local gate
//   threads          foreign TLS and calls from threads that Cosmopolitan created
#define _GNU_SOURCE
#include <cosmo.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

typedef long (*fn_t)(long);
static void *g_h;
static fn_t f_spin, f_nop, f_tls, t_spin, t_nop, t_tls;   // f_* raw, t_* through the trampoline
static _Thread_local volatile long tl_handled;            // thread-local through x28
static atomic_long g_handled;
static void on_alrm(int s) { (void)s; int e = errno; tl_handled++; atomic_fetch_add(&g_handled, 1); errno = e; }

static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static void block_async(void) { sigset_t m; sigfillset(&m); sigdelset(&m, SIGSEGV); sigdelset(&m, SIGBUS); sigdelset(&m, SIGFPE); sigdelset(&m, SIGILL); sigdelset(&m, SIGTRAP); pthread_sigmask(SIG_SETMASK, &m, 0); }
static void storm(int on) { struct itimerval it = {{0, on ? 1000 : 0}, {0, on ? 1000 : 0}}; setitimer(ITIMER_REAL, &it, 0); }
static void install(void) { struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_alrm; sigaction(SIGALRM, &sa, 0); }

static void *helper(void *arg) { (void)arg; sigset_t m; sigemptyset(&m); pthread_sigmask(SIG_SETMASK, &m, 0); double t0 = now_s(); while (now_s() - t0 < 4.0) { struct timespec ts = {0, 500000}; nanosleep(&ts, 0); } return (void *)tl_handled; }

static int run_storm(fn_t f, int blocked, int helper_thread, int poll, double seconds, const char *label) {
  install(); atomic_store(&g_handled, 0); tl_handled = 0;
  pthread_t h; if (helper_thread) pthread_create(&h, 0, helper, 0);
  if (blocked) block_async();
  storm(1); double t0 = now_s(); long calls = 0, polled = 0; sigset_t w; sigemptyset(&w); sigaddset(&w, SIGALRM);
  while (now_s() - t0 < seconds) {
    f(300000); calls++;     // about 0.1-0.3 ms inside foreign code with x28 holding a small integer
    if (poll) { struct timespec z = {0, 0}; while (sigtimedwait(&w, 0, &z) == SIGALRM) polled++; }
  }
  storm(0); long main_handled = tl_handled; long helper_handled = 0;
  if (helper_thread) { void *r; pthread_join(h, &r); helper_handled = (long)r; }
  printf("RESULT %s calls=%ld signals_handled_by_main_thread=%ld signals_handled_by_helper=%ld polled_at_safe_points=%ld total_handler_runs=%ld\n", label, calls, main_handled, helper_handled, polled, (long)atomic_load(&g_handled));
  return 0;
}

static void *thr_nop(void *arg) { long id = (long)arg; long a = f_nop(id), b = t_nop(id); printf("THREAD %ld foreign_calls_without_tls raw=%ld trampolined=%ld (expected %ld)\n", id, a, b, id + 1); fflush(stdout); return 0; }
static void *thr(void *arg) {
  long id = (long)arg; printf("THREAD %ld about to touch foreign TLS\n", id); fflush(stdout); long a = f_tls(1), b = f_tls(1), c = t_tls(1);   // foreign thread-local storage, raw and trampolined
  printf("THREAD %ld foreign_tls_values_raw=%ld,%ld trampolined=%ld (expected 1,2,3)\n", id, a, b, c); fflush(stdout);
  return 0;
}

static const char *g_test; static int g_result = -99;
static int g_pre;   // 1: call the foreign uselocale(LC_GLOBAL_LOCALE) first (sets the thread's locale and ctype pointers, which glibc normally sets when it starts a thread)
static void *battery_thr(void *arg) {
    (void)arg;
    if (g_pre == 1) { typedef void *(*ul_t)(void *); ul_t ul = cosmo_dltramp(cosmo_dlsym(g_h, "uselocale")); if (ul) ul((void *)-1); }
    fn_t f = cosmo_dlsym(g_h, g_test); g_result = (int)f(2000); return 0;
}
// a thread created by the FOREIGN C library's pthread_create, running our (Cosmopolitan) code: does Cosmopolitan code work there?
static void *foreign_made(void *arg) {
    (void)arg; static const char m[] = "in a foreign-created thread: cosmo write works\n"; write(1, m, sizeof m - 1);
    void *p = malloc(100); free(p); errno = 5; int e = errno; printf("cosmo malloc/errno/printf there: errno %d\n", e);
    fn_t f = cosmo_dlsym(g_h, g_test); g_result = (int)f(2000); return 0;
}
static void tlsinfo(const char *where) {
    long o[3] = {0, 0, 0}; typedef long (*ti_t)(long *); ti_t ti = cosmo_dltramp(cosmo_dlsym(g_h, "fb_tlsinfo")); ti(o);
    void *sa = 0; size_t ss = 0; pthread_attr_t at; pthread_getattr_np(pthread_self(), &at); pthread_attr_getstack(&at, &sa, &ss);
    static _Thread_local volatile long mine;
    printf("TLSINFO %-8s foreign: tp=%#lx &tls_var=%#lx (tp%+ld) &errno=%#lx (tp%+ld) | cosmo: __get_tls=%p &mine=%p (tib%+ld) | stack %p..%p\n", where, o[0], o[1], o[1] - o[0], o[2], o[2] - o[0],
           (void *)__get_tls(), (void *)&mine, (long)((char *)&mine - (char *)__get_tls()), sa, (char *)sa + ss);
}
static void *tlsinfo_thr(void *a) { (void)a; tlsinfo("thread"); return 0; }
int main(int argc, char **argv) {
  const char *mode = argc > 1 ? argv[1] : "tramp";
  void *h = g_h = cosmo_dlopen("./libclobber.so", RTLD_NOW); if (!h) { printf("dlopen failed: %s\n", cosmo_dlerror()); return 2; }
  f_spin = cosmo_dlsym(h, "clobber_spin"); f_nop = cosmo_dlsym(h, "clobber_nop"); f_tls = cosmo_dlsym(h, "clobber_tls");
  if (!f_spin || !f_nop || !f_tls) { printf("dlsym failed\n"); return 2; }
  t_spin = cosmo_dltramp(f_spin); t_nop = cosmo_dltramp(f_nop); t_tls = cosmo_dltramp(f_tls);
  printf("MODE %s (x28 clobber: %ld)\n", mode, f_spin(10)); fflush(stdout);
  if (!strcmp(mode, "tramp")) return run_storm(t_spin, 0, 0, 0, 2.0, "tramp");
  if (!strcmp(mode, "direct-open")) { setvbuf(stdout, 0, _IONBF, 0); return run_storm(f_spin, 0, 0, 0, 2.0, "direct-open"); }
  if (!strcmp(mode, "direct-blocked")) return run_storm(f_spin, 1, 1, 0, 2.0, "direct-blocked");
  if (!strcmp(mode, "direct-poll")) return run_storm(f_spin, 1, 0, 1, 2.0, "direct-poll");
  if (!strcmp(mode, "cost")) {
    const long N = 3000000; double t0; volatile long sink = 0;
    t0 = now_s(); for (long i = 0; i < N; i++) sink += t_nop(i); double tr = (now_s() - t0) / N * 1e9;
    t0 = now_s(); for (long i = 0; i < N; i++) sink += f_nop(i); double di = (now_s() - t0) / N * 1e9;
    static _Thread_local volatile char gate = 1;
    t0 = now_s(); for (long i = 0; i < N; i++) sink += gate ? f_nop(i) : t_nop(i); double ga = (now_s() - t0) / N * 1e9;
    printf("RESULT cost trampoline=%.1f ns/call raw=%.1f ns/call raw_with_thread_local_gate=%.1f ns/call\n", tr, di, ga); return 0;
  }
  if (!strcmp(mode, "threads-nop")) {   // control: foreign calls that touch no thread-local storage, from threads Cosmopolitan created
    setvbuf(stdout, 0, _IONBF, 0);
    for (long i = 1; i <= 3; i++) { pthread_t t; pthread_create(&t, 0, thr_nop, (void *)i); pthread_join(t, 0); }
    printf("RESULT threads-nop done\n"); return 0;
  }
  if (!strcmp(mode, "threads")) {
    setvbuf(stdout, 0, _IONBF, 0);
    long a = f_tls(1), b = f_tls(1), c = t_tls(1); printf("THREAD main foreign_tls_values_raw=%ld,%ld trampolined=%ld (expected 1,2,3)\n", a, b, c); fflush(stdout);
    for (long i = 1; i <= 3; i++) { pthread_t t; pthread_create(&t, 0, thr, (void *)i); pthread_join(t, 0); }
    printf("RESULT threads done\n"); return 0;
  }
  if (!strcmp(mode, "tlsinfo")) { setvbuf(stdout, 0, _IONBF, 0); tlsinfo("main"); pthread_t t; pthread_create(&t, 0, tlsinfo_thr, 0); pthread_join(t, 0); return 0; }
  if (!strcmp(mode, "battery")) {   // battery <fb_test> <main|thread|thread-ctype-init>: foreign C library use from the main thread or from a thread the C library created
    setvbuf(stdout, 0, _IONBF, 0); g_test = argc > 2 ? argv[2] : "fb_ctype"; const char *where = argc > 3 ? argv[3] : "main";
    g_pre = strstr(where, "uselocale") ? 1 : 0;
    if (!strcmp(where, "foreign-thread")) {
        typedef int (*pc_t)(unsigned long *, const void *, void *(*)(void *), void *); typedef int (*pj_t)(unsigned long, void **);
        pc_t pc = cosmo_dltramp(cosmo_dlsym(g_h, "pthread_create")); pj_t pj = cosmo_dltramp(cosmo_dlsym(g_h, "pthread_join")); unsigned long t = 0;
        if (!pc || pc(&t, 0, foreign_made, 0)) { printf("foreign pthread_create failed\n"); return 3; } pj(t, 0);
    } else if (!strncmp(where, "thread", 6)) { pthread_t t; pthread_create(&t, 0, battery_thr, 0); pthread_join(t, 0); } else { fn_t f = cosmo_dlsym(h, g_test); g_result = (int)f(2000); }
    printf("RESULT battery %s on %s: %s (misbehaviours %d)\n", g_test, where, g_result == 0 ? "ok" : "WRONG", g_result); return g_result == 0 ? 0 : 1;
  }
  printf("unknown mode\n"); return 2;
}
