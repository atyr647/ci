// Force-included when SwiftShader is compiled with the Cosmopolitan compiler: the few Linux-only declarations the sources use and that Cosmopolitan's headers do not provide.
// Everything here is either not needed at run time in this use (backtraces, debugger detection, the loader's module query) or has an obvious portable meaning.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
#ifndef RTLD_NOLOAD
#define RTLD_NOLOAD 4
#endif
typedef struct { const char *dli_fname; void *dli_fbase; const char *dli_sname; void *dli_saddr; } Dl_info;
static inline int dladdr(const void *a, Dl_info *i) { (void)a; if (i) { i->dli_fname = 0; i->dli_fbase = 0; i->dli_sname = 0; i->dli_saddr = 0; } return 0; }
static inline int backtrace(void **b, int n) { (void)b; (void)n; return 0; }
static inline void backtrace_symbols_fd(void *const *b, int n, int fd) { (void)b; (void)n; (void)fd; }
long syscall(long, ...);   // exists in the C library; Cosmopolitan declares it only for its own source mode
#ifdef __cplusplus
}
#endif
