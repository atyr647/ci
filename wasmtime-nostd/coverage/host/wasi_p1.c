/* WASI preview 1 host written in C for Cosmopolitan (one source, Linux + macOS + Windows, x86-64 + arm64).
 * Covers the whole of wasi_snapshot_preview1: args, environ, clocks, random, fd_*, path_*, poll_oneoff, proc_exit/raise, sched_yield and the four socket calls
 * (on sockets the host pre-opens, like `wasmtime --tcplisten`).
 * Sandbox: every path is resolved lexically against the pre-opened directory it was given relative to (".." may not leave it, absolute paths are refused with ENOTCAPABLE),
 * and the real path of the longest existing prefix must stay under the real path of the pre-opened directory (so a symbolic link cannot lead out).
 * Directory descriptors are virtual (a path under a root), so no OS handle on a directory is needed - that keeps Windows identical to the others. */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <time.h>
#include <poll.h>
#include <dirent.h>
#include <sched.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/random.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <cosmo.h>
#include "wasi_p1.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* ---- errno translation (Cosmopolitan's errno constants are runtime values, so a table, not a switch) ---- */
enum { W_2BIG = 1, W_ACCES = 2, W_ADDRINUSE = 3, W_ADDRNOTAVAIL = 4, W_AFNOSUPPORT = 5, W_AGAIN = 6, W_ALREADY = 7, W_BADF = 8, W_BADMSG = 9, W_BUSY = 10, W_CANCELED = 11, W_CHILD = 12,
    W_CONNABORTED = 13, W_CONNREFUSED = 14, W_CONNRESET = 15, W_DEADLK = 16, W_DESTADDRREQ = 17, W_DOM = 18, W_DQUOT = 19, W_EXIST = 20, W_FAULT = 21, W_FBIG = 22, W_HOSTUNREACH = 23,
    W_IDRM = 24, W_ILSEQ = 25, W_INPROGRESS = 26, W_INTR = 27, W_INVAL = 28, W_IO = 29, W_ISCONN = 30, W_ISDIR = 31, W_LOOP = 32, W_MFILE = 33, W_MLINK = 34, W_MSGSIZE = 35,
    W_NAMETOOLONG = 37, W_NETDOWN = 38, W_NETRESET = 39, W_NETUNREACH = 40, W_NFILE = 41, W_NOBUFS = 42, W_NODEV = 43, W_NOENT = 44, W_NOEXEC = 45, W_NOLCK = 46, W_NOMEM = 48,
    W_NOPROTOOPT = 50, W_NOSPC = 51, W_NOSYS = 52, W_NOTCONN = 53, W_NOTDIR = 54, W_NOTEMPTY = 55, W_NOTSOCK = 57, W_NOTSUP = 58, W_NOTTY = 59, W_NXIO = 60, W_OVERFLOW = 61,
    W_PERM = 63, W_PIPE = 64, W_PROTO = 65, W_PROTONOSUPPORT = 66, W_PROTOTYPE = 67, W_RANGE = 68, W_ROFS = 69, W_SPIPE = 70, W_SRCH = 71, W_STALE = 72, W_TIMEDOUT = 73,
    W_TXTBSY = 74, W_XDEV = 75, W_NOTCAPABLE = 76 };
static struct { int e; int w; } emap[64]; static int nemap;
static void eadd(int e, int w) { if (e && nemap < 64) { emap[nemap].e = e; emap[nemap].w = w; nemap++; } }
static void emap_init(void) {
    if (nemap) return;
    eadd(E2BIG, W_2BIG); eadd(EACCES, W_ACCES); eadd(EADDRINUSE, W_ADDRINUSE); eadd(EADDRNOTAVAIL, W_ADDRNOTAVAIL); eadd(EAFNOSUPPORT, W_AFNOSUPPORT); eadd(EAGAIN, W_AGAIN); eadd(EALREADY, W_ALREADY);
    eadd(EBADF, W_BADF); eadd(EBUSY, W_BUSY); eadd(ECONNABORTED, W_CONNABORTED); eadd(ECONNREFUSED, W_CONNREFUSED); eadd(ECONNRESET, W_CONNRESET); eadd(EDEADLK, W_DEADLK);
    eadd(EDESTADDRREQ, W_DESTADDRREQ); eadd(EDOM, W_DOM); eadd(EDQUOT, W_DQUOT); eadd(EEXIST, W_EXIST); eadd(EFAULT, W_FAULT); eadd(EFBIG, W_FBIG); eadd(EHOSTUNREACH, W_HOSTUNREACH);
    eadd(EILSEQ, W_ILSEQ); eadd(EINPROGRESS, W_INPROGRESS); eadd(EINTR, W_INTR); eadd(EINVAL, W_INVAL); eadd(EIO, W_IO); eadd(EISCONN, W_ISCONN); eadd(EISDIR, W_ISDIR); eadd(ELOOP, W_LOOP);
    eadd(EMFILE, W_MFILE); eadd(EMLINK, W_MLINK); eadd(EMSGSIZE, W_MSGSIZE); eadd(ENAMETOOLONG, W_NAMETOOLONG); eadd(ENETDOWN, W_NETDOWN); eadd(ENETRESET, W_NETRESET);
    eadd(ENETUNREACH, W_NETUNREACH); eadd(ENFILE, W_NFILE); eadd(ENOBUFS, W_NOBUFS); eadd(ENODEV, W_NODEV); eadd(ENOENT, W_NOENT); eadd(ENOEXEC, W_NOEXEC); eadd(ENOLCK, W_NOLCK);
    eadd(ENOMEM, W_NOMEM); eadd(ENOPROTOOPT, W_NOPROTOOPT); eadd(ENOSPC, W_NOSPC); eadd(ENOSYS, W_NOSYS); eadd(ENOTCONN, W_NOTCONN); eadd(ENOTDIR, W_NOTDIR); eadd(ENOTEMPTY, W_NOTEMPTY);
    eadd(ENOTSOCK, W_NOTSOCK); eadd(ENOTSUP, W_NOTSUP); eadd(ENOTTY, W_NOTTY); eadd(ENXIO, W_NXIO); eadd(EOVERFLOW, W_OVERFLOW); eadd(EPERM, W_PERM); eadd(EPIPE, W_PIPE); eadd(EPROTO, W_PROTO);
    eadd(EPROTONOSUPPORT, W_PROTONOSUPPORT); eadd(EPROTOTYPE, W_PROTOTYPE); eadd(ERANGE, W_RANGE); eadd(EROFS, W_ROFS); eadd(ESPIPE, W_SPIPE); eadd(ESRCH, W_SRCH); eadd(ETIMEDOUT, W_TIMEDOUT);
    eadd(ETXTBSY, W_TXTBSY); eadd(EXDEV, W_XDEV); eadd(EWOULDBLOCK, W_AGAIN);
}
static int werr(int e) { emap_init(); for (int i = 0; i < nemap; i++) if (emap[i].e == e) return emap[i].w; return W_IO; }
#define ERR() (r[0] = (uint64_t)werr(errno), 0)
#define RET(code) do { r[0] = (uint64_t)(code); return 0; } while (0)

