/* Wasm guest: wasip1 core module. Talks to the host through the same five-function shape as celori:wire/transport. */
#include <stdio.h>
#include <string.h>
__attribute__((import_module("celori:wire/transport@0.1.0"), import_name("send"))) int wire_send(const void *p, unsigned n);
__attribute__((import_module("celori:wire/transport@0.1.0"), import_name("recv"))) int wire_recv(void *p, unsigned max);
int main(void) {
  const char msg[] = "ping from wasm";
  int r = wire_send(msg, sizeof msg - 1);
  char buf[64] = {0}; int n = wire_recv(buf, sizeof buf - 1);
  printf("guest: send -> %d, recv -> %d bytes: \"%s\"\n", r, n, buf);
  return n == 9 ? 0 : 3;
}
