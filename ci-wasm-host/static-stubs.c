/* Wasmtime linked statically into a Cosmopolitan executable: the few Linux-only system calls Cosmopolitan does not provide, which the tokio/mio
 * I/O reactor and process helpers inside Wasmtime's WASI layer refer to. They fail with ENOSYS, so only the WASI features that need them (sockets,
 * async I/O, child processes) are unavailable; stdio, clocks, files and plain wasm execution do not use them.
 * No includes on purpose: the prototypes are written out to avoid clashes with the Cosmopolitan headers. */
extern int *__errno_location(void);
#define ENOSYS_ 38
static int fail(void) { *__errno_location() = ENOSYS_; return -1; }
int epoll_create1(int flags) { (void)flags; return fail(); }
int epoll_ctl(int ep, int op, int fd, void *ev) { (void)ep; (void)op; (void)fd; (void)ev; return fail(); }
int epoll_wait(int ep, void *evs, int max, int timeout) { (void)ep; (void)evs; (void)max; (void)timeout; return fail(); }
int eventfd(unsigned int initval, int flags) { (void)initval; (void)flags; return fail(); }
int mkfifo(const char *path, unsigned int mode) { (void)path; (void)mode; return fail(); }
int waitid(int idtype, unsigned int id, void *info, int options) { (void)idtype; (void)id; (void)info; (void)options; return fail(); }

/* Rust's musl target calls the POSIX (XSI) strerror_r that returns an int; Cosmopolitan's is the GNU one that returns a pointer, which Rust reads as a failure and
 * turns into "strerror_r failure" while it is already printing an error. The link uses -Wl,--wrap=strerror_r: every call (Rust's and Cosmopolitan's own strerror)
 * lands here, and the GNU implementation is reached through __real_strerror_r. Defining strerror_r itself and calling strerror would recurse forever. */
extern char *__real_strerror_r(int, char *, unsigned long);
extern unsigned long strlen(const char *);
int __wrap_strerror_r(int errnum, char *buf, unsigned long buflen) {
  if (buflen == 0) return 34;
  const char *m = __real_strerror_r(errnum, buf, buflen); unsigned long n = strlen(m);
  if (n >= buflen) n = buflen - 1;
  if (m != buf) for (unsigned long i = 0; i < n; i++) buf[i] = m[i];
  buf[n] = 0; return 0;
}
