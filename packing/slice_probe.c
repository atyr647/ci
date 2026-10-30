// Can machine code that sits inside the executable (as a zip-stored "slice") be made executable at run time WITHOUT extracting it to a file, on every OS?
// Each test runs in its own process (a refusal can kill the process).   usage: slice_probe <test>
//  copy-rx   : copy the bytes into anonymous memory (RW), mprotect(RX), call it
//  map-rx    : mmap the executable file itself with PROT_READ|PROT_EXEC at the page holding the bytes, call it in place (no copy, shared page cache)
//  map-rw-rx : mmap the file PRIVATE with PROT_READ|PROT_WRITE, mprotect(RX), call
//  rwx       : anonymous memory mapped RWX directly
#define _COSMO_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <cosmo.h>

#if defined(__x86_64__)
static const unsigned char code[] = { 'S','L','I','C','E','P','R','O','B','E','_','x','8','6','_', 0, 0xB8, 0x2A, 0, 0, 0, 0xC3 };      // mov eax,42 ; ret
#elif defined(__aarch64__)
static const unsigned char code[] = { 'S','L','I','C','E','P','R','O','B','E','_','a','r','m','_', 0, 0x40, 0x05, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6 };   // mov w0,#42 ; ret
#endif
#define MARK 16

static long find_in_file(const char *path, unsigned char **buf, size_t *len) {
    FILE *f = fopen(path, "rb"); if (!f) return -1;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    *buf = malloc(n); if (fread(*buf, 1, n, f) != (size_t)n) return -1; fclose(f); *len = n;
    for (long i = 0; i + (long)sizeof code <= n; i++) if (!memcmp(*buf + i, code, MARK)) return i;
    return -1;
}
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    const char *t = argv[1]; int (*fn)(void) = NULL; long pg = sysconf(_SC_PAGESIZE);
    if (!strcmp(t, "info")) { printf("os=%s pagesize=%ld\n", IsWindows() ? "windows" : IsXnu() ? "macos" : IsLinux() ? "linux" : "other", pg); return 0; }
    if (!strcmp(t, "copy-rx") || !strcmp(t, "rwx")) {
        void *p = mmap(NULL, pg, PROT_READ | PROT_WRITE | (!strcmp(t, "rwx") ? PROT_EXEC : 0), MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) { perror("mmap"); return 3; }
        memcpy(p, code + MARK, sizeof code - MARK);
        if (strcmp(t, "rwx")) { if (mprotect(p, pg, PROT_READ | PROT_EXEC)) { perror("mprotect"); return 4; } }
        fn = (int (*)(void))p;
    } else {
        const char *exe = GetProgramExecutableName(); unsigned char *b; size_t n; long off = find_in_file(exe, &b, &n);
        if (off < 0) { printf("marker not found in %s\n", exe); return 5; }
        off += MARK; long base = off & ~(pg - 1);
        int fd = open(exe, O_RDONLY); if (fd < 0) { perror("open"); return 6; }
        void *p;
        if (!strcmp(t, "map-rx")) p = mmap(NULL, pg, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, base);
        else { p = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, base); if (p != MAP_FAILED && mprotect(p, pg, PROT_READ | PROT_EXEC)) { perror("mprotect"); return 4; } }
        if (p == MAP_FAILED) { perror("mmap"); return 3; }
        fn = (int (*)(void))((char *)p + (off - base));
    }
    int r = fn(); printf("%s: called, result %d\n", t, r); return r == 42 ? 0 : 1;
}
