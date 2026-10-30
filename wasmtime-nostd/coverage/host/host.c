/* Coverage host: a Cosmopolitan program that runs precompiled .cwasm (core modules) or components through the statically linked no_std Wasmtime.
 * usage: wnc.com <sig|nosig|pulley> <name> [options] [-- guest args]     loads /zip/<name>.<mode>.<arch>.cwasm (pulley: <name>.pulley.cwasm) or the same name in the current directory
 *   --p1                         provide wasi_snapshot_preview1 (all of it, wasi_p1.c)
 *   --dir=GUEST::HOST | --dir=H  pre-open a directory         --env=K=V    set an environment variable for the guest
 *   --tcplisten=IP:PORT          pre-opened listening socket   --selfclient run a client thread that talks to it and reports what it received
 *   --run-tests                  call every export named t_* (must return 1) and x_* (must trap) in one instance
 *   --call=name[:arg]            call one export with an i64 argument and time it       --invoke=a,b,c  call exports in order (like the first host)
 *   --async                      async store (fibers): host function env.yield_n(n) suspends n times

 *   --argv0=NAME                 program name the guest sees
 *   --plain-await                env.await_host as an ordinary synchronous host function (baseline for --asyncify)
 *   --asyncify=entry:data:size   drive an asyncify-instrumented module        --collector=drc|null|copying
 *   --component                  the file is a component (needs the component / p2 build) */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <cosmo.h>
#include "wasi_p1.h"

int32_t wn_init_ex(int32_t mode, int32_t collector);
int32_t wn_define(const char *module, const char *name, const char *sig, int32_t (*cb)(void *, uint8_t *, size_t, const uint64_t *, uint64_t *), void *user);
int32_t wn_load(const uint8_t *bytes, size_t len);
int32_t wn_instantiate(void);
int32_t wn_call(const char *name, const uint64_t *args, size_t nargs, uint64_t *res, size_t nres);
const char *wn_last_error(void);
size_t wn_memory_size(void);
int32_t wn_features(void);
void wn_set_async(int on);
uint64_t wn_pending_polls(void);
int32_t wn_define_yield(const char *module, const char *name);
size_t wn_list_exports(uint8_t *buf, size_t cap);
int32_t wn_define_asyncify(const char *module, const char *name, int32_t (*cb)(void *, int32_t), void *user);
int32_t wn_asyncify_run(const char *entry, uint32_t data, uint32_t size, int32_t *res, uint64_t *unwinds);
#if defined(WN_CM) || defined(WN_P2)
int32_t wn_cm_load(const uint8_t *bytes, size_t len);
int32_t wn_cm_selftest(void);
#endif
#ifdef WN_P2
int32_t wn_p2_run(int argc, char **argv, int *exit_code);
void wn_p2_add_env(const char *k, const char *v);
#endif

void wn_log(const uint8_t *msg, size_t len) { fwrite(msg, 1, len, stderr); fflush(stderr); }
void wn_idle(void) { struct timespec t = { 0, 100000 }; nanosleep(&t, NULL); }

static uint8_t *read_all(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(len ? len : 1); if (fread(b, 1, len, f) != (size_t)len) { fclose(f); free(b); return NULL; } fclose(f); *n = len; return b;
}
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

/* ---- the client thread for the socket test ---- */
static int g_cl_port; static char g_cl_result[512]; static pthread_t g_cl_th; static int g_cl_on;
static void *client_main(void *p) {
    (void)p; int s = -1;
    for (int tries = 0; tries < 100; tries++) {
        s = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in sa; memset(&sa, 0, sizeof sa); sa.sin_family = AF_INET; sa.sin_port = htons((uint16_t)g_cl_port); inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
        if (connect(s, (struct sockaddr *)&sa, sizeof sa) == 0) break;
        close(s); s = -1; struct timespec t = { 0, 20000000 }; nanosleep(&t, NULL);
    }
    if (s < 0) { snprintf(g_cl_result, sizeof g_cl_result, "client could not connect"); return NULL; }
    const char *msg = "ping from client"; send(s, msg, strlen(msg), 0); shutdown(s, SHUT_WR);
    size_t n = 0; for (;;) { ssize_t g = recv(s, g_cl_result + n, sizeof g_cl_result - 1 - n, 0); if (g <= 0) break; n += (size_t)g; }
    g_cl_result[n] = 0; close(s); return NULL;
}

