/* Test host: Cosmopolitan program that runs a precompiled .cwasm through the statically linked no_std Wasmtime.
 * usage: wn.com <mode: sig|nosig|pulley> <guest-base> [options] [-- guest args...]   loads /zip/<guest-base>.<mode>.<arch>.cwasm (pulley: <guest-base>.pulley.cwasm), or the same name in the current directory.
 *   --invoke=a,b,c     call these exports in order in one instance (a trap must not end the process or spoil the next call)
 *   --expect-fault     after an out-of-bounds trap check the fault address Wasmtime was given against the expected one (signals mode)
 *   --stress --threads=N --seconds=S --engine=shared|private    stress.cwasm: N OS threads run compute, host calls, memory.grow and deliberate traps in a loop and check every result
 *   guest base "par" (or --wt) turns on the wasm threads proposal and provides wasi:thread-spawn (each wasm thread is an OS thread with its own store, sharing the memory). */
#define _COSMO_SOURCE 1
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <cosmo.h>
#include <dlfcn.h>
#include "wn-platform.h"
#include "kernels.h"
#include "native_kernels.h"

typedef struct WnEngine WnEngine; typedef struct WnInst WnInst;
typedef int32_t (*WnCb)(void *, WnInst *, uint8_t *, size_t, const uint64_t *, uint64_t *);
WnEngine *wn_engine_new(int32_t mode);
void wn_engine_free(WnEngine *);
const char *wn_engine_error(const WnEngine *);
int32_t wn_engine_define(WnEngine *, const char *module, const char *name, const char *sig, WnCb cb, void *user);
int32_t wn_engine_load(WnEngine *, const uint8_t *bytes, size_t len);
WnInst *wn_inst_new(const WnEngine *, char *err, size_t errlen);
void wn_inst_free(WnInst *);
const char *wn_inst_error(const WnInst *);
WnEngine *wn_inst_engine(const WnInst *);
void *wn_inst_user(const WnInst *);
void wn_inst_set_user(WnInst *, void *);
int32_t wn_inst_call(WnInst *, const char *name, const uint64_t *args, size_t nargs, uint64_t *res, size_t nres);
uint8_t *wn_inst_memory(WnInst *, size_t *len);
extern uint8_t wn_x28_save;
void wn_log(const uint8_t *msg, size_t len) { fwrite(msg, 1, len, stderr); fflush(stderr); }

#define CB(n) static int32_t n(void *user, WnInst *inst, uint8_t *mem, size_t memlen, const uint64_t *a, uint64_t *r)
static char g_reply[64]; static int g_reply_len;
static const char *g_gargv[32]; static int g_gargc;   /* arguments the guest sees */
/* sample:wire/transport */
CB(wire_send) { uint32_t p = (uint32_t)a[0], n = (uint32_t)a[1]; printf("host : wire.send got %u bytes: \"%.*s\"\n", n, (int)n, mem + p); g_reply_len = snprintf(g_reply, sizeof g_reply, "pong (%u)", n); r[0] = 0; return 0; }
CB(wire_recv) { uint32_t p = (uint32_t)a[0], mx = (uint32_t)a[1]; int n = g_reply_len < (int)mx ? g_reply_len : (int)mx; memcpy(mem + p, g_reply, n); r[0] = (uint64_t)n; return 0; }
/* the small slice of WASI preview 1 that wasi-libc programs need to print, take arguments and exit */
CB(h_fd_write) { uint32_t fd = (uint32_t)a[0], iovs = (uint32_t)a[1], n = (uint32_t)a[2], out = (uint32_t)a[3], total = 0;
    for (uint32_t i = 0; i < n; i++) { uint32_t p, l; memcpy(&p, mem + iovs + 8 * i, 4); memcpy(&l, mem + iovs + 8 * i + 4, 4); fwrite(mem + p, 1, l, fd == 2 ? stderr : stdout); total += l; }
    fflush(fd == 2 ? stderr : stdout); memcpy(mem + out, &total, 4); r[0] = 0; return 0; }
