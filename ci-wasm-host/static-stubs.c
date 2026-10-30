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

/* strerror_r: Cosmopolitan's is already the POSIX (XSI) one that returns 0 on success, which is what Rust's musl target expects - nothing to provide. */