/* ---- guest memory access ---- */
#define CB(n) static int32_t n(void *user, uint8_t *mem, size_t memlen, const uint64_t *a, uint64_t *r)
#define A32(i) ((uint32_t)a[i])
#define A64(i) ((uint64_t)a[i])
#define CHK(p, n) do { if ((uint64_t)(p) + (uint64_t)(n) > memlen) RET(W_FAULT); } while (0)
static void put32(uint8_t *m, uint32_t off, uint32_t v) { memcpy(m + off, &v, 4); }
static void put64(uint8_t *m, uint32_t off, uint64_t v) { memcpy(m + off, &v, 8); }
static uint32_t get32(const uint8_t *m, uint32_t off) { uint32_t v; memcpy(&v, m + off, 4); return v; }
static uint64_t get64(const uint8_t *m, uint32_t off) { uint64_t v; memcpy(&v, m + off, 8); return v; }
uint64_t wasi_p1_calls;
static uint64_t now_ns(int clk) { struct timespec t; clock_gettime(clk, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }

/* ---- descriptors ---- */
enum { K_NONE = 0, K_FILE, K_DIR, K_STDIO, K_LISTEN, K_SOCK };
typedef struct DirEnt { char *name; uint64_t ino; uint8_t type; } DirEnt;
typedef struct Fd { int kind; int hfd; int root; char *rel; char *gname; DirEnt *list; size_t nlist; } Fd;
typedef struct Root { char *host; } Root;
static Fd *fds; static int nfds, capfds;
static Root roots[16]; static int nroots;
static int g_argc; static char **g_argv; static char *g_env[256]; static int g_nenv;
static int g_listen_fd = -1;
int wasi_listen_fd(void) { return g_listen_fd; }

static int fd_new(Fd f) {
    for (int i = 3; i < nfds; i++) if (fds[i].kind == K_NONE) { fds[i] = f; return i; }
    if (nfds == capfds) { capfds = capfds ? capfds * 2 : 16; fds = realloc(fds, capfds * sizeof *fds); }
    fds[nfds] = f; return nfds++;
}
static void fd_free_list(Fd *f) { for (size_t i = 0; i < f->nlist; i++) free(f->list[i].name); free(f->list); f->list = NULL; f->nlist = 0; }
static Fd *fd_get(uint32_t g) { return g < (uint32_t)nfds && fds[g].kind != K_NONE ? &fds[g] : NULL; }
static void fd_release(Fd *f) { fd_free_list(f); free(f->rel); free(f->gname); memset(f, 0, sizeof *f); f->hfd = -1; }
static void init_fds(void) {
    if (nfds) return;
    capfds = 16; fds = calloc(capfds, sizeof *fds);
    for (int i = 0; i < 3; i++) { fds[i].kind = K_STDIO; fds[i].hfd = i; fds[i].root = -1; }
    nfds = 3;
}
int wasi_add_preopen(const char *guest, const char *host) {
    init_fds();
    char rp[PATH_MAX]; if (!realpath(host, rp)) return -1;
    struct stat st; if (stat(rp, &st) || !S_ISDIR(st.st_mode)) return -1;
    if (nroots >= 16) return -1;
    roots[nroots].host = strdup(rp);
    Fd f = { K_DIR, -1, nroots, strdup(""), strdup(guest), NULL, 0 };
    nroots++; fd_new(f); return 0;
}
void wasi_set_args(int argc, char **argv) { g_argc = argc; g_argv = argv; }
void wasi_add_env(const char *kv) { if (g_nenv < 255) g_env[g_nenv++] = strdup(kv); }
int wasi_add_tcp_listen(const char *ip, int port, int *bound) {
    init_fds();
    int s = socket(AF_INET, SOCK_STREAM, 0); if (s < 0) return -1;
    int one = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (void *)&one, sizeof one);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa); sa.sin_family = AF_INET; sa.sin_port = htons((uint16_t)port); if (inet_pton(AF_INET, ip, &sa.sin_addr) != 1) return -1;
    if (bind(s, (struct sockaddr *)&sa, sizeof sa) || listen(s, 16)) { close(s); return -1; }
    socklen_t l = sizeof sa; getsockname(s, (struct sockaddr *)&sa, &l); if (bound) *bound = ntohs(sa.sin_port);
    Fd f = { K_LISTEN, s, -1, NULL, NULL, NULL, 0 };
    g_listen_fd = fd_new(f); return 0;
}

/* ---- sandboxed paths ---- */
/* join rel + "/" + path, resolve "." and "..", refuse to go above the root; out has no leading or trailing slash ("" for the root itself) */
static int norm_path(const char *rel, const char *p, size_t plen, char *out, size_t cap) {
    char buf[PATH_MAX]; size_t n = 0;
    size_t rl = strlen(rel);
    if (rl + plen + 2 > sizeof buf) return W_NAMETOOLONG;
    memcpy(buf, rel, rl); n = rl; if (n && plen) buf[n++] = '/';
    memcpy(buf + n, p, plen); n += plen; buf[n] = 0;
    if (memchr(p, 0, plen)) return W_INVAL;
    if (plen && (p[0] == '/' || p[0] == '\\')) return W_NOTCAPABLE;
    size_t comps[PATH_MAX / 2], clen[PATH_MAX / 2]; int nc = 0;
    size_t i = 0;
    while (i < n) {
        while (i < n && (buf[i] == '/')) i++;
        size_t s = i; while (i < n && buf[i] != '/') i++;
        size_t l = i - s; if (!l) continue;
        if (l == 1 && buf[s] == '.') continue;
        if (l == 2 && buf[s] == '.' && buf[s + 1] == '.') { if (!nc) return W_NOTCAPABLE; nc--; continue; }
        comps[nc] = s; clen[nc] = l; nc++;
    }
    size_t o = 0;
    for (int c = 0; c < nc; c++) { if (c) { if (o + 1 >= cap) return W_NAMETOOLONG; out[o++] = '/'; } if (o + clen[c] >= cap) return W_NAMETOOLONG; memcpy(out + o, buf + comps[c], clen[c]); o += clen[c]; }
    out[o] = 0; return 0;
}
static void host_path(int root, const char *rel, char *out, size_t cap) { if (*rel) snprintf(out, cap, "%s/%s", roots[root].host, rel); else snprintf(out, cap, "%s", roots[root].host); }
/* the real path of the longest existing prefix (including the final component when `follow`) must lie under the real root */
static int symlink_check(int root, const char *rel, int follow) {
    char hp[PATH_MAX], rp[PATH_MAX];
    host_path(root, rel, hp, sizeof hp);
    size_t hl = strlen(hp), rootlen = strlen(roots[root].host);
    if (!follow) { char *sl = strrchr(hp, '/'); if (sl && (size_t)(sl - hp) >= rootlen) *sl = 0; else if (!*rel) return 0; }
    for (;;) {
        if (realpath(hp, rp)) break;
        if (errno != ENOENT && errno != ENOTDIR) return W_ACCES;
        char *sl = strrchr(hp, '/'); if (!sl || (size_t)(sl - hp) < rootlen) return 0;   /* nothing existing below the root: nothing to escape through */
        *sl = 0;
    }
    (void)hl;
    if (strncmp(rp, roots[root].host, rootlen) == 0 && (rp[rootlen] == 0 || rp[rootlen] == '/')) return 0;
    return W_NOTCAPABLE;
}
/* resolves guest (fd, path) to root + normalised relative path; returns 0 or a WASI errno */
static int resolve(uint32_t gfd, const uint8_t *mem, uint32_t pp, uint32_t pl, int follow, int *root, char *rel, size_t cap) {
    Fd *d = fd_get(gfd); if (!d) return W_BADF; if (d->kind != K_DIR) return W_NOTDIR;
    int e = norm_path(d->rel, (const char *)mem + pp, pl, rel, cap); if (e) return e;
    *root = d->root;
    return symlink_check(d->root, rel, follow);
}

/* ---- file types and stat ---- */
static uint8_t wtype(mode_t m) { if (S_ISREG(m)) return 4; if (S_ISDIR(m)) return 3; if (S_ISCHR(m)) return 2; if (S_ISBLK(m)) return 1; if (S_ISLNK(m)) return 7; if (S_ISSOCK(m)) return 6; return 0; }
static void put_stat(uint8_t *m, uint32_t off, const struct stat *st) {
    memset(m + off, 0, 64);
    put64(m, off, (uint64_t)st->st_dev); put64(m, off + 8, (uint64_t)st->st_ino); m[off + 16] = wtype(st->st_mode); put64(m, off + 24, (uint64_t)st->st_nlink); put64(m, off + 32, (uint64_t)st->st_size);
    put64(m, off + 40, (uint64_t)st->st_atim.tv_sec * 1000000000ull + (uint64_t)st->st_atim.tv_nsec);
    put64(m, off + 48, (uint64_t)st->st_mtim.tv_sec * 1000000000ull + (uint64_t)st->st_mtim.tv_nsec);
    put64(m, off + 56, (uint64_t)st->st_ctim.tv_sec * 1000000000ull + (uint64_t)st->st_ctim.tv_nsec);
}
#define ALL_RIGHTS 0x1FFFFFFFull

