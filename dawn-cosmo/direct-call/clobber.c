// A "foreign" library built by the platform's own compiler (glibc, normal register use). Functions here do what real driver code may do:
// use x28 as a general register, and use thread-local storage of its own.
#include <stdint.h>
#ifdef __aarch64__
// keeps a counter in x28 for n iterations (x28 is callee-saved, so the compiler saves and restores it around the asm; during the loop it holds a small integer, not a pointer)
long clobber_spin(long n) {
  long out;
  __asm__ volatile("mov x28, %1\n1: subs x28, x28, #1\n b.ne 1b\n mov %0, x28" : "=r"(out) : "r"(n) : "x28", "cc");
  return out;
}
#else
long clobber_spin(long n) { volatile long x = n; while (x > 0) x--; return 0; }
#endif
long clobber_nop(long v) { return v + 1; }
static __thread long tls_value;     // glibc TLS of this library (the thread register of the foreign code)
long clobber_tls(long add) { tls_value += add; return tls_value; }