CB(h_clock_time_get) { struct timespec t; clock_gettime((uint32_t)a[0] == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &t); uint64_t ns = (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; memcpy(mem + (uint32_t)a[2], &ns, 8); r[0] = 0; return 0; }
CB(h_proc_exit) { fflush(stdout); fflush(stderr); exit((int)a[0]); }
CB(h_args_sizes_get) { uint32_t n = (uint32_t)g_gargc, sz = 0; for (int i = 0; i < g_gargc; i++) sz += (uint32_t)strlen(g_gargv[i]) + 1; memcpy(mem + (uint32_t)a[0], &n, 4); memcpy(mem + (uint32_t)a[1], &sz, 4); r[0] = 0; return 0; }
CB(h_args_get) { uint32_t pv = (uint32_t)a[0], pb = (uint32_t)a[1]; for (int i = 0; i < g_gargc; i++) { size_t l = strlen(g_gargv[i]) + 1; memcpy(mem + pb, g_gargv[i], l); memcpy(mem + pv + 4 * i, &pb, 4); pb += (uint32_t)l; } r[0] = 0; return 0; }
CB(zero2) { uint32_t z = 0; memcpy(mem + (uint32_t)a[0], &z, 4); memcpy(mem + (uint32_t)a[1], &z, 4); r[0] = 0; return 0; }   /* environ_sizes_get */
CB(ok2) { r[0] = 0; return 0; }                                                                                                      /* environ_get, fd_close */
CB(h_ebadf) { r[0] = 8; return 0; }                                                                                                    /* fd_prestat_get, fd_prestat_dir_name */
CB(h_enosys) { r[0] = 52; return 0; }
CB(h_fd_seek) { r[0] = 70; return 0; }
CB(h_fd_fdstat_get) { memset(mem + (uint32_t)a[1], 0, 24); mem[(uint32_t)a[1]] = 2; r[0] = 0; return 0; }
CB(h_sched_yield) { r[0] = 0; return 0; }
CB(h_random_get) { uint8_t *p = mem + (uint32_t)a[0]; uint32_t n = (uint32_t)a[1]; for (uint32_t i = 0; i < n; i++) p[i] = (uint8_t)(i * 167 + 13); r[0] = 0; return 0; }

/* ---- wasi:thread-spawn: every wasm thread is an OS thread with its own store and instance of the same module; they share the memory ---- */
static atomic_int g_tid = 1, g_live = 0, g_thread_traps = 0;
struct Spawn { WnEngine *eng; int32_t tid, arg; };
static void *spawn_main(void *p) {
    struct Spawn s = *(struct Spawn *)p; free(p);
    char err[512]; WnInst *inst = wn_inst_new(s.eng, err, sizeof err);
    if (!inst) { fprintf(stderr, "host : thread %d: instantiate failed: %s\n", s.tid, err); atomic_fetch_add(&g_thread_traps, 1); atomic_fetch_sub(&g_live, 1); return NULL; }
    uint64_t args[2] = {(uint32_t)s.tid, (uint32_t)s.arg};
    if (wn_inst_call(inst, "wasi_thread_start", args, 2, NULL, 0)) { fprintf(stderr, "host : wasm thread %d trapped (process continues): %.100s\n", s.tid, wn_inst_error(inst)); fflush(stderr); atomic_fetch_add(&g_thread_traps, 1); }
    wn_inst_free(inst); atomic_fetch_sub(&g_live, 1);
    return NULL;
}
CB(thread_spawn) {
    struct Spawn *s = malloc(sizeof *s); int32_t tid = atomic_fetch_add(&g_tid, 1); s->eng = wn_inst_engine(inst); s->tid = tid; s->arg = (int32_t)a[0];
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 8u << 20); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_t t; atomic_fetch_add(&g_live, 1);
    if (pthread_create(&t, &at, spawn_main, s)) { atomic_fetch_sub(&g_live, 1); free(s); r[0] = (uint64_t)(uint32_t)-1; return 0; }
    r[0] = (uint32_t)tid; return 0;   /* s belongs to the new thread now */
}

/* ---- stress test imports ---- */
struct TState { pthread_t self; };
static atomic_ullong g_hostcalls, g_hostbad;
static _Thread_local volatile uint64_t tl_probe;
CB(stress_mix) {
    uint32_t x = (uint32_t)a[0], y = (uint32_t)a[1];
    struct TState *ts = wn_inst_user(inst);
    tl_probe = 0xA5A5000000000000ull | x;   /* a thread-local, an errno, a malloc and the thread identity must all survive the transition wasm -> host */
    errno = (int)(x & 0x7fff) + 1;
    int e1 = errno;   /* read at once: a library call that waits on a contended lock (malloc below) is allowed to change errno, which is not what this probe is about */
    size_t sz = 16 + (y & 255); uint8_t *p = malloc(sz); memset(p, (int)y, sz);
    int bad = e1 != (int)(x & 0x7fff) + 1 || p[sz - 1] != (uint8_t)y || tl_probe != (0xA5A5000000000000ull | x) || (ts && !pthread_equal(ts->self, pthread_self()));
    free(p);
    atomic_fetch_add(&g_hostcalls, 1); if (bad) atomic_fetch_add(&g_hostbad, 1);
    r[0] = wn_mix(x, y); return 0;
}

