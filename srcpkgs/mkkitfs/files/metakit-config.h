/* config.h for building the Metakit fork's C++ library inside mkkitfs (Linux, glibc or musl).
   Metakit's own unix/configure would find the same; mkkitfs only needs the library, so it
   compiles src/*.cpp itself with this file as config.h. */
#define HAVE_BCOPY 1
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LONG_LONG 1
#define HAVE_MEMMOVE 1
#define HAVE_MEMORY_H 1
#define HAVE_MMAP 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1
#if defined(__LP64__)
#define SIZEOF_LONG 8
#else
#define SIZEOF_LONG 4
#endif
