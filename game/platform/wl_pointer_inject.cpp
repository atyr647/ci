// Test tool: a persistent virtual pointer (wlr-virtual-pointer-unstable-v1, supported by wlroots compositors such as sway) that moves to an absolute position inside the output and stays for a while.
//   wl_pointer_inject <x> <y> <output width> <output height> <seconds alive>
// (wlrctl creates its virtual pointer for one command only, which is gone before a client has bound to the new seat capability.)
#include "window.h"
int main(int argc, char **argv) {
    if (argc < 6) return 2; unsigned x = atoi(argv[1]), y = atoi(argv[2]), W = atoi(argv[3]), H = atoi(argv[4]); double secs = atof(argv[5]);
    win::Wayland w; const char *rd = getenv("XDG_RUNTIME_DIR"), *wd = getenv("WAYLAND_DISPLAY"); if (!rd || !wd) return 3;
    std::string path = std::string(rd) + "/" + wd; struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX; snprintf(sa.sun_path, sizeof sa.sun_path, "%s", path.c_str());
    w.fd = socket(AF_UNIX, SOCK_STREAM, 0); if (w.fd < 0 || connect(w.fd, (struct sockaddr *)&sa, sizeof sa)) { puts("cannot connect"); return 4; }
    w.registry = w.next++; w.msg(1, 1, {w.registry}); if (!w.roundtrip()) return 5;
    uint32_t mgr_name = 0, seat_name = 0, mgr_ver = 1, seat_ver = 1; for (auto &g : w.globals) { if (g.iface == "zwlr_virtual_pointer_manager_v1") { mgr_name = g.name; mgr_ver = g.ver; } if (g.iface == "wl_seat") { seat_name = g.name; seat_ver = g.ver; } }
    if (!mgr_name || !seat_name) { puts("the compositor has no zwlr_virtual_pointer_manager_v1"); return 6; }
    uint32_t seat = w.do_bind(seat_name, "wl_seat", std::min<uint32_t>(seat_ver, 5)), mgr = w.do_bind(mgr_name, "zwlr_virtual_pointer_manager_v1", std::min<uint32_t>(mgr_ver, 2));
    uint32_t vp = w.next++; w.msg(mgr, 0, {seat, vp}); w.roundtrip(); printf("wl_pointer_inject: virtual pointer created, alive %.1f s\n", secs); fflush(stdout);
    win::wsleep_ms(1500);   // the client under test sees the new capability and binds the pointer
    for (int i = 0; i < 3; i++) { w.msg(vp, 1, {(uint32_t)(1000 + i * 10), x + (unsigned)(i & 1), y, W, H}); w.msg(vp, 4, {}); w.roundtrip(); win::wsleep_ms(100); }
    w.msg(vp, 1, {2000, x, y, W, H}); w.msg(vp, 4, {}); w.roundtrip();
    win::wsleep_ms((int)(secs * 1000)); return 0;
}
