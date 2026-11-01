// mimalloc's thread id through the C library (pthread_self) instead of the thread register: Cosmopolitan runs on Linux, Windows and macOS with different thread registers.
#include <pthread.h>
#include <stdint.h>
static inline uintptr_t mi_cosmo_tid(void) { return (uintptr_t)pthread_self(); }
