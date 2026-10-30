/* A Cosmopolitan program that loads a system library at run time (what a GPU program does with vulkan-1.dll, libvulkan.so, Metal frameworks):
 * a different static footprint from a program that loads nothing, used for the antivirus verdicts. */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <dlfcn.h>
#include <cosmo.h>
int main(void) {
    const char *lib = IsWindows() ? "kernel32.dll" : IsXnu() ? "/usr/lib/libSystem.B.dylib" : "libc.so.6";
    const char *sym = IsWindows() ? "GetCurrentProcessId" : "getpid";
    void *h = cosmo_dlopen(lib, RTLD_NOW);
    if (!h) { printf("dl: dlopen(%s) failed: %s\n", lib, cosmo_dlerror()); return 2; }
    void *f = cosmo_dlsym(h, sym);
    printf("dl: loaded %s, symbol %s %s\n", lib, sym, f ? "resolved" : "NOT FOUND");
    return f ? 0 : 3;
}