/* ---- args, environ ---- */
CB(p_args_sizes_get) { uint32_t n = (uint32_t)g_argc, sz = 0; for (int i = 0; i < g_argc; i++) sz += (uint32_t)strlen(g_argv[i]) + 1; CHK(A32(0), 4); CHK(A32(1), 4); put32(mem, A32(0), n); put32(mem, A32(1), sz); RET(0); }
CB(p_args_get) { uint32_t pp = A32(0), bp = A32(1); for (int i = 0; i < g_argc; i++) { uint32_t l = (uint32_t)strlen(g_argv[i]) + 1; CHK(bp, l); CHK(pp + 4 * i, 4); memcpy(mem + bp, g_argv[i], l); put32(mem, pp + 4 * i, bp); bp += l; } RET(0); }
CB(p_environ_sizes_get) { uint32_t sz = 0; for (int i = 0; i < g_nenv; i++) sz += (uint32_t)strlen(g_env[i]) + 1; CHK(A32(0), 4); CHK(A32(1), 4); put32(mem, A32(0), (uint32_t)g_nenv); put32(mem, A32(1), sz); RET(0); }
CB(p_environ_get) { uint32_t pp = A32(0), bp = A32(1); for (int i = 0; i < g_nenv; i++) { uint32_t l = (uint32_t)strlen(g_env[i]) + 1; CHK(bp, l); CHK(pp + 4 * i, 4); memcpy(mem + bp, g_env[i], l); put32(mem, pp + 4 * i, bp); bp += l; } RET(0); }

/* ---- clocks, random, misc ---- */
static int clk_of(uint32_t id, clockid_t *out) { switch (id) { case 0: *out = CLOCK_REALTIME; return 0; case 1: *out = CLOCK_MONOTONIC; return 0; case 2: *out = CLOCK_PROCESS_CPUTIME_ID; return 0; case 3: *out = CLOCK_THREAD_CPUTIME_ID; return 0; } return -1; }
CB(p_clock_res_get) { clockid_t c; CHK(A32(1), 8); if (clk_of(A32(0), &c)) RET(W_INVAL); struct timespec t; if (clock_getres(c, &t)) { if (A32(0) >= 2) { put64(mem, A32(1), 1000); RET(0); } return ERR(); } put64(mem, A32(1), (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec); RET(0); }
CB(p_clock_time_get) { clockid_t c; CHK(A32(2), 8); if (clk_of(A32(0), &c)) RET(W_INVAL); struct timespec t; if (clock_gettime(c, &t)) { if (A32(0) >= 2) RET(W_NOTSUP); return ERR(); } put64(mem, A32(2), (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec); RET(0); }
CB(p_random_get) { uint32_t p = A32(0), n = A32(1); CHK(p, n); uint32_t done = 0; while (done < n) { uint32_t k = n - done > 256 ? 256 : n - done; ssize_t g = getrandom(mem + p + done, k, 0); if (g <= 0) RET(W_IO); done += (uint32_t)g; } RET(0); }
CB(p_sched_yield) { sched_yield(); RET(0); }
CB(p_proc_exit) { fflush(stdout); fflush(stderr); exit((int)A32(0)); }
CB(p_proc_raise) { int s = (int)A32(0); int h = s == 6 ? SIGABRT : s == 2 ? SIGINT : s == 15 ? SIGTERM : s == 9 ? SIGKILL : s == 8 ? SIGFPE : s == 11 ? SIGSEGV : 0; if (!h) RET(W_NOSYS); fflush(stdout); raise(h); RET(0); }

/* ---- fd_* ---- */
CB(p_fd_close) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); int e = 0; if ((f->kind == K_FILE || f->kind == K_SOCK || f->kind == K_LISTEN || f->kind == K_STDIO) && f->hfd >= 0) { if (f->kind == K_STDIO && f->hfd <= 2) { /* keep the host's own stdio open */ } else if (close(f->hfd)) e = werr(errno); } fd_release(f); RET(e); }
CB(p_fd_prestat_get) { Fd *f = fd_get(A32(0)); CHK(A32(1), 8); if (!f || f->kind != K_DIR || !f->gname || *f->rel) RET(W_BADF); memset(mem + A32(1), 0, 8); put32(mem, A32(1) + 4, (uint32_t)strlen(f->gname)); RET(0); }
CB(p_fd_prestat_dir_name) { Fd *f = fd_get(A32(0)); if (!f || f->kind != K_DIR || !f->gname) RET(W_BADF); uint32_t l = (uint32_t)strlen(f->gname); if (A32(2) < l) RET(W_NAMETOOLONG); CHK(A32(1), l); memcpy(mem + A32(1), f->gname, l); RET(0); }
static int rw_check(Fd *f, int dir_ok) { if (!f) return W_BADF; if (f->kind == K_DIR) return dir_ok ? 0 : W_ISDIR; return 0; }
/* gathers iovecs; on files uses readv/writev style loops */
CB(p_fd_read) { Fd *f = fd_get(A32(0)); int e = rw_check(f, 0); if (e) RET(e); uint32_t iov = A32(1), n = A32(2), outp = A32(3); CHK(iov, 8 * (uint64_t)n); CHK(outp, 4);
    uint32_t total = 0;
    for (uint32_t i = 0; i < n; i++) { uint32_t p = get32(mem, iov + 8 * i), l = get32(mem, iov + 8 * i + 4); if (!l) continue; CHK(p, l); ssize_t g = read(f->hfd, mem + p, l); if (g < 0) { if (total) break; return ERR(); } total += (uint32_t)g; if ((uint32_t)g < l) break; }
    put32(mem, outp, total); RET(0); }
CB(p_fd_pread) { Fd *f = fd_get(A32(0)); int e = rw_check(f, 0); if (e) RET(e); uint32_t iov = A32(1), n = A32(2), outp = A32(4); uint64_t off = A64(3); CHK(iov, 8 * (uint64_t)n); CHK(outp, 4);
    uint32_t total = 0;
    for (uint32_t i = 0; i < n; i++) { uint32_t p = get32(mem, iov + 8 * i), l = get32(mem, iov + 8 * i + 4); if (!l) continue; CHK(p, l); ssize_t g = pread(f->hfd, mem + p, l, (off_t)(off + total)); if (g < 0) { if (total) break; return ERR(); } total += (uint32_t)g; if ((uint32_t)g < l) break; }
    put32(mem, outp, total); RET(0); }
CB(p_fd_write) { Fd *f = fd_get(A32(0)); int e = rw_check(f, 0); if (e) RET(e); uint32_t iov = A32(1), n = A32(2), outp = A32(3); CHK(iov, 8 * (uint64_t)n); CHK(outp, 4);
    uint32_t total = 0;
    if (f->kind == K_STDIO && f->hfd <= 2) { if (f->hfd == 1) fflush(stdout); else if (f->hfd == 2) fflush(stderr); }
    for (uint32_t i = 0; i < n; i++) { uint32_t p = get32(mem, iov + 8 * i), l = get32(mem, iov + 8 * i + 4); if (!l) continue; CHK(p, l);
        uint32_t done = 0; while (done < l) { ssize_t w = write(f->hfd, mem + p + done, l - done); if (w < 0) { if (errno == EINTR) continue; if (total + done) goto out; return ERR(); } done += (uint32_t)w; } total += done; }
out: put32(mem, outp, total); RET(0); }
CB(p_fd_pwrite) { Fd *f = fd_get(A32(0)); int e = rw_check(f, 0); if (e) RET(e); uint32_t iov = A32(1), n = A32(2), outp = A32(4); uint64_t off = A64(3); CHK(iov, 8 * (uint64_t)n); CHK(outp, 4);
    uint32_t total = 0;
    for (uint32_t i = 0; i < n; i++) { uint32_t p = get32(mem, iov + 8 * i), l = get32(mem, iov + 8 * i + 4); if (!l) continue; CHK(p, l); ssize_t w = pwrite(f->hfd, mem + p, l, (off_t)(off + total)); if (w < 0) { if (total) break; return ERR(); } total += (uint32_t)w; if ((uint32_t)w < l) break; }
    put32(mem, outp, total); RET(0); }
CB(p_fd_seek) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); CHK(A32(3), 8); if (f->kind == K_DIR) RET(W_ISDIR); int wh = (int)A32(2); if (wh > 2) RET(W_INVAL);
    off_t o = lseek(f->hfd, (off_t)(int64_t)A64(1), wh == 0 ? SEEK_SET : wh == 1 ? SEEK_CUR : SEEK_END); if (o < 0) return ERR(); put64(mem, A32(3), (uint64_t)o); RET(0); }
