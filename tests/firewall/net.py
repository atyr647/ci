#!/usr/bin/env python3
"""net.py - TEST TOOL (tests/test-firewall.sh), run inside a network namespace:
  net.py serve tcp|udp PORT LOG   listen on every address (IPv4 and IPv6); answer each TCP connection with "hi",
                                  and log each TCP connection or UDP datagram as a line in LOG (IPv4 only on a
                                  kernel without IPv6)
  net.py connect HOST PORT        exit 0 when a TCP connection is made and "hi" comes back within 2 s, else 1
  net.py send HOST PORT           send one UDP datagram
  net.py ipv6                     exit 0 when this kernel has IPv6
  net.py ping HOST                exit 0 when an ICMP echo reply comes back within 2 s (IPv4, raw socket)"""
import os, select, socket, struct, sys, time

cmd = sys.argv[1]
if cmd == "serve":
    kind, port, log = sys.argv[2], int(sys.argv[3]), sys.argv[4]
    t = socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM
    try:
        s = socket.socket(socket.AF_INET6, t)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("::", port))
    except OSError:  # a kernel without IPv6
        s = socket.socket(socket.AF_INET, t)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", port))
    if kind == "tcp":
        s.listen(8)
    open(log + ".ready", "w").close()
    while True:
        if kind == "tcp":
            c, a = s.accept()
            c.sendall(b"hi")
            c.close()
        else:
            _, a = s.recvfrom(100)
        with open(log, "a") as f:
            f.write(a[0] + "\n")
elif cmd == "ipv6":
    try:
        socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    except OSError:
        sys.exit(1)
elif cmd == "connect":
    try:
        c = socket.create_connection((sys.argv[2], int(sys.argv[3])), timeout=2)
        sys.exit(0 if c.recv(2) == b"hi" else 1)
    except OSError:
        sys.exit(1)
elif cmd == "send":
    fam = socket.AF_INET6 if ":" in sys.argv[2] else socket.AF_INET
    socket.socket(fam, socket.SOCK_DGRAM).sendto(b"x", (sys.argv[2], int(sys.argv[3])))
elif cmd == "ping":
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    body = struct.pack("!HH", os.getpid() & 0xFFFF, 1) + b"ribbon"
    def csum(b):
        b += b"\0" * (len(b) % 2)
        n = sum(struct.unpack("!%dH" % (len(b) // 2), b))
        n = (n >> 16) + (n & 0xFFFF); n += n >> 16
        return ~n & 0xFFFF
    pkt = struct.pack("!BBH", 8, 0, 0) + body
    pkt = struct.pack("!BBH", 8, 0, csum(pkt)) + body
    s.sendto(pkt, (sys.argv[2], 0))
    end = time.time() + 2
    while time.time() < end:
        r, _, _ = select.select([s], [], [], end - time.time())
        if r:
            d, a = s.recvfrom(200)
            if a[0] == sys.argv[2] and d[(d[0] & 15) * 4] == 0:
                sys.exit(0)
    sys.exit(1)
