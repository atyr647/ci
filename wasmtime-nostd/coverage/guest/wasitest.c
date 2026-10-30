/* A real wasi-sdk program that exercises the WASI host: args, environment, stdio, files, directories, symlinks, times, clocks, random, poll, sockets (preview 1), exit codes.
 * Built for wasm32-wasip1 and wasm32-wasip2; the output is meant to be identical on every OS and CPU the host runs on. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <poll.h>
#include <time.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/time.h>
#ifdef __wasip1__
#include <sys/socket.h>
#endif

static int pass, fail;
static void section(const char *name) { static struct timespec t0; struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); if (!t0.tv_sec && !t0.tv_nsec) t0 = t; printf("== %s\n", name); fprintf(stderr, "[t=%ld ms] %s\n", (long)((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000), name); }
#define CHECK(name, cond) do { int ok_ = !!(cond); if (ok_) pass++; else fail++; printf("%s %s\n", ok_ ? "ok  " : "FAIL", name); if (!ok_) printf("       (errno %d)\n", errno); } while (0)
static uint64_t fnv(const unsigned char *p, size_t n) { uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }
static void bye(void) { printf("atexit handler ran\n"); fflush(stdout); }

static char *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    size_t cap = 1 << 16, len = 0; char *b = malloc(cap);
    for (;;) { size_t g = fread(b + len, 1, cap - len, f); len += g; if (len < cap) break; cap *= 2; b = realloc(b, cap); }
    fclose(f); *n = len; return b;
}

int main(int argc, char **argv) {
    atexit(bye);
    section("args");
    printf("argc=%d argv0=%s\n", argc, argv[0]);
    for (int i = 1; i < argc; i++) printf("argv[%d]=%s\n", i, argv[i]);
    if (argc > 1 && !strcmp(argv[1], "exit7")) { printf("exiting with 7\n"); return 7; }

    section("environment");
    const char *ev = getenv("WN_TEST_VAR");
    CHECK("getenv WN_TEST_VAR", ev && !strcmp(ev, "hello env"));
    CHECK("getenv missing", getenv("WN_NO_SUCH_VAR") == NULL);

    section("stdio");
    printf("stdout line\n"); fprintf(stderr, "stderr line\n");
    char line[128]; const char *g = fgets(line, sizeof line, stdin);
    if (g) { line[strcspn(line, "\r\n")] = 0; printf("stdin line: [%s]\n", line); } else printf("stdin: eof\n");
    CHECK("stdin read", g == NULL || strlen(line) > 0);

    section("files");
    const char *D = "/sandbox";
    char p[256], q[256];
    snprintf(p, sizeof p, "%s/work", D);
    CHECK("mkdir", mkdir(p, 0755) == 0);
    CHECK("mkdir again fails EEXIST", mkdir(p, 0755) != 0 && errno == EEXIST);
    snprintf(p, sizeof p, "%s/work/a.txt", D);
    FILE *f = fopen(p, "wb"); CHECK("create a.txt", f != NULL);
    if (f) { fputs("hello, wasi\nsecond line\n", f); CHECK("fclose", fclose(f) == 0); }
    size_t n = 0; char *b = slurp(p, &n);
    CHECK("read back", b && n == 24 && !memcmp(b, "hello, wasi\nsecond line\n", 24)); free(b);
    struct stat st; CHECK("stat size/type", stat(p, &st) == 0 && st.st_size == 24 && S_ISREG(st.st_mode));
    int fd = open(p, O_RDWR); CHECK("open rdwr", fd >= 0);
    if (fd >= 0) {
        CHECK("lseek end", lseek(fd, 0, SEEK_END) == 24);
        CHECK("lseek set+tell", lseek(fd, 7, SEEK_SET) == 7 && lseek(fd, 0, SEEK_CUR) == 7);
        char buf[8] = {0}; CHECK("read 4", read(fd, buf, 4) == 4 && !memcmp(buf, "wasi", 4));
        CHECK("pread", pread(fd, buf, 5, 0) == 5 && !memcmp(buf, "hello", 5));
        CHECK("pwrite", pwrite(fd, "HELLO", 5, 0) == 5);
        CHECK("ftruncate", ftruncate(fd, 12) == 0);
        CHECK("fstat after truncate", fstat(fd, &st) == 0 && st.st_size == 12);
        CHECK("fsync", fsync(fd) == 0);
        close(fd);
    }
    fd = open(p, O_WRONLY | O_APPEND); CHECK("open append", fd >= 0);
    if (fd >= 0) { CHECK("append write", write(fd, "+tail", 5) == 5); close(fd); }
    b = slurp(p, &n); CHECK("content after edits", b && n == 17 && !memcmp(b, "HELLO, wasi\n+tail", 17)); free(b);
    fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0644); CHECK("O_EXCL on existing fails EEXIST", fd < 0 && errno == EEXIST);
    snprintf(q, sizeof q, "%s/work/none.txt", D);
    CHECK("open missing fails ENOENT", open(q, O_RDONLY) < 0 && errno == ENOENT);
    snprintf(q, sizeof q, "%s/work/b.txt", D);
    CHECK("rename", rename(p, q) == 0);
    CHECK("old name gone", stat(p, &st) != 0 && errno == ENOENT);
    CHECK("link", link(q, p) == 0);
    CHECK("link count", stat(q, &st) == 0 && st.st_nlink == 2);
    CHECK("unlink one name", unlink(p) == 0);

    struct timespec ts[2] = {{1700000000, 0}, {1700000123, 0}};
    CHECK("utimensat", utimensat(AT_FDCWD, q, ts, 0) == 0);
    int sr = stat(q, &st); CHECK("mtime/atime read back", sr == 0 && st.st_mtim.tv_sec == 1700000123 && st.st_atim.tv_sec == 1700000000); if (!(sr == 0 && st.st_mtim.tv_sec == 1700000123 && st.st_atim.tv_sec == 1700000000)) printf("       stat=%d mtime=%lld atime=%lld\n", sr, (long long)st.st_mtim.tv_sec, (long long)st.st_atim.tv_sec);

    /* a larger file, written in odd-sized chunks, read back, hashed */
    snprintf(p, sizeof p, "%s/work/big.bin", D);
    { size_t total = 3 * 1024 * 1024 + 17; unsigned char *buf = malloc(total); for (size_t i = 0; i < total; i++) buf[i] = (unsigned char)(i * 31 + (i >> 8));
      fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644); size_t off = 0; int ok = fd >= 0; while (ok && off < total) { size_t c = total - off > 70001 ? 70001 : total - off; ssize_t w = write(fd, buf + off, c); if (w <= 0) ok = 0; else off += (size_t)w; } if (fd >= 0) close(fd);
      CHECK("write 3 MiB", ok && off == total);
      size_t rn = 0; char *rb = slurp(p, &rn); CHECK("read 3 MiB back, same hash", rb && rn == total && fnv((unsigned char *)rb, rn) == fnv(buf, total));
      printf("big.bin fnv=%016llx\n", (unsigned long long)fnv(buf, total)); free(rb); free(buf); }

    section("directories");
    snprintf(p, sizeof p, "%s/work/sub", D); CHECK("mkdir sub", mkdir(p, 0755) == 0);
    snprintf(p, sizeof p, "%s/work/sub/inner.txt", D); f = fopen(p, "w"); if (f) { fputs("x", f); fclose(f); }
    DIR *d = opendir("/sandbox/work"); CHECK("opendir", d != NULL);
    if (d) { struct dirent *e; char names[16][64]; int nn = 0; while ((e = readdir(d)) && nn < 16) snprintf(names[nn++], 64, "%s", e->d_name); closedir(d);
        /* the preview 1 host lists ".", ".." first, then the entries sorted by name; the preview 2 interface does not list the dot entries, so only the real ones are printed */
        int real = 0; for (int i = 0; i < nn; i++) if (strcmp(names[i], ".") && strcmp(names[i], "..")) { printf("dirent: %s\n", names[i]); real++; }
        CHECK("readdir real entry count", real == 3); }
    CHECK("stat directory", stat("/sandbox/work/sub", &st) == 0 && S_ISDIR(st.st_mode));
    snprintf(p, sizeof p, "%s/work/sub", D);
    CHECK("rmdir non-empty fails ENOTEMPTY", rmdir(p) != 0 && errno == ENOTEMPTY);
    snprintf(q, sizeof q, "%s/work/sub/inner.txt", D); CHECK("unlink inner", unlink(q) == 0);
    CHECK("rmdir empty", rmdir(p) == 0);
    CHECK("unlink a directory fails", unlink("/sandbox/work") != 0);

    section("symbolic links and the sandbox");
    int sl = symlink("b.txt", "/sandbox/work/link-to-b");
    printf("symlink: %s\n", sl == 0 ? "created" : "not supported here");
    if (sl == 0) { char tgt[64] = {0}; ssize_t rl = readlink("/sandbox/work/link-to-b", tgt, sizeof tgt - 1); CHECK("readlink", rl == 5 && !strcmp(tgt, "b.txt"));
        size_t m = 0; char *c = slurp("/sandbox/work/link-to-b", &m); CHECK("read through symlink", c && m == 17); free(c); }
    int esc = symlink("../../..", "/sandbox/work/escape");
    if (esc == 0) { FILE *x = fopen("/sandbox/work/escape/etc/hostname", "r"); CHECK("symlink pointing out of the sandbox is not followed", x == NULL); if (x) fclose(x); } else printf("escape symlink: not supported here\n");
    CHECK("dot-dot out of the preopen is refused", fopen("/sandbox/../escape.txt", "w") == NULL);
    CHECK("absolute path outside the preopens is refused", fopen("/etc/passwd", "r") == NULL);
    CHECK("relative dot-dot inside is fine", stat("/sandbox/work/../work/b.txt", &st) == 0);

    section("clocks, random, poll");
    struct timespec t0, t1, wall; clock_gettime(CLOCK_MONOTONIC, &t0); struct timespec nap = {0, 20 * 1000000}; nanosleep(&nap, NULL); clock_gettime(CLOCK_MONOTONIC, &t1);
    long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
    CHECK("nanosleep 20 ms", ms >= 19 && ms < 2000);
    clock_gettime(CLOCK_REALTIME, &wall); CHECK("realtime clock is after 2024", wall.tv_sec > 1704067200);
    struct timespec res; CHECK("clock_getres", clock_getres(CLOCK_MONOTONIC, &res) == 0 && res.tv_sec == 0 && res.tv_nsec > 0);
    clock_gettime(CLOCK_MONOTONIC, &t0); int pr = poll(NULL, 0, 30); clock_gettime(CLOCK_MONOTONIC, &t1);
    ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000; CHECK("poll as a 30 ms timer", pr == 0 && ms >= 28 && ms < 2000);
    unsigned char r1[32], r2[32]; CHECK("getentropy", getentropy(r1, 32) == 0 && getentropy(r2, 32) == 0);
    int nz = 0; for (int i = 0; i < 32; i++) nz |= r1[i]; CHECK("random not all zero and two draws differ", nz && memcmp(r1, r2, 32));