CB(p_fd_tell) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); CHK(A32(1), 8); if (f->kind == K_DIR) RET(W_ISDIR); off_t o = lseek(f->hfd, 0, SEEK_CUR); if (o < 0) return ERR(); put64(mem, A32(1), (uint64_t)o); RET(0); }
CB(p_fd_sync) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind == K_FILE && fsync(f->hfd)) return ERR(); RET(0); }
CB(p_fd_datasync) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind == K_FILE && fdatasync(f->hfd)) return ERR(); RET(0); }
CB(p_fd_advise) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (A32(3) > 5) RET(W_INVAL); RET(0); }
CB(p_fd_allocate) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind == K_DIR) RET(W_ISDIR); struct stat st; if (fstat(f->hfd, &st)) return ERR(); uint64_t need = A64(1) + A64(2); if (need > (uint64_t)st.st_size && ftruncate(f->hfd, (off_t)need)) return ERR(); RET(0); }
CB(p_fd_fdstat_get) { Fd *f = fd_get(A32(0)); CHK(A32(1), 24); if (!f) RET(W_BADF); uint32_t o = A32(1); memset(mem + o, 0, 24); uint8_t ty = 0; uint16_t fl = 0;
    if (f->kind == K_DIR) ty = 3;
    else if (f->kind == K_LISTEN || f->kind == K_SOCK) ty = 6;
    else { struct stat st; if (fstat(f->hfd, &st) == 0) { ty = wtype(st.st_mode); if (f->kind == K_STDIO && !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) ty = isatty(f->hfd) ? 2 : 0; }
           int fl2 = fcntl(f->hfd, F_GETFL); if (fl2 >= 0) { if (fl2 & O_APPEND) fl |= 1; if (fl2 & O_NONBLOCK) fl |= 4; } }
    mem[o] = ty; memcpy(mem + o + 2, &fl, 2); put64(mem, o + 8, ALL_RIGHTS); put64(mem, o + 16, ALL_RIGHTS); RET(0); }
CB(p_fd_fdstat_set_flags) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind == K_DIR) RET(0); int cur = fcntl(f->hfd, F_GETFL); if (cur < 0) return ERR(); uint32_t w = A32(1); cur &= ~(O_APPEND | O_NONBLOCK); if (w & 1) cur |= O_APPEND; if (w & 4) cur |= O_NONBLOCK; if (fcntl(f->hfd, F_SETFL, cur)) return ERR(); RET(0); }
CB(p_fd_fdstat_set_rights) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); RET(0); }
CB(p_fd_filestat_get) { Fd *f = fd_get(A32(0)); CHK(A32(1), 64); if (!f) RET(W_BADF); struct stat st;
    if (f->kind == K_DIR) { char hp[PATH_MAX]; host_path(f->root, f->rel, hp, sizeof hp); if (stat(hp, &st)) return ERR(); } else if (fstat(f->hfd, &st)) return ERR();
    put_stat(mem, A32(1), &st); RET(0); }
CB(p_fd_filestat_set_size) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind == K_DIR) RET(W_ISDIR); if (ftruncate(f->hfd, (off_t)A64(1))) return ERR(); RET(0); }
static void times_of(uint64_t at, uint64_t mt, uint32_t fl, struct timespec ts[2]) {
    if (fl & 2) ts[0].tv_nsec = UTIME_NOW; else if (fl & 1) { ts[0].tv_sec = (time_t)(at / 1000000000ull); ts[0].tv_nsec = (long)(at % 1000000000ull); } else ts[0].tv_nsec = UTIME_OMIT;
    if (fl & 8) ts[1].tv_nsec = UTIME_NOW; else if (fl & 4) { ts[1].tv_sec = (time_t)(mt / 1000000000ull); ts[1].tv_nsec = (long)(mt % 1000000000ull); } else ts[1].tv_nsec = UTIME_OMIT;
}
CB(p_fd_filestat_set_times) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); uint32_t fl = A32(3); if (((fl & 1) && (fl & 2)) || ((fl & 4) && (fl & 8))) RET(W_INVAL);
    struct timespec ts[2] = {{0, 0}, {0, 0}}; times_of(A64(1), A64(2), fl, ts);
    if (f->kind == K_DIR) { char hp[PATH_MAX]; host_path(f->root, f->rel, hp, sizeof hp); if (utimensat(AT_FDCWD, hp, ts, 0)) return ERR(); } else if (futimens(f->hfd, ts)) return ERR();
    RET(0); }
CB(p_fd_renumber) { uint32_t from = A32(0), to = A32(1); Fd *f = fd_get(from), *t = fd_get(to); if (!f || !t) RET(W_BADF); if (from == to) RET(0);
    if ((t->kind == K_FILE || t->kind == K_SOCK) && t->hfd >= 0) close(t->hfd); fd_release(t); *t = *f; memset(f, 0, sizeof *f); f->hfd = -1; RET(0); }

/* directory listing: ".", "..", then the entries, each with a cookie = index of the next entry */
static int cmp_ent(const void *x, const void *y) { return strcmp(((const DirEnt *)x)->name, ((const DirEnt *)y)->name); }
static int load_dir(Fd *f) {
    char hp[PATH_MAX]; host_path(f->root, f->rel, hp, sizeof hp);
    DIR *d = opendir(hp); if (!d) return werr(errno);
    fd_free_list(f);
    size_t cap = 16; f->list = calloc(cap, sizeof(DirEnt)); f->nlist = 0;
    struct dirent *e;
    #define ADD(nm, ino_, ty_) do { if (f->nlist == cap) { cap *= 2; f->list = realloc(f->list, cap * sizeof(DirEnt)); } f->list[f->nlist].name = strdup(nm); f->list[f->nlist].ino = (ino_); f->list[f->nlist].type = (ty_); f->nlist++; } while (0)
    struct stat st; uint64_t dino = 0; if (stat(hp, &st) == 0) dino = (uint64_t)st.st_ino;
    ADD(".", dino, 3); ADD("..", dino, 3);
    size_t first = f->nlist;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char ep[PATH_MAX]; snprintf(ep, sizeof ep, "%s/%s", hp, e->d_name);
        uint8_t ty = 0; uint64_t ino = 0; if (lstat(ep, &st) == 0) { ty = wtype(st.st_mode); ino = (uint64_t)st.st_ino; }
        ADD(e->d_name, ino, ty);
    }
    closedir(d);
    qsort(f->list + first, f->nlist - first, sizeof(DirEnt), cmp_ent);   /* a stable order on every OS */
    return 0;
}
CB(p_fd_readdir) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind != K_DIR) RET(W_NOTDIR); uint32_t buf = A32(1), len = A32(2), usedp = A32(4); uint64_t cookie = A64(3); CHK(buf, len); CHK(usedp, 4);
    if (cookie == 0 || !f->list) { int e = load_dir(f); if (e) RET(e); }
    uint32_t used = 0;
    for (size_t i = (size_t)cookie; i < f->nlist && used < len; i++) {
        uint8_t hdr[24]; uint32_t nl = (uint32_t)strlen(f->list[i].name); uint64_t next = i + 1; memset(hdr, 0, 24);
        memcpy(hdr, &next, 8); memcpy(hdr + 8, &f->list[i].ino, 8); memcpy(hdr + 16, &nl, 4); hdr[20] = f->list[i].type;
        uint32_t k = len - used < 24 ? len - used : 24; memcpy(mem + buf + used, hdr, k); used += k;
        if (used < len) { uint32_t m = len - used < nl ? len - used : nl; memcpy(mem + buf + used, f->list[i].name, m); used += m; }
    }
    put32(mem, usedp, used); RET(0); }

