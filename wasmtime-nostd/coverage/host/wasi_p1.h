/* WASI preview 1 (wasi_snapshot_preview1) host in C on top of the Cosmopolitan C library: one implementation for Linux, macOS and Windows. */
#ifndef WASI_P1_H
#define WASI_P1_H
#include <stdint.h>
#include <stddef.h>

int32_t wn_define(const char *module, const char *name, const char *sig, int32_t (*cb)(void *, uint8_t *, size_t, const uint64_t *, uint64_t *), void *user);

int  wasi_add_preopen(const char *guest_name, const char *host_path);      /* 0 ok */
void wasi_set_args(int argc, char **argv);                                  /* guest argv (copied pointers, not strings) */
void wasi_add_env(const char *kv);                                          /* "K=V" */
int  wasi_add_tcp_listen(const char *ip, int port, int *bound_port);        /* pre-opened listening socket; its guest fd is returned in wasi_listen_fd() */
int  wasi_listen_fd(void);
int  wasi_p1_register(void);                                                /* wn_define for every function; 0 ok */
extern uint64_t wasi_p1_calls;                                              /* number of p1 calls served */
#endif
