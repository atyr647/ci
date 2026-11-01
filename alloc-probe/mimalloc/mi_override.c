// Replaces the Cosmopolitan C library's malloc family with mimalloc (compiled in from src/static.c). Each function of Cosmopolitan's malloc lives in its own archive member, so defining the
// public names here takes precedence over the library's. Link with: mi_static.o mi_override.o.
#include <errno.h>
#include <mimalloc.h>
#include <stddef.h>
#include <stdint.h>

void *malloc(size_t n) { return mi_malloc(n); }
void free(void *p) { mi_free(p); }
void *calloc(size_t a, size_t b) { return mi_calloc(a, b); }
void *realloc(void *p, size_t n) { return mi_realloc(p, n); }
void *memalign(size_t al, size_t n) { return mi_memalign(al, n); }
int posix_memalign(void **p, size_t al, size_t n) { return mi_posix_memalign(p, al, n); }
void *aligned_alloc(size_t al, size_t n) { return mi_aligned_alloc(al, n); }
void *valloc(size_t n) { return mi_valloc(n); }
void *pvalloc(size_t n) { return mi_pvalloc(n); }
void *reallocarray(void *p, size_t a, size_t b) { return mi_reallocarray(p, a, b); }
size_t malloc_usable_size(void *p) { return mi_usable_size(p); }