#ifdef __wasip1__
    section("sockets (preview 1)");
    const char *lf = getenv("LISTEN_FD");
    if (lf) {
        int lfd = atoi(lf); struct pollfd pf = { lfd, POLLIN, 0 };
        int r = poll(&pf, 1, 10000); CHECK("poll listening socket readable", r == 1 && (pf.revents & POLLIN));
        int c = accept(lfd, NULL, NULL); CHECK("accept", c >= 0);
        if (c >= 0) { char buf[128]; size_t got = 0; for (;;) { ssize_t k = recv(c, buf + got, sizeof buf - 1 - got, 0); if (k <= 0) break; got += (size_t)k; } buf[got] = 0;
            printf("received %zu bytes: [%s]\n", got, buf); CHECK("received the client's message", got == 16 && !strcmp(buf, "ping from client"));
            char rep[160]; int rn = snprintf(rep, sizeof rep, "pong(%zu): %s", got, buf); CHECK("send reply", send(c, rep, (size_t)rn, 0) == rn);
            CHECK("shutdown", shutdown(c, SHUT_WR) == 0); close(c); }
    } else printf("no listening socket supplied\n");
#endif

    section("memory");
    { size_t sz = 48u << 20; unsigned char *m = malloc(sz); CHECK("malloc 48 MiB", m != NULL); if (m) { for (size_t i = 0; i < sz; i += 4096) m[i] = (unsigned char)(i >> 12); uint64_t h = 0; for (size_t i = 0; i < sz; i += 4096) h += m[i]; printf("touched pages checksum=%llu\n", (unsigned long long)h); free(m); } }

    printf("SUMMARY pass=%d fail=%d\n", pass, fail);
    fflush(stdout);
    return fail ? 1 : 0;
}
