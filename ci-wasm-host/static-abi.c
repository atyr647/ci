/* Rust's musl target compiles Linux numbers into its calls: CLOCK_MONOTONIC is 1, getrandom's GRND_INSECURE is 4, and so on. Cosmopolitan's libc takes its own constants,
 * which are variables resolved when the program starts because they differ between the operating systems it runs on. On Linux the two agree, which is why the x86-64
 * build ran there; on macOS clock_gettime(1, ...) is not CLOCK_MONOTONIC and the call fails, on Windows getrandom(..., 4) is refused.
 * The workflow renames these undefined symbols inside Wasmtime's static library (llvm-objcopy --redefine-sym clock_gettime=rs_clock_gettime, ...) so only calls made BY
 * the Rust code come here; Cosmopolitan's own calls keep using its libc directly. */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/random.h>
#include <time.h>

static int map_clock(int linux_id) {
  switch (linux_id) {
    case 0: return CLOCK_REALTIME;
    case 1: return CLOCK_MONOTONIC;
    case 2: return CLOCK_PROCESS_CPUTIME_ID;
    case 3: return CLOCK_THREAD_CPUTIME_ID;
    case 4: return CLOCK_MONOTONIC_RAW;
    case 5: return CLOCK_REALTIME_COARSE;
    case 6: return CLOCK_MONOTONIC_COARSE;
    case 7: return CLOCK_BOOTTIME;
    default: return linux_id;
  }
}
int rs_clock_gettime(int clk, struct timespec *ts) { return clock_gettime(map_clock(clk), ts); }
int rs_clock_getres(int clk, struct timespec *ts) { return clock_getres(map_clock(clk), ts); }

/* GRND_INSECURE (4) is a Linux 5.6 flag; asking for secure bytes instead is always acceptable for the uses inside Wasmtime (hash seeds, WASI random). */
ssize_t rs_getrandom(void *buf, size_t n, unsigned flags) { return getrandom(buf, n, flags & ~4u); }

/* An error code Cosmopolitan does not know must not abort the process from inside the panic handler that is trying to print it. */
int rs_strerror_r(int e, char *buf, size_t n) {
  if (strerror_r(e, buf, n) != 0) snprintf(buf, n, "os error %d", e);
  return 0;
}
int rs___xpg_strerror_r(int e, char *buf, size_t n) { return rs_strerror_r(e, buf, n); }