static uint8_t *read_all(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(len); if (fread(b, 1, len, f) != (size_t)len) { fclose(f); free(b); return NULL; } fclose(f); *n = len; return b;
}
/* Windows on ARM runs the x86-64 half of the file under emulation. Measured there (kernels, same machine): modules compiled for AVX2/FMA are 14% slower on matmul and 30% slower on n-body than the baseline ones,
 * so the baseline module is chosen when the machine is ARM64. IsWow64Process2 reports the native machine type. */
static int under_arm_emulation(void) {
    if (!IsWindows()) return 0;
    void *k = cosmo_dlopen("kernel32.dll", RTLD_NOW); if (!k) return 0;
    typedef int (__attribute__((ms_abi)) *w2_t)(void *, unsigned short *, unsigned short *);
    w2_t f = (w2_t)cosmo_dlsym(k, "IsWow64Process2"); if (!f) return 0;
    unsigned short proc = 0, native = 0; if (!f((void *)(intptr_t)-1, &proc, &native)) return 0;
    return native == 0xAA64;
}
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

/* ---- native kernels offered to wasm as imports (instruction set chosen at start-up, see native_kernels.h) ---- */
#define NK_OK(p, bytes) ((uint64_t)(uint32_t)(p) + (uint64_t)(bytes) <= (uint64_t)memlen)
CB(nk_cb_level) { (void)a; r[0] = (uint64_t)nk_level(); return 0; }
CB(nk_cb_saxpy) { uint32_t n = (uint32_t)a[0], x = (uint32_t)a[2], y = (uint32_t)a[3]; float al; uint32_t ab = (uint32_t)a[1]; memcpy(&al, &ab, 4);
    if (!NK_OK(x, 4ull * n) || !NK_OK(y, 4ull * n)) { fprintf(stderr, "host : saxpy_f32 out of bounds: n=%u x=%u y=%u memory=%zu\n", n, x, y, memlen); return 1; } nk_saxpy(n, al, (const float *)(mem + x), (float *)(mem + y)); return 0; }
CB(nk_cb_dot) { uint32_t n = (uint32_t)a[0], x = (uint32_t)a[1], y = (uint32_t)a[2];
    if (!NK_OK(x, 4ull * n) || !NK_OK(y, 4ull * n)) { fprintf(stderr, "host : dot_f32 out of bounds: n=%u x=%u y=%u memory=%zu\n", n, x, y, memlen); return 1; } float d = nk_dot(n, (const float *)(mem + x), (const float *)(mem + y)); uint32_t b; memcpy(&b, &d, 4); r[0] = b; return 0; }
CB(nk_cb_matmul) { uint32_t m = (uint32_t)a[0], n = (uint32_t)a[1], k = (uint32_t)a[2], A = (uint32_t)a[3], B = (uint32_t)a[4], C = (uint32_t)a[5];
    if (!NK_OK(A, 4ull * m * k) || !NK_OK(B, 4ull * k * n) || !NK_OK(C, 4ull * m * n)) { fprintf(stderr, "host : matmul_f32 out of bounds: m=%u n=%u k=%u A=%u B=%u C=%u memory=%zu\n", m, n, k, A, B, C, memlen); return 1; } nk_matmul(m, n, k, (const float *)(mem + A), (const float *)(mem + B), (float *)(mem + C)); return 0; }

