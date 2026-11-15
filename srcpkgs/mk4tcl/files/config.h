/* config.h for Mk4tcl from the Metakit fork (Linux, glibc or musl), in place of the one its 2007
   TEA configure writes: that one leaves every macro #undef'd, which picks a 64-bit t4_i32 on
   x86_64 (a build error) and silently turns mmap off (kit/poc/01-mk4tcl-build). */
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
