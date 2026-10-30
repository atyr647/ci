/* TCP over loopback inside one guest (wasm32-wasip2): listener on an ephemeral port, client connect, accept, data both ways with a hash, shutdown, name lookup. Single thread. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <poll.h>
#include <stdint.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

static int pass, fail;
#define CHECK(name, cond) do { int ok_ = !!(cond); if (ok_) pass++; else fail++; printf("%s %s\n", ok_ ? "ok  " : "FAIL", name); if (!ok_) printf("       (errno %d)\n", errno); } while (0)
static uint64_t fnv(const unsigned char *p, size_t n, uint64_t h) { for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; } return h; }
static int send_all(int fd, const unsigned char *p, size_t n) { size_t d = 0; while (d < n) { ssize_t w = send(fd, p + d, n - d, 0); if (w <= 0) return -1; d += (size_t)w; } return 0; }
static int recv_all(int fd, unsigned char *p, size_t n) { size_t d = 0; while (d < n) { ssize_t r = recv(fd, p + d, n - d, 0); if (r <= 0) return -1; d += (size_t)r; } return 0; }

int main(void) {
    printf("== name lookup\n");
    struct addrinfo hints, *res = NULL; memset(&hints, 0, sizeof hints); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo("127.0.0.1", NULL, &hints, &res); CHECK("getaddrinfo of an address literal", gai == 0 && res && res->ai_family == AF_INET);
    if (res) { struct sockaddr_in *sa = (struct sockaddr_in *)res->ai_addr; CHECK("resolved to 127.0.0.1", ntohl(sa->sin_addr.s_addr) == 0x7f000001); freeaddrinfo(res); }
    res = NULL; gai = getaddrinfo("localhost", NULL, &hints, &res); CHECK("getaddrinfo of localhost", gai == 0 && res != NULL); if (res) freeaddrinfo(res);

    printf("== tcp loopback\n");
    int ls = socket(AF_INET, SOCK_STREAM, 0); CHECK("socket", ls >= 0);
    struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(0x7f000001); a.sin_port = 0;
    CHECK("bind 127.0.0.1:0", bind(ls, (struct sockaddr *)&a, sizeof a) == 0);
    CHECK("listen", listen(ls, 5) == 0);
    struct sockaddr_in la; socklen_t ll = sizeof la; CHECK("getsockname", getsockname(ls, (struct sockaddr *)&la, &ll) == 0 && la.sin_port != 0 && ntohl(la.sin_addr.s_addr) == 0x7f000001);
    int cs = socket(AF_INET, SOCK_STREAM, 0);
    CHECK("connect to the listener", connect(cs, (struct sockaddr *)&la, sizeof la) == 0);
    struct pollfd pf = { ls, POLLIN, 0 }; int pr = poll(&pf, 1, 2000); CHECK("poll: listener readable", pr == 1 && (pf.revents & POLLIN));
    struct sockaddr_in pa; socklen_t pl = sizeof pa; int as = accept(ls, (struct sockaddr *)&pa, &pl); CHECK("accept", as >= 0);
    struct sockaddr_in cp; socklen_t cl = sizeof cp; CHECK("getpeername on the client is the listener port", getpeername(cs, (struct sockaddr *)&cp, &cl) == 0 && cp.sin_port == la.sin_port);

    unsigned char out[65536], in[65536]; uint64_t hsend = 1469598103934665603ull, hrecv = hsend, hback = hsend, hecho = hsend; int ok = 1;
    for (int round = 0; round < 6 && ok; round++) {
        for (size_t i = 0; i < sizeof out; i++) out[i] = (unsigned char)(i * 7 + round * 13);
        hsend = fnv(out, sizeof out, hsend);
        if (send_all(cs, out, sizeof out) || recv_all(as, in, sizeof in)) { ok = 0; break; }
        hrecv = fnv(in, sizeof in, hrecv);
        if (send_all(as, in, sizeof in) || recv_all(cs, out, sizeof out)) { ok = 0; break; }   /* echo back */
        hback = fnv(out, sizeof out, hback);
    }
    hecho = hsend;
    CHECK("6 x 64 KiB client -> server -> client", ok && hsend == hrecv && hsend == hback && hecho == hback);
    printf("hash %016llx\n", (unsigned long long)hsend);
    const char *bye = "bye"; CHECK("send small message", send(cs, bye, 3, 0) == 3);
    CHECK("shutdown(SHUT_WR) on the client", shutdown(cs, SHUT_WR) == 0);
    char b[8]; ssize_t g = recv(as, b, sizeof b, 0); CHECK("server reads the message", g == 3 && !memcmp(b, "bye", 3));
    g = recv(as, b, sizeof b, 0); CHECK("server then sees end of stream", g == 0);
    close(as); close(cs); close(ls);
    int ns = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in dead = la; int cr = connect(ns, (struct sockaddr *)&dead, sizeof dead);
    CHECK("connect to the closed port is refused", cr != 0); close(ns);
    printf("SUMMARY pass=%d fail=%d\n", pass, fail);
    return fail ? 1 : 0;
}