static int define_all(WnEngine *e, int wt) {
    const char *W = "wasi_snapshot_preview1"; int rc = 0;
#define D(m, n, sg, cb) rc |= wn_engine_define(e, m, n, sg, cb, 0)
    D("sample:wire/transport@0.1.0", "send", "ii>i", wire_send); D("sample:wire/transport@0.1.0", "recv", "ii>i", wire_recv);
    D("stress", "mix", "ii>i", stress_mix);
    D("native", "cpu_level", ">i", nk_cb_level); D("native", "saxpy_f32", "ifii>", nk_cb_saxpy); D("native", "dot_f32", "iii>f", nk_cb_dot); D("native", "matmul_f32", "iiiiii>", nk_cb_matmul);
    D(W, "fd_write", "iiii>i", h_fd_write); D(W, "clock_time_get", "ili>i", h_clock_time_get); D(W, "proc_exit", "i", h_proc_exit);
    D(W, "args_sizes_get", "ii>i", h_args_sizes_get); D(W, "args_get", "ii>i", h_args_get); D(W, "environ_sizes_get", "ii>i", zero2); D(W, "environ_get", "ii>i", ok2);
    D(W, "fd_close", "i>i", ok2); D(W, "fd_prestat_get", "ii>i", h_ebadf); D(W, "fd_prestat_dir_name", "iii>i", h_ebadf);
    D(W, "fd_seek", "ilii>i", h_fd_seek); D(W, "fd_fdstat_get", "ii>i", h_fd_fdstat_get);
    D(W, "sched_yield", ">i", h_sched_yield); D(W, "random_get", "ii>i", h_random_get); D(W, "fd_read", "iiii>i", h_enosys); D(W, "poll_oneoff", "iiii>i", h_enosys); D(W, "clock_res_get", "ii>i", h_enosys);
    if (wt) D("wasi", "thread-spawn", "i>i", thread_spawn);
#undef D
    return rc;
}
static WnEngine *make_engine(int m, int wt, const uint8_t *bytes, size_t len) {
    WnEngine *e = wn_engine_new(m | (wt ? 0x10 : 0)); if (!e) { fprintf(stderr, "init failed\n"); return NULL; }
    if (define_all(e, wt)) { fprintf(stderr, "define failed: %s\n", wn_engine_error(e)); return NULL; }
    if (wn_engine_load(e, bytes, len)) { fprintf(stderr, "load failed: %s\n", wn_engine_error(e)); return NULL; }
    return e;
}

/* ---- stress ---- */
static uint64_t g_exp_compute[8]; static uint32_t g_exp_mix[8];
#define COMPUTE_ITERS 1500
#define MIX_N 40
struct StressT { int id, mode, wt; double seconds; WnEngine *eng; const uint8_t *bytes; size_t len; int priv;
    uint64_t iters, kind[7], faultchecks; int failed; char msg[600]; };
