/* Declarations shared between platform.c, the Rust side and the test host. */
#ifndef WN_PLATFORM_H
#define WN_PLATFORM_H
#include <stdint.h>
/* what the signal handler of the last trap on the calling thread saw */
struct WnFault {
    int signo, code;
    uintptr_t ip;        /* faulting instruction */
    uintptr_t si_addr;   /* what the C library put in siginfo (on Windows: the instruction address) */
    uintptr_t addr;      /* the address handed to Wasmtime (0 when unknown) */
    int has_addr;
    int source;          /* 0 siginfo, 1 Windows exception record, 2 unknown */
};
const struct WnFault *wn_last_fault(void);
int32_t wn_atomic_wait(const uint8_t *addr, uint32_t size, uint64_t expected, int64_t timeout_ns);
uint32_t wn_atomic_notify(const uint8_t *addr, uint32_t count);
#endif
