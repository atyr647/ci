/* Test host: Cosmopolitan program that runs a precompiled .cwasm through the statically linked no_std Wasmtime.
 * usage: wn.com <mode: sig|nosig|pulley> <guest-base> [--invoke=<export>] ...   loads /zip/<guest-base>.<mode>.<arch>.cwasm (pulley: <guest-base>.pulley.cwasm), or the same name in the current directory. */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <cosmo.h>

int32_t wn_init(int32_t mode);
int32_t wn_define(const char *module, const char *name, const char *sig, int32_t (*cb)(void *, uint8_t *, size_t, const uint64_t *, uint64_t *), void *user);
int32_t wn_load(const uint8_t *bytes, size_t len);
int32_t wn_instantiate(void);
int32_t wn_call(const char *name, const uint64_t *args, size_t nargs, uint64_t *res, size_t nres);
const char *wn_last_error(void);
size_t wn_memory_size(void);
void wn_log(const uint8_t *msg, size_t len) { fwrite(msg, 1, len, stderr); fflush(stderr); }

#define CB(n) static int32_t n(void *user, uint8_t *mem, size_t memlen, const uint64_t *a, uint64_t *r)
static char g_reply[64]; static int g_reply_len;
/* sample:wire/transport */
CB(wire_send) { uint32_t p = (uint32_t)a[0], n = (uint32_t)a[1]; printf("host : wire.send got %u bytes: \"%.*s\"\n", n, (int)n, mem + p); g_reply_len = snprintf(g_reply, sizeof g_reply, "pong (%u)", n); r[0] = 0; return 0; }
CB(wire_recv) { uint32_t p = (uint32_t)a[0], mx = (uint32_t)a[1]; int n = g_reply_len < (int)mx ? g_reply_len : (int)mx; memcpy(mem + p, g_reply, n); r[0] = (uint64_t)n; return 0; }
/* the small slice of WASI preview 1 that wasi-libc programs need to print and exit */
CB(fd_write) { uint32_t fd = (uint32_t)a[0], iovs = (uint32_t)a[1], n = (uint32_t)a[2], out = (uint32_t)a[3], total = 0;
    for (uint32_t i = 0; i < n; i++) { uint32_t p, l; memcpy(&p, mem + iovs + 8 * i, 4); memcpy(&l, mem + iovs + 8 * i + 4, 4); fwrite(mem + p, 1, l, fd == 2 ? stderr : stdout); total += l; }
    memcpy(mem + out, &total, 4); r[0] = 0; return 0; }
CB(clock_time_get) { struct timespec t; clock_gettime((uint32_t)a[0] == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &t); uint64_t ns = (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; memcpy(mem + (uint32_t)a[2], &ns, 8); r[0] = 0; return 0; }
CB(proc_exit) { fflush(stdout); fflush(stderr); exit((int)a[0]); }
CB(zero2) { uint32_t z = 0; memcpy(mem + (uint32_t)a[0], &z, 4); memcpy(mem + (uint32_t)a[1], &z, 4); r[0] = 0; return 0; }   /* args_sizes_get, environ_sizes_get */
CB(ok2) { r[0] = 0; return 0; }                                                                                                      /* args_get, environ_get, fd_close */
CB(ebadf) { r[0] = 8; return 0; }                                                                                                    /* fd_prestat_get, fd_prestat_dir_name */
CB(fd_seek) { r[0] = 70; return 0; }
CB(fd_fdstat_get) { memset(mem + (uint32_t)a[1], 0, 24); mem[(uint32_t)a[1]] = 2; r[0] = 0; return 0; }

static uint8_t *read_all(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(len); if (fread(b, 1, len, f) != (size_t)len) { fclose(f); free(b); return NULL; } fclose(f); *n = len; return b;
}
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s sig|nosig|pulley <guest-base> [--invoke=name]\n", argv[0]); return 64; }
    const char *mode = argv[1], *base = argv[2], *entry = "_start";
    for (int i = 3; i < argc; i++) if (!strncmp(argv[i], "--invoke=", 9)) entry = argv[i] + 9;
    int m = !strcmp(mode, "sig") ? 0 : !strcmp(mode, "nosig") ? 1 : 2;
    const char *arch = IsAarch64() ? "aarch64" : "x86_64";
    char path[512], alt[512];
    if (m == 2) snprintf(path, sizeof path, "/zip/%s.pulley.cwasm", base), snprintf(alt, sizeof alt, "%s.pulley.cwasm", base);
    else snprintf(path, sizeof path, "/zip/%s.%s.%s.cwasm", base, mode, arch), snprintf(alt, sizeof alt, "%s.%s.%s.cwasm", base, mode, arch);
    size_t len = 0; uint8_t *bytes = read_all(path, &len); if (!bytes) bytes = read_all(alt, &len);
    if (!bytes) { fprintf(stderr, "cannot read %s or %s\n", path, alt); return 65; }
    printf("host : platform=%s arch=%s mode=%s guest=%s (%zu bytes)\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", arch, mode, base, len); fflush(stdout);
    double t0 = now_ms();
    if (wn_init(m)) { fprintf(stderr, "init failed\n"); return 66; }
    const char *W = "wasi_snapshot_preview1";
    int rc = 0;
    rc |= wn_define("sample:wire/transport@0.1.0", "send", "ii>i", wire_send, 0) | wn_define("sample:wire/transport@0.1.0", "recv", "ii>i", wire_recv, 0);
    rc |= wn_define(W, "fd_write", "iiii>i", fd_write, 0) | wn_define(W, "clock_time_get", "ili>i", clock_time_get, 0) | wn_define(W, "proc_exit", "i", proc_exit, 0);
    rc |= wn_define(W, "args_sizes_get", "ii>i", zero2, 0) | wn_define(W, "environ_sizes_get", "ii>i", zero2, 0) | wn_define(W, "args_get", "ii>i", ok2, 0) | wn_define(W, "environ_get", "ii>i", ok2, 0);
    rc |= wn_define(W, "fd_close", "i>i", ok2, 0) | wn_define(W, "fd_prestat_get", "ii>i", ebadf, 0) | wn_define(W, "fd_prestat_dir_name", "iii>i", ebadf, 0);
    rc |= wn_define(W, "fd_seek", "ilii>i", fd_seek, 0) | wn_define(W, "fd_fdstat_get", "ii>i", fd_fdstat_get, 0);
    if (rc) { fprintf(stderr, "define failed: %s\n", wn_last_error()); return 67; }
    if (wn_load(bytes, len)) { fprintf(stderr, "load failed: %s\n", wn_last_error()); return 68; }
    double t1 = now_ms();
    if (wn_instantiate()) { fprintf(stderr, "instantiate failed: %s\n", wn_last_error()); return 69; }
    double t2 = now_ms();
    printf("host : engine+load %.1f ms, instantiate %.1f ms, linear memory %zu MiB\n", t1 - t0, t2 - t1, wn_memory_size() >> 20); fflush(stdout);
    uint64_t res[2] = {0, 0};
    if (wn_call(entry, NULL, 0, res, 1)) { fprintf(stderr, "call failed: %s\n", wn_last_error()); return 70; }
    printf("host : %s returned\n", entry);
    return 0;
}