/* ---- path_* ---- */
#define RESOLVE(fd, pp, pl, follow, root, rel) char rel[PATH_MAX]; int root; { CHK(pp, pl); int _e = resolve(fd, mem, pp, pl, follow, &root, rel, sizeof rel); if (_e) RET(_e); }
CB(p_path_create_directory) { RESOLVE(A32(0), A32(1), A32(2), 0, root, rel); char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); if (!*rel) RET(W_EXIST); if (mkdir(hp, 0777)) return ERR(); RET(0); }
CB(p_path_remove_directory) { RESOLVE(A32(0), A32(1), A32(2), 0, root, rel); char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); if (!*rel) RET(W_BUSY); if (rmdir(hp)) return ERR(); RET(0); }
CB(p_path_unlink_file) { RESOLVE(A32(0), A32(1), A32(2), 0, root, rel); char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); struct stat st; if (lstat(hp, &st) == 0 && S_ISDIR(st.st_mode)) RET(W_ISDIR); if (unlink(hp)) return ERR(); RET(0); }
CB(p_path_filestat_get) { RESOLVE(A32(0), A32(2), A32(3), A32(1) & 1, root, rel); CHK(A32(4), 64); char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); struct stat st; if ((A32(1) & 1) ? stat(hp, &st) : lstat(hp, &st)) return ERR(); put_stat(mem, A32(4), &st); RET(0); }
CB(p_path_filestat_set_times) { RESOLVE(A32(0), A32(2), A32(3), A32(1) & 1, root, rel); uint32_t fl = A32(6); if (((fl & 1) && (fl & 2)) || ((fl & 4) && (fl & 8))) RET(W_INVAL);
    char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); struct timespec ts[2] = {{0, 0}, {0, 0}}; times_of(A64(4), A64(5), fl, ts); if (utimensat(AT_FDCWD, hp, ts, (A32(1) & 1) ? 0 : AT_SYMLINK_NOFOLLOW)) return ERR(); RET(0); }
CB(p_path_rename) { RESOLVE(A32(0), A32(1), A32(2), 0, r1, rel1); char rel2[PATH_MAX]; int r2; { CHK(A32(4), A32(5)); int e = resolve(A32(3), mem, A32(4), A32(5), 0, &r2, rel2, sizeof rel2); if (e) RET(e); }
    char h1[PATH_MAX], h2[PATH_MAX]; host_path(r1, rel1, h1, sizeof h1); host_path(r2, rel2, h2, sizeof h2); if (!*rel1 || !*rel2) RET(W_BUSY); if (rename(h1, h2)) return ERR(); RET(0); }
CB(p_path_link) { RESOLVE(A32(0), A32(2), A32(3), A32(1) & 1, r1, rel1); char rel2[PATH_MAX]; int r2; { CHK(A32(5), A32(6)); int e = resolve(A32(4), mem, A32(5), A32(6), 0, &r2, rel2, sizeof rel2); if (e) RET(e); }
    char h1[PATH_MAX], h2[PATH_MAX]; host_path(r1, rel1, h1, sizeof h1); host_path(r2, rel2, h2, sizeof h2); if (link(h1, h2)) return ERR(); RET(0); }
CB(p_path_symlink) { CHK(A32(0), A32(1)); char target[PATH_MAX]; if (A32(1) >= sizeof target) RET(W_NAMETOOLONG); memcpy(target, mem + A32(0), A32(1)); target[A32(1)] = 0;
    RESOLVE(A32(2), A32(3), A32(4), 0, root, rel); char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); if (symlink(target, hp)) return ERR(); RET(0); }
CB(p_path_readlink) { RESOLVE(A32(0), A32(1), A32(2), 0, root, rel); uint32_t buf = A32(3), len = A32(4), outp = A32(5); CHK(buf, len); CHK(outp, 4);
    char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); char tmp[PATH_MAX]; ssize_t n = readlink(hp, tmp, sizeof tmp); if (n < 0) return ERR(); uint32_t c = (uint32_t)n < len ? (uint32_t)n : len; memcpy(mem + buf, tmp, c); put32(mem, outp, c); RET(0); }
/* path_open(dirfd, dirflags, path, path_len, oflags, rights_base, rights_inheriting, fdflags, *opened) */
CB(p_path_open) { uint32_t dirflags = A32(1), oflags = A32(4), fdflags = A32(7), outp = A32(8); uint64_t rights = A64(5); int follow = dirflags & 1;
    RESOLVE(A32(0), A32(2), A32(3), follow, root, rel); CHK(outp, 4);
    char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp);
    struct stat st; int exists = (follow ? stat(hp, &st) : lstat(hp, &st)) == 0;
    int want_dir = (oflags & 2) != 0;
    if (exists && S_ISDIR(st.st_mode)) {
        if ((oflags & 1) && (oflags & 4)) RET(W_EXIST);
        if (oflags & 8) RET(W_ISDIR);
        if (rights & (1ull << 6)) RET(W_ISDIR);   /* fd_write on a directory */
        Fd f = { K_DIR, -1, root, strdup(rel), NULL, NULL, 0 }; put32(mem, outp, (uint32_t)fd_new(f)); RET(0);
    }
    if (want_dir) { if (!exists) RET(W_NOENT); RET(W_NOTDIR); }
    if (exists && S_ISLNK(st.st_mode) && !follow) RET(W_LOOP);
    int rd = (rights & ((1ull << 1) | (1ull << 14))) != 0, wr = (rights & ((1ull << 0) | (1ull << 6) | (1ull << 8) | (1ull << 22))) != 0;
    int fl = wr ? (rd ? O_RDWR : O_WRONLY) : O_RDONLY;
    if (oflags & 1) fl |= O_CREAT; if (oflags & 4) fl |= O_EXCL; if (oflags & 8) fl |= O_TRUNC;
    if (fdflags & 1) fl |= O_APPEND; if (fdflags & 4) fl |= O_NONBLOCK;
    int h = open(hp, fl, 0666); if (h < 0) return ERR();
    Fd f = { K_FILE, h, root, NULL, NULL, NULL, 0 }; put32(mem, outp, (uint32_t)fd_new(f)); RET(0); }

/* ---- poll_oneoff ---- */
CB(p_poll_oneoff) { uint32_t in = A32(0), out = A32(1), n = A32(2), nevp = A32(3); if (!n) RET(W_INVAL); CHK(in, 48ull * n); CHK(out, 32ull * n); CHK(nevp, 4);
    struct pollfd *pf = calloc(n, sizeof *pf); uint32_t *pidx = calloc(n, 4), *evs = calloc(n * 2, 4); uint64_t *dl = calloc(n, 8); uint8_t *isclk = calloc(n, 1);
    int npf = 0, nev = 0; uint64_t min_dl = UINT64_MAX; int immediate = 0;
    uint64_t tmono = now_ns(CLOCK_MONOTONIC);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t o = in + 48 * i; uint8_t tag = mem[o + 8];
        if (tag == 0) {   /* clock */
            uint32_t id = get32(mem, o + 16); uint64_t to = get64(mem, o + 24); uint16_t fl; memcpy(&fl, mem + o + 40, 2); clockid_t c;
            if (clk_of(id, &c)) { evs[nev++] = i | 0x80000000u; continue; }
            uint64_t wait = to; if (fl & 1) { uint64_t nowc = now_ns(c); wait = to > nowc ? to - nowc : 0; }
            dl[i] = tmono + wait; isclk[i] = 1; if (dl[i] < min_dl) min_dl = dl[i];
        } else if (tag == 1 || tag == 2) {
            Fd *f = fd_get(get32(mem, o + 16)); if (!f) { evs[nev++] = i | 0x40000000u; continue; }
            if (f->kind == K_DIR || f->kind == K_FILE) { evs[nev++] = i; immediate = 1; continue; }
            pf[npf].fd = f->hfd; pf[npf].events = tag == 1 ? POLLIN : POLLOUT; pidx[npf] = i; npf++;
        } else { evs[nev++] = i | 0x40000000u; }
    }
    if (!immediate && nev == 0) {
        for (;;) {
            uint64_t t = now_ns(CLOCK_MONOTONIC); int tmo = -1;
            if (min_dl != UINT64_MAX) { uint64_t rem = min_dl > t ? min_dl - t : 0; tmo = rem > 2000000000ull ? 2000 : (int)((rem + 999999) / 1000000); }
            int pr = 0;
            if (npf) { pr = poll(pf, (nfds_t)npf, tmo); if (pr < 0) { if (errno == EINTR) continue; /* a descriptor the OS cannot poll: report it ready */ for (int k = 0; k < npf; k++) evs[nev++] = pidx[k]; break; } }
            else if (min_dl != UINT64_MAX) { uint64_t rem = min_dl > t ? min_dl - t : 0; struct timespec ts = { (time_t)(rem / 1000000000ull), (long)(rem % 1000000000ull) }; nanosleep(&ts, NULL); }
            for (int k = 0; k < npf; k++) if (pf[k].revents) evs[nev++] = pidx[k];
            uint64_t t2 = now_ns(CLOCK_MONOTONIC);
            for (uint32_t i = 0; i < n; i++) if (isclk[i] && dl[i] <= t2) evs[nev++] = i;
            if (nev) break;
            if (min_dl != UINT64_MAX && t2 >= min_dl) break;
        }
    } else {
        /* something is ready already: also report sockets/pipes that are ready right now, and clocks that have expired */
        if (npf) { int pr = poll(pf, (nfds_t)npf, 0); if (pr > 0) for (int k = 0; k < npf; k++) if (pf[k].revents) evs[nev++] = pidx[k]; }
        uint64_t t2 = now_ns(CLOCK_MONOTONIC); for (uint32_t i = 0; i < n; i++) if (isclk[i] && dl[i] <= t2) evs[nev++] = i;
    }
    uint32_t w = 0;
    for (int k = 0; k < nev; k++) {
        uint32_t i = evs[k] & 0x3FFFFFFF; uint32_t o = in + 48 * i; uint32_t bad = (evs[k] & 0xC0000000u);
        memset(mem + out + 32 * w, 0, 32); memcpy(mem + out + 32 * w, mem + o, 8); mem[out + 32 * w + 10] = mem[o + 8];
        uint16_t e = bad ? (uint16_t)((bad & 0x80000000u) ? W_INVAL : W_BADF) : 0; memcpy(mem + out + 32 * w + 8, &e, 2);
        w++;
    }
    put32(mem, nevp, w);
    free(pf); free(pidx); free(evs); free(dl); free(isclk); RET(0); }