static const char *kind_name[7] = {"oob", "div0", "unreach", "recurse", "oob2", "oob3", "grow"};
static const char *kind_trap[7] = {"MemoryOutOfBounds", "IntegerDivisionByZero", "UnreachableCodeReached", "StackOverflow", "MemoryOutOfBounds", "MemoryOutOfBounds", ""};
#define FAIL(...) do { snprintf(t->msg, sizeof t->msg, __VA_ARGS__); t->failed = 1; goto done; } while (0)
static void *stress_thread(void *p) {
    struct StressT *t = p; WnEngine *eng = t->eng; WnInst *inst = NULL; char err[512]; struct TState ts; ts.self = pthread_self();
    if (t->priv) { eng = make_engine(t->mode, t->wt, t->bytes, t->len); if (!eng) FAIL("private engine failed"); }
    double end = now_ms() + t->seconds * 1000;
    for (uint64_t it = 0; now_ms() < end || it < 21; it++) {
        if (!inst || it % 48 == 0) {
            if (inst) wn_inst_free(inst);
            inst = wn_inst_new(eng, err, sizeof err); if (!inst) FAIL("instantiate: %.300s", err);
            wn_inst_set_user(inst, &ts);
        }
        uint32_t seed = (uint32_t)((t->id * 5 + it) % 8); uint64_t args[2] = {seed, COMPUTE_ITERS}, res[2] = {0, 0};
        if (wn_inst_call(inst, "compute", args, 2, res, 1)) FAIL("compute call failed: %.300s", wn_inst_error(inst));
        if (res[0] != g_exp_compute[seed]) FAIL("compute(%u) = %llx, expected %llx", seed, (unsigned long long)res[0], (unsigned long long)g_exp_compute[seed]);
        args[1] = MIX_N; res[0] = 0;
        if (wn_inst_call(inst, "hostmix", args, 2, res, 1)) FAIL("hostmix call failed: %.300s", wn_inst_error(inst));
        if ((uint32_t)res[0] != g_exp_mix[seed]) FAIL("hostmix(%u) = %x, expected %x", seed, (unsigned)res[0], g_exp_mix[seed]);
        int k = (int)(it % 7); t->kind[k]++;
        if (k == 6) {
            args[0] = 3; res[0] = 0;
            if (wn_inst_call(inst, "grow", args, 1, res, 1)) FAIL("grow call failed: %.300s", wn_inst_error(inst));
            if ((uint32_t)res[0] != 3003) FAIL("grow(3) = %u, expected 3003", (unsigned)res[0]);
        } else {
            uint64_t a1[1] = {1};
            int rc = wn_inst_call(inst, kind_name[k], a1, 1, res, 1);
            if (!rc) FAIL("%s returned instead of trapping", kind_name[k]);
            const char *e = wn_inst_error(inst);
            if (!strstr(e, kind_trap[k])) FAIL("%s: wrong trap, expected %s, got %.300s", kind_name[k], kind_trap[k], e);
            if (t->mode == 0 && (k == 0 || k == 4)) {   /* signals mode: the address Wasmtime was given must be base + the wasm address */
                size_t ml = 0; uint8_t *base = wn_inst_memory(inst, &ml); const struct WnFault *f = wn_last_fault();
                uintptr_t want = (uintptr_t)base + (k == 0 ? 0xFFFFFFF0ull : 0x100000040ull);
                if (!f->has_addr || f->addr != want) FAIL("%s: fault address %p (has_addr %d, source %d), expected %p", kind_name[k], (void *)f->addr, f->has_addr, f->source, (void *)want);
                if (!strstr(e, k == 0 ? "wasm address 0xfffffff0" : "wasm address 0x100000040")) FAIL("%s: error text lacks the wasm address: %.300s", kind_name[k], e);
                t->faultchecks++;
            }
            res[0] = 0;
            if (wn_inst_call(inst, "ok", NULL, 0, res, 1)) FAIL("ok after %s failed: %.300s", kind_name[k], wn_inst_error(inst));
            if ((int)res[0] != 42) FAIL("ok after %s returned %d", kind_name[k], (int)res[0]);
        }
        t->iters++;
    }
done:
    if (inst) wn_inst_free(inst);
    if (t->priv && eng) wn_engine_free(eng);
    return NULL;
}
static int run_stress(int mode, const uint8_t *bytes, size_t len, int nthreads, double seconds, int priv) {
    for (int s = 0; s < 8; s++) { g_exp_compute[s] = wn_compute((uint32_t)s, COMPUTE_ITERS); uint32_t r = (uint32_t)s; for (uint32_t i = 0; i < MIX_N; i++) r = wn_mix(r, i); g_exp_mix[s] = r; }
    WnEngine *shared = NULL; if (!priv) { shared = make_engine(mode, 0, bytes, len); if (!shared) return 1; }
    struct StressT *ts = calloc(nthreads, sizeof *ts); pthread_t *th = calloc(nthreads, sizeof *th);
    double t0 = now_ms();
    for (int i = 0; i < nthreads; i++) {
        ts[i] = (struct StressT){.id = i, .mode = mode, .seconds = seconds, .eng = shared, .bytes = bytes, .len = len, .priv = priv};
        pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 8u << 20);
        if (pthread_create(&th[i], &at, stress_thread, &ts[i])) { printf("host : pthread_create failed\n"); return 1; }
    }
    for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
    uint64_t iters = 0, fc = 0, kinds[7] = {0}; int failed = 0;
    for (int i = 0; i < nthreads; i++) {
        iters += ts[i].iters; fc += ts[i].faultchecks; for (int k = 0; k < 7; k++) kinds[k] += ts[i].kind[k];
        if (ts[i].failed) { failed++; printf("host : thread %d FAILED after %llu iterations: %s\n", i, (unsigned long long)ts[i].iters, ts[i].msg); }
    }
    uint64_t hb = atomic_load(&g_hostbad);
    printf("STRESS mode=%s engine=%s threads=%d seconds=%.1f x28=%s iterations=%llu hostcalls=%llu bad_hostcalls=%llu traps{oob=%llu div0=%llu unreach=%llu stack_overflow=%llu oob_guard=%llu oob_end=%llu} grow_calls=%llu fault_address_checks=%llu failed_threads=%d -> %s\n",
           mode == 0 ? "sig" : mode == 1 ? "nosig" : "pulley", priv ? "private-per-thread" : "shared", nthreads, (now_ms() - t0) / 1000, wn_x28_save ? "save/restore workaround" : "none needed",
           (unsigned long long)iters, (unsigned long long)atomic_load(&g_hostcalls), (unsigned long long)hb,
           (unsigned long long)kinds[0], (unsigned long long)kinds[1], (unsigned long long)kinds[2], (unsigned long long)kinds[3], (unsigned long long)kinds[4], (unsigned long long)kinds[5], (unsigned long long)kinds[6], (unsigned long long)fc,
           failed, failed == 0 && hb == 0 ? "PASS" : "FAIL");
    return failed || hb ? 1 : 0;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s sig|nosig|pulley <guest-base> [--invoke=name] [--stress --threads=N --seconds=S --engine=shared|private] [-- guest args]\n", argv[0]); return 64; }
    const char *mode = argv[1], *base = argv[2], *entry = "_start";
    int stress = 0, nthreads = 4, priv = 0, expect_fault = 0, wt = !strcmp(base, "par"); double seconds = 3;
    g_gargv[g_gargc++] = base;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { for (i++; i < argc && g_gargc < 31; i++) g_gargv[g_gargc++] = argv[i]; break; }
        if (!strncmp(argv[i], "--invoke=", 9)) entry = argv[i] + 9;
        else if (!strcmp(argv[i], "--stress")) stress = 1;
        else if (!strncmp(argv[i], "--threads=", 10)) nthreads = atoi(argv[i] + 10);
        else if (!strncmp(argv[i], "--seconds=", 10)) seconds = atof(argv[i] + 10);
        else if (!strncmp(argv[i], "--engine=", 9)) priv = !strcmp(argv[i] + 9, "private");
        else if (!strcmp(argv[i], "--expect-fault")) expect_fault = 1;
        else if (!strcmp(argv[i], "--wt")) wt = 1;
    }
    if (getenv("WN_X28") && !strcmp(getenv("WN_X28"), "save")) wn_x28_save = 1;
    int m = !strcmp(mode, "sig") ? 0 : !strcmp(mode, "nosig") ? 1 : 2;
    const char *arch = IsAarch64() ? "aarch64" : "x86_64";
    char path[512], alt[512], envp[1024], name[256];
    nk_init();
    /* which precompiled variant: on x86-64 the module compiled for the AVX2/FMA/BMI level when this CPU and OS have all of it, else the baseline one (WN_CWASM_LEVEL=base forces the baseline) */
    const char *lvl = ""; const char *lenv = getenv("WN_CWASM_LEVEL");
    if (!IsAarch64() && m != 2 && !(lenv && !strcmp(lenv, "base")) && nk_haswell_ok() && (!under_arm_emulation() || (lenv && !strcmp(lenv, "v3")))) lvl = ".v3";   /* WN_CWASM_LEVEL=v3 forces it under emulation (for measuring) */
    if (m == 2) snprintf(name, sizeof name, "%s.pulley.cwasm", base); else snprintf(name, sizeof name, "%s.%s.%s%s.cwasm", base, mode, arch, lvl);
    snprintf(path, sizeof path, "/zip/%s", name); snprintf(alt, sizeof alt, "%s", name);
    size_t len = 0; uint8_t *bytes = NULL;
    if (getenv("WN_CWASM_DIR")) { snprintf(envp, sizeof envp, "%s/%s", getenv("WN_CWASM_DIR"), name); bytes = read_all(envp, &len); if (bytes) printf("host : using %s\n", envp); }   /* e.g. the baseline built by the stock compiler */
    if (!bytes) bytes = read_all(path, &len);
    if (!bytes) bytes = read_all(alt, &len);
    if (!bytes && *lvl) {   /* no variant for this level in the file: the baseline one */
        lvl = ""; snprintf(name, sizeof name, "%s.%s.%s.cwasm", base, mode, arch); snprintf(path, sizeof path, "/zip/%s", name); snprintf(alt, sizeof alt, "%s", name);
        bytes = read_all(path, &len); if (!bytes) bytes = read_all(alt, &len);
    }
    if (!bytes) { fprintf(stderr, "cannot read %s or %s\n", path, alt); return 65; }
    if (*lvl) {   /* the CPU check above and the engine's own check of the module's compile settings must agree; if the engine refuses the v3 module, fall back to the baseline one instead of failing to start */
        WnEngine *probe = make_engine(m, wt, bytes, len);
        if (probe) wn_engine_free(probe);
        else {
            fprintf(stderr, "host : the v3 module was refused by the engine, using the baseline module\n");
            free(bytes); bytes = NULL; lvl = "";
            snprintf(name, sizeof name, "%s.%s.%s.cwasm", base, mode, arch); snprintf(path, sizeof path, "/zip/%s", name); snprintf(alt, sizeof alt, "%s", name);
            bytes = read_all(path, &len); if (!bytes) bytes = read_all(alt, &len);
            if (!bytes) { fprintf(stderr, "cannot read %s or %s\n", path, alt); return 65; }
        }
    }
    printf("host : platform=%s arch=%s mode=%s guest=%s (%zu bytes)\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", arch, mode, base, len); fflush(stdout);
    printf("host : module level: %s; native kernels: %s\n", *lvl ? "x86-64 AVX2/FMA/BMI (v3)" : IsAarch64() ? "arm64 baseline" : "x86-64 baseline", nk_level_name()); fflush(stdout);
    if (stress) return run_stress(m, bytes, len, nthreads, seconds, priv);
    double t0 = now_ms();
    WnEngine *eng = make_engine(m, wt, bytes, len); if (!eng) return 66;
    double t1 = now_ms();
    char err[512]; WnInst *inst = wn_inst_new(eng, err, sizeof err);
    if (!inst) { fprintf(stderr, "instantiate failed: %s\n", err); return 69; }
    double t2 = now_ms(); size_t memlen = 0; uint8_t *membase = wn_inst_memory(inst, &memlen);
    printf("host : engine+load %.1f ms, instantiate %.1f ms, linear memory %zu MiB\n", t1 - t0, t2 - t1, memlen >> 20); fflush(stdout);
    uint64_t res[2] = {0, 0}; int bad = 0;
    if (strchr(entry, ',') || expect_fault) {   /* a list of exports, called in order in the same instance */
        char list[256]; snprintf(list, sizeof list, "%s", entry);
        for (char *tok = strtok(list, ","); tok; tok = strtok(NULL, ",")) {
            res[0] = 0; uint64_t a1[1] = {1};
            if (wn_inst_call(inst, tok, a1, 1, res, 1)) {
                printf("host : %s trapped: %.220s\n", tok, wn_inst_error(inst));
                const struct WnFault *f = wn_last_fault();
                if (m == 0 && f->signo) {
                    printf("host : %s fault record: signal %d ip %p si_addr %p address given to Wasmtime %p (has_addr %d, source %s)\n", tok, f->signo, (void *)f->ip, (void *)f->si_addr, (void *)f->addr, f->has_addr, f->source == 1 ? "windows exception record" : f->source == 2 ? "unknown" : "si_addr");
                    if (expect_fault && (!strcmp(tok, "oob") || !strcmp(tok, "oob2") || !strcmp(tok, "oob3"))) {
                        uint64_t want_wasm = !strcmp(tok, "oob") ? 0xFFFFFFF0ull : !strcmp(tok, "oob2") ? 0x100000040ull : (uint64_t)memlen;
                        char needle[64]; snprintf(needle, sizeof needle, "wasm address 0x%llx", (unsigned long long)want_wasm);
                        int addr_ok = f->has_addr && f->addr == (uintptr_t)membase + want_wasm, text_ok = strstr(wn_inst_error(inst), needle) != NULL;
                        printf("FAULTADDR %s: expected memory base %p + 0x%llx = %p, got %p; Wasmtime error names the wasm address: %s -> %s\n", tok, (void *)membase, (unsigned long long)want_wasm, (void *)((uintptr_t)membase + want_wasm), (void *)f->addr, text_ok ? "yes" : "no", addr_ok && text_ok ? "PASS" : "FAIL");
                        if (!(addr_ok && text_ok)) bad = 1;
                    }
                }
            } else printf("host : %s -> %d\n", tok, (int)res[0]);
            fflush(stdout);
        }
        return bad;
    }
    if (wn_inst_call(inst, entry, NULL, 0, res, 1)) { fprintf(stderr, "call failed: %s\n", wn_inst_error(inst)); return 70; }
    for (int i = 0; i < 500 && atomic_load(&g_live) > 0; i++) { struct timespec ts = {0, 10 * 1000 * 1000}; nanosleep(&ts, NULL); }
    printf("host : %s returned (wasm thread traps: %d)\n", entry, atomic_load(&g_thread_traps));
    return 0;
}
