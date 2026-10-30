/* Cost of WASI calls from a guest: ns per operation (clock read, random, small file write+read, stat, fd_write to a file). Not part of the identical-output comparison. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/stat.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
#define BENCH(name, n, body) do { double t0 = now(); for (int i = 0; i < (n); i++) { body; } double dt = now() - t0; printf("BENCH %-22s %10.0f ns/op  (%d ops)\n", name, dt / (n), (n)); } while (0)
int main(void) {
    struct timespec ts; unsigned char rnd[16]; char buf[4096]; struct stat st; memset(buf, 'x', sizeof buf);
    BENCH("clock_gettime", 200000, clock_gettime(CLOCK_MONOTONIC, &ts));
    BENCH("getentropy 16B", 100000, getentropy(rnd, 16));
    int fd = open("/sandbox/bench.bin", O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { printf("cannot open /sandbox/bench.bin\n"); return 1; }
    BENCH("write 4 KiB", 20000, write(fd, buf, sizeof buf));
    BENCH("pread 4 KiB", 20000, pread(fd, buf, sizeof buf, (i % 1000) * 4096));
    BENCH("fstat", 50000, fstat(fd, &st));
    close(fd);
    BENCH("stat (path)", 20000, stat("/sandbox/bench.bin", &st));
    BENCH("open+close", 5000, { int f = open("/sandbox/bench.bin", O_RDONLY); close(f); });
    unlink("/sandbox/bench.bin");
    return 0;
}