/* ---- sockets (descriptors the host pre-opened, and the ones accepted from them) ---- */
CB(p_sock_accept) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind != K_LISTEN) RET(W_NOTSOCK); CHK(A32(2), 4); int c = accept(f->hfd, NULL, NULL); if (c < 0) return ERR();
    if (A32(1) & 4) fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK); Fd nf = { K_SOCK, c, -1, NULL, NULL, NULL, 0 }; put32(mem, A32(2), (uint32_t)fd_new(nf)); RET(0); }
CB(p_sock_recv) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind != K_SOCK) RET(W_NOTSOCK); uint32_t iov = A32(1), n = A32(2), fl = A32(3), np = A32(4), rop = A32(5); CHK(iov, 8ull * n); CHK(np, 4); CHK(rop, 2);
    int flags = (fl & 1) ? MSG_PEEK : 0; if (fl & 2) flags |= MSG_WAITALL; uint32_t total = 0;
    for (uint32_t i = 0; i < n; i++) { uint32_t p = get32(mem, iov + 8 * i), l = get32(mem, iov + 8 * i + 4); if (!l) continue; CHK(p, l); ssize_t g = recv(f->hfd, mem + p, l, flags); if (g < 0) { if (total) break; return ERR(); } total += (uint32_t)g; break; }
    put32(mem, np, total); memset(mem + rop, 0, 2); RET(0); }
CB(p_sock_send) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind != K_SOCK) RET(W_NOTSOCK); uint32_t iov = A32(1), n = A32(2), np = A32(4); CHK(iov, 8ull * n); CHK(np, 4); uint32_t total = 0;
    for (uint32_t i = 0; i < n; i++) { uint32_t p = get32(mem, iov + 8 * i), l = get32(mem, iov + 8 * i + 4); if (!l) continue; CHK(p, l); uint32_t done = 0; while (done < l) { ssize_t w = send(f->hfd, mem + p + done, l - done, 0); if (w < 0) { if (errno == EINTR) continue; if (total + done) goto out; return ERR(); } done += (uint32_t)w; } total += done; }
out: put32(mem, np, total); RET(0); }
CB(p_sock_shutdown) { Fd *f = fd_get(A32(0)); if (!f) RET(W_BADF); if (f->kind != K_SOCK) RET(W_NOTSOCK); uint32_t h = A32(1); int how = (h == 1) ? SHUT_RD : (h == 2) ? SHUT_WR : (h == 3) ? SHUT_RDWR : -1; if (how < 0) RET(W_INVAL); if (shutdown(f->hfd, how)) return ERR(); RET(0); }

int wasi_p1_register(void) {
    init_fds();
    const char *W = "wasi_snapshot_preview1"; int rc = 0;
    #define D(name, sig, fn) rc |= wn_define(W, name, sig, fn, 0)
    D("args_get", "ii>i", p_args_get); D("args_sizes_get", "ii>i", p_args_sizes_get); D("environ_get", "ii>i", p_environ_get); D("environ_sizes_get", "ii>i", p_environ_sizes_get);
    D("clock_res_get", "ii>i", p_clock_res_get); D("clock_time_get", "ili>i", p_clock_time_get);
    D("fd_advise", "illi>i", p_fd_advise); D("fd_allocate", "ill>i", p_fd_allocate); D("fd_close", "i>i", p_fd_close); D("fd_datasync", "i>i", p_fd_datasync);
    D("fd_fdstat_get", "ii>i", p_fd_fdstat_get); D("fd_fdstat_set_flags", "ii>i", p_fd_fdstat_set_flags); D("fd_fdstat_set_rights", "ill>i", p_fd_fdstat_set_rights);
    D("fd_filestat_get", "ii>i", p_fd_filestat_get); D("fd_filestat_set_size", "il>i", p_fd_filestat_set_size); D("fd_filestat_set_times", "illi>i", p_fd_filestat_set_times);
    D("fd_pread", "iiili>i", p_fd_pread); D("fd_prestat_get", "ii>i", p_fd_prestat_get); D("fd_prestat_dir_name", "iii>i", p_fd_prestat_dir_name); D("fd_pwrite", "iiili>i", p_fd_pwrite);
    D("fd_read", "iiii>i", p_fd_read); D("fd_readdir", "iiili>i", p_fd_readdir); D("fd_renumber", "ii>i", p_fd_renumber); D("fd_seek", "ilii>i", p_fd_seek); D("fd_sync", "i>i", p_fd_sync);
    D("fd_tell", "ii>i", p_fd_tell); D("fd_write", "iiii>i", p_fd_write);
    D("path_create_directory", "iii>i", p_path_create_directory); D("path_filestat_get", "iiiii>i", p_path_filestat_get); D("path_filestat_set_times", "iiiilli>i", p_path_filestat_set_times);
    D("path_link", "iiiiiii>i", p_path_link); D("path_open", "iiiiillii>i", p_path_open); D("path_readlink", "iiiiii>i", p_path_readlink); D("path_remove_directory", "iii>i", p_path_remove_directory);
    D("path_rename", "iiiiii>i", p_path_rename); D("path_symlink", "iiiii>i", p_path_symlink); D("path_unlink_file", "iii>i", p_path_unlink_file);
    D("poll_oneoff", "iiii>i", p_poll_oneoff); D("proc_exit", "i", p_proc_exit); D("proc_raise", "i>i", p_proc_raise); D("sched_yield", ">i", p_sched_yield); D("random_get", "ii>i", p_random_get);
    D("sock_accept", "iii>i", p_sock_accept); D("sock_recv", "iiiiii>i", p_sock_recv); D("sock_send", "iiiii>i", p_sock_send); D("sock_shutdown", "ii>i", p_sock_shutdown);
    return rc;
}

/* ======================================================================================================================================================
 * Support for the preview 2 host (written in Rust, embedding/src/p2.rs): the same sandbox (pre-opened roots, lexical + real-path check) and the same C library
 * calls, behind plain-typed functions. Every function returns a value >= 0 or minus a WASI preview 1 errno.
 * ====================================================================================================================================================== */