static int32_t sync_nop(void *u, uint8_t *mem, size_t memlen, const uint64_t *a, uint64_t *r) { (void)u; (void)mem; (void)memlen; (void)a; (void)r; return 0; }

/* ---- asyncify host work between unwind and rewind: a trivial computation standing in for completed I/O ---- */
static int32_t asy_work(void *u, int32_t req) { (void)u; return req * 2 + 1; }
static int32_t plain_await(void *u, uint8_t *mem, size_t memlen, const uint64_t *a, uint64_t *r) { (void)u; (void)mem; (void)memlen; r[0] = (uint32_t)((int32_t)a[0] * 2 + 1); return 0; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s sig|nosig|pulley <name> [options] [-- guest args]\n", argv[0]); return 64; }
    const char *mode = argv[1], *base = argv[2];
    int m = !strcmp(mode, "sig") ? 0 : !strcmp(mode, "nosig") ? 1 : 2;
    int plain_await_mode = 0, use_p1 = 0, run_tests = 0, use_async = 0, component = 0, collector = 0, selfclient = 0;
    const char *invoke = NULL, *asyncify = NULL; const char *calls[16]; int ncalls = 0;
    const char *dirs[8]; int ndirs = 0; const char *envs[64]; int nenvs = 0; const char *listen_spec = NULL;
    int gargc = 0; char *gargv[64]; gargv[gargc++] = (char *)base;
    for (int i = 3; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--")) { for (i++; i < argc && gargc < 63; i++) gargv[gargc++] = argv[i]; break; }
        else if (!strcmp(a, "--p1")) use_p1 = 1;
        else if (!strcmp(a, "--run-tests")) run_tests = 1;
        else if (!strcmp(a, "--async")) use_async = 1;
        else if (!strcmp(a, "--component")) component = 1;
        else if (!strcmp(a, "--selfclient")) selfclient = 1;
        else if (!strcmp(a, "--plain-await")) plain_await_mode = 1;
        else if (!strncmp(a, "--argv0=", 8)) gargv[0] = (char *)(a + 8);
        else if (!strncmp(a, "--invoke=", 9)) invoke = a + 9;
        else if (!strncmp(a, "--call=", 7) && ncalls < 16) calls[ncalls++] = a + 7;
        else if (!strncmp(a, "--asyncify=", 11)) asyncify = a + 11;
        else if (!strncmp(a, "--dir=", 6) && ndirs < 8) dirs[ndirs++] = a + 6;
        else if (!strncmp(a, "--env=", 6) && nenvs < 64) envs[nenvs++] = a + 6;
        else if (!strncmp(a, "--tcplisten=", 12)) listen_spec = a + 12;
        else if (!strncmp(a, "--collector=", 12)) collector = !strcmp(a + 12, "drc") ? 1 : !strcmp(a + 12, "null") ? 2 : 3;
        else { fprintf(stderr, "unknown option %s\n", a); return 64; }
    }
    const char *arch = IsAarch64() ? "aarch64" : "x86_64";
    const char *plat = IsWindows() ? "windows" : IsXnu() ? "macos" : "linux";
    char path[512], alt[512];
    if (m == 2) snprintf(path, sizeof path, "/zip/%s.pulley.cwasm", base), snprintf(alt, sizeof alt, "%s.pulley.cwasm", base);
    else snprintf(path, sizeof path, "/zip/%s.%s.%s.cwasm", base, mode, arch), snprintf(alt, sizeof alt, "%s.%s.%s.cwasm", base, mode, arch);
    size_t len = 0; uint8_t *bytes = read_all(path, &len); if (!bytes) bytes = read_all(alt, &len);
    if (!bytes) { fprintf(stderr, "cannot read %s or %s\n", path, alt); return 65; }
    printf("host : platform=%s arch=%s mode=%s name=%s (%zu bytes) features=0x%x\n", plat, arch, mode, base, len, wn_features()); fflush(stdout);
    double t0 = now_ms();
    if (wn_init_ex(m, collector)) { fprintf(stderr, "init failed\n"); return 66; }
    int rc = 0;
    if (use_async) wn_set_async(1);
    if (!component) {
        if (use_p1) {
            for (int i = 0; i < ndirs; i++) {
                char spec[600]; snprintf(spec, sizeof spec, "%s", dirs[i]); char *sep = strstr(spec, "::"); const char *guest = spec, *host = spec;
                if (sep) { *sep = 0; host = sep + 2; }
                if (wasi_add_preopen(guest, host)) { fprintf(stderr, "cannot pre-open %s\n", dirs[i]); return 71; }
            }
            for (int i = 0; i < nenvs; i++) wasi_add_env(envs[i]);
            if (listen_spec) {
                char spec[128]; snprintf(spec, sizeof spec, "%s", listen_spec); char *c = strchr(spec, ':'); int bound = 0;
                if (!c) return 64; *c = 0;
                if (wasi_add_tcp_listen(spec, atoi(c + 1), &bound)) { fprintf(stderr, "cannot listen on %s\n", listen_spec); return 71; }
                char kv[64]; snprintf(kv, sizeof kv, "LISTEN_FD=%d", wasi_listen_fd()); wasi_add_env(kv);
                printf("host : listening on %s:%d as guest fd %d\n", spec, bound, wasi_listen_fd()); fflush(stdout);
                if (selfclient) { g_cl_port = bound; g_cl_on = !pthread_create(&g_cl_th, NULL, client_main, NULL); }
            }
            wasi_set_args(gargc, gargv);
            rc |= wasi_p1_register();
        }
        if (use_async) { rc |= wn_define_yield("env", "yield_n"); rc |= wn_define("env", "sync_nop", "i", sync_nop, 0); }
        if (asyncify) rc |= wn_define_asyncify("env", "await_host", asy_work, 0);
        if (plain_await_mode) rc |= wn_define("env", "await_host", "i>i", plain_await, 0);
        if (rc) { fprintf(stderr, "define failed: %s\n", wn_last_error()); return 67; }
        if (wn_load(bytes, len)) { fprintf(stderr, "load failed: %s\n", wn_last_error()); return 68; }
        double t1 = now_ms();
        if (wn_instantiate()) { fprintf(stderr, "instantiate failed: %s\n", wn_last_error()); return 69; }
        double t2 = now_ms();
        printf("host : engine+load %.1f ms, instantiate %.1f ms, linear memory %zu MiB\n", t1 - t0, t2 - t1, wn_memory_size() >> 20); fflush(stdout);
        uint64_t res[2] = {0, 0};
        if (run_tests || ncalls || asyncify || invoke) { uint64_t tmp = 0; wn_call("_initialize", NULL, 0, &tmp, 0); }   /* reactor modules */
        if (run_tests) {
            static uint8_t names[16384]; size_t need = wn_list_exports(names, sizeof names - 1); if (need >= sizeof names) need = sizeof names - 1; names[need] = 0;
            int pass = 0, fail = 0, total = 0;
            for (char *p = (char *)names; *p;) {
                char *nl = strchr(p, '\n'); if (!nl) break; *nl = 0;
                int want_trap = !strncmp(p, "x_", 2), is_test = want_trap || !strncmp(p, "t_", 2);
                if (is_test) {
                    total++; res[0] = 0; int r = wn_call(p, NULL, 0, res, 1);
                    if (want_trap) { if (r) { printf("PASS %s (trapped as required: %.70s)\n", p, wn_last_error()); pass++; } else { printf("FAIL %s did not trap (returned %d)\n", p, (int)res[0]); fail++; } }
                    else if (r) { printf("FAIL %s trapped: %.150s\n", p, wn_last_error()); fail++; }
                    else if ((int)res[0] == 1) { printf("PASS %s\n", p); pass++; }
                    else { printf("FAIL %s returned %d\n", p, (int)res[0]); fail++; }
                    fflush(stdout);
                }
                p = nl + 1;
            }
            printf("SUMMARY tests=%d pass=%d fail=%d\n", total, pass, fail); fflush(stdout);
            return fail ? 1 : 0;
        }
        for (int i = 0; i < ncalls; i++) {
            char spec[128]; snprintf(spec, sizeof spec, "%s", calls[i]); char *c = strchr(spec, ':'); uint64_t arg = 0; if (c) { *c = 0; arg = strtoull(c + 1, NULL, 10); }
            uint64_t before = wn_pending_polls(); double s = now_ms(); int r = wn_call(spec, &arg, 1, res, 1); double e = now_ms();
            if (r) { printf("CALL %s(%llu) trapped: %.150s\n", spec, (unsigned long long)arg, wn_last_error()); }
            else printf("CALL %s(%llu) -> %lld in %.3f ms, suspensions %llu\n", spec, (unsigned long long)arg, (long long)(int64_t)res[0], e - s, (unsigned long long)(wn_pending_polls() - before));
            fflush(stdout);
        }
        if (asyncify) {
            char spec[160]; snprintf(spec, sizeof spec, "%s", asyncify); char *d = strchr(spec, ':'); char *z = d ? strchr(d + 1, ':') : NULL; if (!z) return 64; *d = 0; *z = 0;
            uint64_t dataaddr = 0; if (wn_call(d + 1, NULL, 0, &dataaddr, 1)) { fprintf(stderr, "no %s: %s\n", d + 1, wn_last_error()); return 70; }
            int32_t out = 0; uint64_t unw = 0; double s = now_ms();
            if (wn_asyncify_run(spec, (uint32_t)dataaddr, (uint32_t)atoi(z + 1), &out, &unw)) { printf("ASYNCIFY %s failed: %.200s\n", spec, wn_last_error()); return 1; }
            printf("ASYNCIFY %s -> %d, unwinds %llu in %.3f ms\n", spec, out, (unsigned long long)unw, now_ms() - s); fflush(stdout);
        }
        if (invoke) {
            char list[256]; snprintf(list, sizeof list, "%s", invoke);
            for (char *tok = strtok(list, ","); tok; tok = strtok(NULL, ",")) {
                res[0] = 0;
                if (wn_call(tok, NULL, 0, res, 1)) { if (!strcmp(tok, "_start") && strstr(wn_last_error(), "exit")) { } printf("host : %s trapped: %.120s\n", tok, wn_last_error()); }
                else printf("host : %s -> %d\n", tok, (int)res[0]);
                fflush(stdout);
            }
        }
        if (!run_tests && !ncalls && !asyncify && !invoke) {
            if (wn_call("_start", NULL, 0, res, 0)) { fflush(stdout); fprintf(stderr, "_start failed: %s\n", wn_last_error()); return 70; }
            fflush(stdout);
        }
        if (g_cl_on) { pthread_join(g_cl_th, NULL); printf("host : selfclient received: \"%s\"\n", g_cl_result); }
        return 0;
    }
#if defined(WN_CM) || defined(WN_P2)
    for (int i = 0; i < ndirs; i++) {
        char spec[600]; snprintf(spec, sizeof spec, "%s", dirs[i]); char *sep = strstr(spec, "::"); const char *guest = spec, *host = spec;
        if (sep) { *sep = 0; host = sep + 2; }
        if (wasi_add_preopen(guest, host)) { fprintf(stderr, "cannot pre-open %s\n", dirs[i]); return 71; }
    }
#ifdef WN_P2
    for (int i = 0; i < nenvs; i++) { char kv[300]; snprintf(kv, sizeof kv, "%s", envs[i]); char *e = strchr(kv, '='); if (e) { *e = 0; wn_p2_add_env(kv, e + 1); } }
#endif
    if (wn_cm_load(bytes, len)) { fprintf(stderr, "component load failed: %s\n", wn_last_error()); return 68; }
    printf("host : component loaded in %.1f ms\n", now_ms() - t0); fflush(stdout);
    if (run_tests) { int r = wn_cm_selftest(); fflush(stdout); if (r) printf("component selftest failed: %s\n", wn_last_error()); return r ? 1 : 0; }
#ifdef WN_P2
    int code = 0; double s = now_ms();
    if (wn_p2_run(gargc, gargv, &code)) { fflush(stdout); fprintf(stderr, "run failed: %s\n", wn_last_error()); return 70; }
    fflush(stdout); fprintf(stderr, "host : component finished in %.1f ms, exit code %d, suspensions %llu\n", now_ms() - s, code, (unsigned long long)wn_pending_polls());
    return code;
#else
    fprintf(stderr, "this build has the component model but no WASI preview 2 host\n"); return 72;
#endif
#else
    fprintf(stderr, "this build has no component support\n"); return 72;
#endif
}