#define NEG() (-werr(errno))
int wn_fs_count(void) { return nroots; }
const char *wn_fs_guest_name(int i) { for (int k = 0, n = 0; k < nfds; k++) if (fds[k].kind == K_DIR && fds[k].gname && !*fds[k].rel) { if (n++ == i) return fds[k].gname; } return NULL; }
int wn_fs_root_of(int i) { for (int k = 0, n = 0; k < nfds; k++) if (fds[k].kind == K_DIR && fds[k].gname && !*fds[k].rel) { if (n++ == i) return fds[k].root; } return -1; }
/* resolves `path` relative to directory (root, base_rel); result in out_rel */
int wn_fs_resolve(int root, const char *base_rel, const char *path, int follow, char *out_rel, size_t cap) {
    if (root < 0 || root >= nroots) return -W_BADF;
    int e = norm_path(base_rel, path, strlen(path), out_rel, cap); if (e) return -e;
    e = symlink_check(root, out_rel, follow); return e ? -e : 0;
}
static int stat_out(const struct stat *st, uint64_t out[8]) {
    out[0] = wtype(st->st_mode); out[1] = (uint64_t)st->st_nlink; out[2] = (uint64_t)st->st_size;
    out[3] = (uint64_t)st->st_atim.tv_sec * 1000000000ull + (uint64_t)st->st_atim.tv_nsec; out[4] = (uint64_t)st->st_mtim.tv_sec * 1000000000ull + (uint64_t)st->st_mtim.tv_nsec;
    out[5] = (uint64_t)st->st_ctim.tv_sec * 1000000000ull + (uint64_t)st->st_ctim.tv_nsec; out[6] = (uint64_t)st->st_ino; out[7] = (uint64_t)st->st_dev; return 0;
}
int wn_fs_stat(int root, const char *rel, int follow, uint64_t out[8]) { char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); struct stat st; if ((follow ? stat(hp, &st) : lstat(hp, &st))) return NEG(); return stat_out(&st, out); }
int wn_fs_fstat(int hfd, uint64_t out[8]) { struct stat st; if (fstat(hfd, &st)) return NEG(); return stat_out(&st, out); }
int wn_fs_open(int root, const char *rel, int rd, int wr, int creat, int excl, int trunc, int append) {
    char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); int fl = wr ? (rd ? O_RDWR : O_WRONLY) : O_RDONLY;
    if (creat) fl |= O_CREAT; if (excl) fl |= O_EXCL; if (trunc) fl |= O_TRUNC; if (append) fl |= O_APPEND;
    int h = open(hp, fl, 0666); return h < 0 ? NEG() : h;
}
int wn_fs_dup(int hfd) { int h = dup(hfd); return h < 0 ? NEG() : h; }
int wn_fs_close(int hfd) { return close(hfd) ? NEG() : 0; }
int64_t wn_fs_pread(int hfd, uint8_t *p, size_t n, uint64_t off) { ssize_t g = pread(hfd, p, n, (off_t)off); return g < 0 ? NEG() : g; }
int64_t wn_fs_pwrite(int hfd, const uint8_t *p, size_t n, uint64_t off) { ssize_t g = pwrite(hfd, p, n, (off_t)off); return g < 0 ? NEG() : g; }
int64_t wn_c_write(int hfd, const uint8_t *p, size_t n) { if (hfd == 1) fflush(stdout); else if (hfd == 2) fflush(stderr); ssize_t g = write(hfd, p, n); return g < 0 ? NEG() : g; }
int64_t wn_c_read(int hfd, uint8_t *p, size_t n) { ssize_t g = read(hfd, p, n); return g < 0 ? NEG() : g; }
/* 1 ready, 0 not ready within timeout_ms, < 0 error; descriptors the OS cannot poll (regular files) are always ready */
int wn_c_poll(int hfd, int for_write, int timeout_ms) {
    struct stat st; if (fstat(hfd, &st) == 0 && S_ISREG(st.st_mode)) return 1;
    struct pollfd p = { hfd, (short)(for_write ? POLLOUT : POLLIN), 0 }; int r = poll(&p, 1, timeout_ms); if (r < 0) return 1; return r > 0;
}
int wn_fs_mkdir(int root, const char *rel) { char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); if (!*rel) return -W_EXIST; return mkdir(hp, 0777) ? NEG() : 0; }
int wn_fs_rmdir(int root, const char *rel) { char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); if (!*rel) return -W_BUSY; return rmdir(hp) ? NEG() : 0; }
int wn_fs_unlink(int root, const char *rel) { char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); struct stat st; if (lstat(hp, &st) == 0 && S_ISDIR(st.st_mode)) return -W_ISDIR; return unlink(hp) ? NEG() : 0; }
int wn_fs_rename(int r1, const char *rel1, int r2, const char *rel2) { char a[PATH_MAX], b[PATH_MAX]; host_path(r1, rel1, a, sizeof a); host_path(r2, rel2, b, sizeof b); if (!*rel1 || !*rel2) return -W_BUSY; return rename(a, b) ? NEG() : 0; }
int wn_fs_link(int r1, const char *rel1, int r2, const char *rel2) { char a[PATH_MAX], b[PATH_MAX]; host_path(r1, rel1, a, sizeof a); host_path(r2, rel2, b, sizeof b); return link(a, b) ? NEG() : 0; }
int wn_fs_symlink(const char *target, int root, const char *rel) { char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); return symlink(target, hp) ? NEG() : 0; }
int wn_fs_readlink(int root, const char *rel, char *buf, size_t cap) { char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); ssize_t n = readlink(hp, buf, cap); return n < 0 ? NEG() : (int)n; }
int wn_fs_ftruncate(int hfd, uint64_t size) { return ftruncate(hfd, (off_t)size) ? NEG() : 0; }
int wn_fs_fsync(int hfd, int data_only) { return (data_only ? fdatasync(hfd) : fsync(hfd)) ? NEG() : 0; }
/* modes: 0 leave, 1 now, 2 set to ns */
int wn_fs_utimens(int root, const char *rel, int follow, int am, uint64_t ans, int mm, uint64_t mns) {
    char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); struct timespec ts[2];
    ts[0].tv_sec = (time_t)(ans / 1000000000ull); ts[0].tv_nsec = am == 0 ? UTIME_OMIT : am == 1 ? UTIME_NOW : (long)(ans % 1000000000ull);
    ts[1].tv_sec = (time_t)(mns / 1000000000ull); ts[1].tv_nsec = mm == 0 ? UTIME_OMIT : mm == 1 ? UTIME_NOW : (long)(mns % 1000000000ull);
    return utimensat(AT_FDCWD, hp, ts, follow ? 0 : AT_SYMLINK_NOFOLLOW) ? NEG() : 0;
}
int wn_fs_futimens(int hfd, int am, uint64_t ans, int mm, uint64_t mns) {
    struct timespec ts[2];
    ts[0].tv_sec = (time_t)(ans / 1000000000ull); ts[0].tv_nsec = am == 0 ? UTIME_OMIT : am == 1 ? UTIME_NOW : (long)(ans % 1000000000ull);
    ts[1].tv_sec = (time_t)(mns / 1000000000ull); ts[1].tv_nsec = mm == 0 ? UTIME_OMIT : mm == 1 ? UTIME_NOW : (long)(mns % 1000000000ull);
    return futimens(hfd, ts) ? NEG() : 0;
}
/* directory listing in one buffer: for each entry u8 type, u32 name length, name bytes; "." and ".." are not included (the guest library adds nothing; wasi:filesystem says they are omitted). Free with wn_free. */
int wn_fs_readdir(int root, const char *rel, uint8_t **out, size_t *len) {
    char hp[PATH_MAX]; host_path(root, rel, hp, sizeof hp); DIR *d = opendir(hp); if (!d) return NEG();
    size_t cap = 4096, n = 0; uint8_t *b = malloc(cap); struct dirent *e;
    DirEnt *ents = NULL; size_t ne = 0, ce = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char ep[PATH_MAX]; snprintf(ep, sizeof ep, "%s/%s", hp, e->d_name); struct stat st; uint8_t ty = 0; if (lstat(ep, &st) == 0) ty = wtype(st.st_mode);
        if (ne == ce) { ce = ce ? ce * 2 : 16; ents = realloc(ents, ce * sizeof *ents); }
        ents[ne].name = strdup(e->d_name); ents[ne].type = ty; ents[ne].ino = 0; ne++;
    }
    closedir(d); qsort(ents, ne, sizeof *ents, cmp_ent);
    for (size_t i = 0; i < ne; i++) {
        uint32_t nl = (uint32_t)strlen(ents[i].name);
        if (n + 5 + nl > cap) { while (n + 5 + nl > cap) cap *= 2; b = realloc(b, cap); }
        b[n] = ents[i].type; memcpy(b + n + 1, &nl, 4); memcpy(b + n + 5, ents[i].name, nl); n += 5 + nl; free(ents[i].name);
    }
    free(ents); *out = b; *len = n; return 0;
}
void wn_free(void *p) { free(p); }
uint64_t wn_c_clock_ns(int id) { return now_ns(id == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC); }
uint64_t wn_c_clock_res_ns(int id) { struct timespec t; if (clock_getres(id == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &t)) return 1000; return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
void wn_c_sleep_ns(uint64_t ns) { struct timespec t = { (time_t)(ns / 1000000000ull), (long)(ns % 1000000000ull) }; nanosleep(&t, NULL); }
int wn_c_random(uint8_t *p, size_t n) { size_t done = 0; while (done < n) { size_t k = n - done > 256 ? 256 : n - done; ssize_t g = getrandom(p + done, k, 0); if (g <= 0) return -W_IO; done += (size_t)g; } return 0; }
void wn_out(const uint8_t *msg, size_t len) { fwrite(msg, 1, len, stdout); fflush(stdout); }

/* ======================================================================================================================================================
 * TCP sockets and name lookup for the preview 2 host (wasi:sockets). Families: 0 = IPv4, 1 = IPv6. Socket addresses travel as 32 bytes:
 * [0] family, [2..3] port (u16), [4..7] flow info (u32), [8..11] scope id (u32), [12..27] address (16 bytes; IPv4 uses the first 4).
 * ====================================================================================================================================================== */
#include <netdb.h>
#include <netinet/tcp.h>
static int sa_from(const uint8_t *a, struct sockaddr_storage *ss, socklen_t *len) {
    memset(ss, 0, sizeof *ss); uint16_t port; memcpy(&port, a + 2, 2);
    if (a[0] == 0) { struct sockaddr_in *s = (struct sockaddr_in *)ss; s->sin_family = AF_INET; s->sin_port = htons(port); memcpy(&s->sin_addr, a + 12, 4); *len = sizeof *s; }
    else { struct sockaddr_in6 *s = (struct sockaddr_in6 *)ss; s->sin6_family = AF_INET6; s->sin6_port = htons(port); memcpy(&s->sin6_addr, a + 12, 16); memcpy(&s->sin6_flowinfo, a + 4, 4); memcpy(&s->sin6_scope_id, a + 8, 4); *len = sizeof *s; }
    return 0;
}
static void sa_to(const struct sockaddr_storage *ss, uint8_t *a) {
    memset(a, 0, 32);
    if (ss->ss_family == AF_INET) { const struct sockaddr_in *s = (const struct sockaddr_in *)ss; a[0] = 0; uint16_t p = ntohs(s->sin_port); memcpy(a + 2, &p, 2); memcpy(a + 12, &s->sin_addr, 4); }
    else { const struct sockaddr_in6 *s = (const struct sockaddr_in6 *)ss; a[0] = 1; uint16_t p = ntohs(s->sin6_port); memcpy(a + 2, &p, 2); memcpy(a + 4, &s->sin6_flowinfo, 4); memcpy(a + 8, &s->sin6_scope_id, 4); memcpy(a + 12, &s->sin6_addr, 16); }
}
int wn_sock_create(int family) { int s = socket(family ? AF_INET6 : AF_INET, SOCK_STREAM, 0); if (s < 0) return NEG(); int fl = fcntl(s, F_GETFL); if (fl >= 0) fcntl(s, F_SETFL, fl | O_NONBLOCK); if (family) { int on = 1; setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, (void *)&on, sizeof on); } return s; }
int wn_sock_bind(int fd, const uint8_t *a) {
    struct sockaddr_storage ss; socklen_t l; sa_from(a, &ss, &l);
    int one = 1; if (!IsWindows()) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (void *)&one, sizeof one);   /* like the usual host implementations on Unix; Windows SO_REUSEADDR means something else */
    return bind(fd, (struct sockaddr *)&ss, l) ? NEG() : 0;
}
/* 0 connected at once, 1 in progress, < 0 error */
int wn_sock_connect(int fd, const uint8_t *a) { struct sockaddr_storage ss; socklen_t l; sa_from(a, &ss, &l); if (connect(fd, (struct sockaddr *)&ss, l) == 0) return 0; if (errno == EINPROGRESS || errno == EWOULDBLOCK || errno == EAGAIN || errno == EALREADY) return 1; return NEG(); }
/* 0 finished ok, 1 not finished, < 0 error */
int wn_sock_finish_connect(int fd) {
    struct pollfd p = { fd, POLLOUT, 0 }; int r = poll(&p, 1, 0); if (r < 0) return NEG(); if (r == 0) return 1;
    int err = 0; socklen_t l = sizeof err; if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (void *)&err, &l)) return NEG(); if (err) { errno = err; return NEG(); }
    if (p.revents & (POLLERR | POLLHUP) && !(p.revents & POLLOUT)) return -W_CONNREFUSED;
    return 0;
}
int wn_sock_listen(int fd, int backlog) { return listen(fd, backlog) ? NEG() : 0; }
/* new fd (non-blocking) or < 0 */
int wn_sock_accept(int fd, uint8_t *peer32) { struct sockaddr_storage ss; socklen_t l = sizeof ss; int c = accept(fd, (struct sockaddr *)&ss, &l); if (c < 0) return NEG(); int fl = fcntl(c, F_GETFL); if (fl >= 0) fcntl(c, F_SETFL, fl | O_NONBLOCK); sa_to(&ss, peer32); return c; }
int wn_sock_name(int fd, int peer, uint8_t *out32) { struct sockaddr_storage ss; socklen_t l = sizeof ss; if ((peer ? getpeername(fd, (struct sockaddr *)&ss, &l) : getsockname(fd, (struct sockaddr *)&ss, &l))) return NEG(); sa_to(&ss, out32); return 0; }
int wn_sock_shutdown(int fd, int how) { return shutdown(fd, how == 0 ? SHUT_RD : how == 1 ? SHUT_WR : SHUT_RDWR) ? NEG() : 0; }
int64_t wn_sock_recv(int fd, uint8_t *p, size_t n) { ssize_t g = recv(fd, p, n, 0); return g < 0 ? NEG() : g; }
int64_t wn_sock_send(int fd, const uint8_t *p, size_t n) { ssize_t g = send(fd, p, n, 0); return g < 0 ? NEG() : g; }
/* which: 1 keep-alive enabled, 2 receive buffer, 3 send buffer, 4 hop limit (unicast), 5 listen-backlog is not an option. set: 1 write `*v` */
int wn_sock_opt(int fd, int which, int set, uint64_t *v) {
    int level = SOL_SOCKET, opt = 0;
    switch (which) { case 1: opt = SO_KEEPALIVE; break; case 2: opt = SO_RCVBUF; break; case 3: opt = SO_SNDBUF; break; case 4: level = IPPROTO_IP; opt = IP_TTL; break; default: return -W_NOTSUP; }
    int x = (int)*v; socklen_t l = sizeof x;
    if (set) return setsockopt(fd, level, opt, (void *)&x, sizeof x) ? NEG() : 0;
    if (getsockopt(fd, level, opt, (void *)&x, &l)) return NEG(); *v = (uint64_t)(uint32_t)x; return 0;
}
/* name lookup: returns the number of addresses (>= 0) written to `out` as 17-byte records (family, 16 address bytes), at most `max`; < 0 is minus a resolver code: 1 not found, 2 temporary, 3 permanent */
int wn_resolve(const char *name, uint8_t *out, int max) {
    struct addrinfo hints, *res = NULL; memset(&hints, 0, sizeof hints); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    int r = getaddrinfo(name, NULL, &hints, &res); if (r) return (r == EAI_AGAIN) ? -2 : (r == EAI_FAIL) ? -3 : -1;
    int n = 0;
    for (struct addrinfo *a = res; a && n < max; a = a->ai_next) {
        if (a->ai_family == AF_INET) { struct sockaddr_in *s = (struct sockaddr_in *)a->ai_addr; out[n * 17] = 0; memset(out + n * 17 + 1, 0, 16); memcpy(out + n * 17 + 1, &s->sin_addr, 4); n++; }
        else if (a->ai_family == AF_INET6) { struct sockaddr_in6 *s = (struct sockaddr_in6 *)a->ai_addr; out[n * 17] = 1; memcpy(out + n * 17 + 1, &s->sin6_addr, 16); n++; }
    }
    freeaddrinfo(res); return n;
}
