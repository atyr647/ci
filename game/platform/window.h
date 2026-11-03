// A window to show the game's frames in, and its keyboard and mouse, from a Cosmopolitan program. CPU presentation: the host reads the rendered frame back and this blits it.
//   Linux:   the X11 protocol spoken directly over the display's unix socket (no libX11, no libxcb, nothing from the system's C library: works on a Linux without glibc); Wayland is window_wayland.h
//   Windows: user32 + gdi32 through ms_abi pointers (x86-64 half; Windows arm64 machines run that half)
//   macOS:   AppKit through the Objective-C runtime, the frame is set as the contents of the content view's layer (a CGImage)
// Interface: open(), present(rgba, w, h) (frame as 4 bytes per pixel R,G,B,A, top row first), poll(events) (game key codes: 1 left, 2 right, 3 up, 4 down, 5 fire; mouse in frame pixels), verify() (reads the window back
// where the OS allows it), close().
#pragma once
#define _COSMO_SOURCE 1
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cmath>
#include <cosmo.h>
#include <dlfcn.h>
#include <errno.h>
#include <map>
#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

namespace win {

enum { EV_KEY_DOWN = 1, EV_KEY_UP = 2, EV_MOUSE = 3, EV_CLOSE = 4 };
struct Event { int type, a, b; };

static inline void wsleep_ms(int ms) { struct timespec t = {ms / 1000, (ms % 1000) * 1000000L}; nanosleep(&t, nullptr); }
static inline int game_key_from_keysym(uint32_t ks) { switch (ks) { case 0xff51: case 'a': case 'A': return 1; case 0xff53: case 'd': case 'D': return 2; case 0xff52: case 'w': case 'W': return 3; case 0xff54: case 's': case 'S': return 4; case ' ': return 5; default: return 0; } }

// ================================================================================================ X11, protocol only
struct X11 {
    int fd = -1; uint32_t base = 0, mask = 0, root = 0, rootvis = 0, win = 0, gc = 0, wm_protocols = 0, wm_delete = 0; int depth = 0, bpp = 0, w = 0, h = 0; uint32_t maxreq = 0; uint8_t mink = 0, maxk = 0; uint16_t seq = 0;
    std::vector<uint32_t> keysyms; int per = 0; std::vector<uint8_t> inbuf; std::vector<Event> pending; int errors = 0; std::string note, vendor;
    static size_t pad4(size_t n) { return (n + 3) & ~3u; }
    bool wr(const void *p, size_t n) { const uint8_t *b = (const uint8_t *)p; while (n) { ssize_t k = write(fd, b, n); if (k < 0) { if (errno == EINTR) continue; return false; } b += k; n -= (size_t)k; } return true; }
    bool rd(void *p, size_t n, int timeout_ms = 5000) { uint8_t *b = (uint8_t *)p; while (n) { struct pollfd pf = {fd, POLLIN, 0}; if (poll(&pf, 1, timeout_ms) <= 0) return false; ssize_t k = read(fd, b, n); if (k <= 0) return false; b += k; n -= (size_t)k; } return true; }
    static void put16(std::vector<uint8_t> &v, uint32_t x) { v.push_back(x & 255); v.push_back((x >> 8) & 255); }
    static void put32(std::vector<uint8_t> &v, uint32_t x) { put16(v, x & 0xffff); put16(v, x >> 16); }
    static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
    static uint32_t get16(const uint8_t *p) { return p[0] | p[1] << 8; }

    // the authority entry for this display: ~/.Xauthority or $XAUTHORITY, family local (256) or wild (65535), display number as text
    static bool find_cookie(const char *dispnum, std::vector<uint8_t> &name, std::vector<uint8_t> &data) {
        const char *f = getenv("XAUTHORITY"); std::string path; if (f && *f) path = f; else if (const char *h = getenv("HOME")) path = std::string(h) + "/.Xauthority"; else return false;
        FILE *fp = fopen(path.c_str(), "rb"); if (!fp) return false; bool found = false;
        for (;;) { uint8_t b2[2]; if (fread(b2, 1, 2, fp) != 2) break; unsigned family = b2[0] << 8 | b2[1]; std::vector<uint8_t> fld[4];
            bool ok = true; for (int i = 0; i < 4 && ok; i++) { uint8_t l[2]; if (fread(l, 1, 2, fp) != 2) { ok = false; break; } unsigned n = l[0] << 8 | l[1]; fld[i].resize(n); if (n && fread(fld[i].data(), 1, n, fp) != n) ok = false; }
            if (!ok) break; std::string num(fld[1].begin(), fld[1].end());
            if ((family == 256 || family == 65535) && (num == dispnum || num.empty()) && std::string(fld[2].begin(), fld[2].end()) == "MIT-MAGIC-COOKIE-1") { name = fld[2]; data = fld[3]; found = true; break; } }
        fclose(fp); return found;
    }
    bool open(int width, int height, const char *title, std::string &n) {
        const char *d = getenv("DISPLAY"); if (!d || !*d) { n = "DISPLAY is not set"; return false; }
        const char *colon = strrchr(d, ':'); if (!colon || (colon != d && colon[-1] != '/' && colon != d)) { if (!colon) { n = "unsupported DISPLAY"; return false; } }
        if (colon != d) { n = std::string("DISPLAY \"") + d + "\" names a host; only a local display is supported"; return false; }
        char num[16]; snprintf(num, sizeof num, "%d", atoi(colon + 1));
        struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX; snprintf(sa.sun_path, sizeof sa.sun_path, "/tmp/.X11-unix/X%s", num);
        fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof sa)) { n = std::string("cannot connect to ") + sa.sun_path + ": " + strerror(errno); return false; }
        std::vector<uint8_t> an, ad; find_cookie(num, an, ad);
        std::vector<uint8_t> rq; rq.push_back('l'); rq.push_back(0); put16(rq, 11); put16(rq, 0); put16(rq, (uint32_t)an.size()); put16(rq, (uint32_t)ad.size()); put16(rq, 0);
        rq.insert(rq.end(), an.begin(), an.end()); rq.resize(12 + pad4(an.size())); rq.insert(rq.end(), ad.begin(), ad.end()); rq.resize(12 + pad4(an.size()) + pad4(ad.size()));
        if (!wr(rq.data(), rq.size())) { n = "write of the setup request failed"; return false; }
        uint8_t hd[8]; if (!rd(hd, 8)) { n = "no answer to the setup request"; return false; }
        size_t extra = (size_t)get16(hd + 6) * 4; std::vector<uint8_t> s(extra); if (!rd(s.data(), extra)) { n = "short setup reply"; return false; }
        if (hd[0] != 1) { n = "the X server refused the connection: " + std::string((char *)s.data(), std::min<size_t>(hd[1], s.size())); return false; }
        base = get32(s.data() + 4); mask = get32(s.data() + 8); size_t vlen = get16(s.data() + 16); maxreq = get16(s.data() + 18); int nscreens = s[20], nformats = s[21]; mink = s[26]; maxk = s[27];
        vendor.assign((char *)s.data() + 32, vlen); size_t off = 32 + pad4(vlen); struct Fmt { int depth, bpp; }; std::vector<Fmt> fm; for (int i = 0; i < nformats; i++) { fm.push_back({s[off + 8 * i], s[off + 8 * i + 1]}); } off += 8 * (size_t)nformats;
        if (nscreens < 1) { n = "no screen"; return false; }
        root = get32(s.data() + off); rootvis = get32(s.data() + off + 32); depth = s[off + 38]; bpp = 0; for (auto &f : fm) if (f.depth == depth) bpp = f.bpp;
        if (!(depth == 24 || depth == 32) || bpp != 32) { n = "unsupported root depth " + std::to_string(depth) + " / " + std::to_string(bpp) + " bits per pixel"; return false; }
        w = width; h = height; uint32_t idc = 1; win = base | (idc++ & mask); gc = base | (idc++ & mask);
        std::vector<uint8_t> cw; cw.push_back(1); cw.push_back(0); put16(cw, 10); put32(cw, win); put32(cw, root); put16(cw, 100); put16(cw, 100); put16(cw, (uint32_t)w); put16(cw, (uint32_t)h); put16(cw, 0); put16(cw, 1); put32(cw, 0);
        put32(cw, 0x802 /* BackPixel, EventMask */); put32(cw, 0x203040); put32(cw, 1 | 2 | 4 | 8 | 64 | 0x8000 | 0x20000 /* key press/release, button press/release, pointer motion, exposure, structure */); if (!wr(cw.data(), cw.size())) return false; seq++;
        std::string t = title; std::vector<uint8_t> cp; cp.push_back(18); cp.push_back(0); put16(cp, (uint32_t)(6 + pad4(t.size()) / 4)); put32(cp, win); put32(cp, 39 /*WM_NAME*/); put32(cp, 31 /*STRING*/); cp.push_back(8); cp.push_back(0); cp.push_back(0); cp.push_back(0); put32(cp, (uint32_t)t.size());
        cp.insert(cp.end(), t.begin(), t.end()); cp.resize(24 + pad4(t.size())); wr(cp.data(), cp.size()); seq++;
        wm_protocols = intern("WM_PROTOCOLS"); wm_delete = intern("WM_DELETE_WINDOW");
        if (wm_protocols && wm_delete) { std::vector<uint8_t> pr; pr.push_back(18); pr.push_back(0); put16(pr, 7); put32(pr, win); put32(pr, wm_protocols); put32(pr, 4 /*ATOM*/); pr.push_back(32); pr.push_back(0); pr.push_back(0); pr.push_back(0); put32(pr, 1); put32(pr, wm_delete); wr(pr.data(), pr.size()); seq++; }
        std::vector<uint8_t> mg; mg.push_back(55); mg.push_back(0); put16(mg, 4); put32(mg, gc); put32(mg, win); put32(mg, 0); wr(mg.data(), mg.size()); seq++;
        std::vector<uint8_t> mp; mp.push_back(8); mp.push_back(0); put16(mp, 2); put32(mp, win); wr(mp.data(), mp.size()); seq++;
        std::vector<uint8_t> km; km.push_back(101); km.push_back(0); put16(km, 2); km.push_back(mink); km.push_back((uint8_t)(maxk - mink + 1)); put16(km, 0); wr(km.data(), km.size()); seq++;
        std::vector<uint8_t> rep; if (read_reply(rep)) { per = rep[1]; size_t cnt = (rep.size() - 32) / 4; keysyms.resize(cnt); for (size_t i = 0; i < cnt; i++) keysyms[i] = get32(rep.data() + 32 + 4 * i); }
        n = "X11 protocol over /tmp/.X11-unix/X" + std::string(num) + ", vendor \"" + vendor + "\", depth " + std::to_string(depth) + ", " + std::to_string(w) + "x" + std::to_string(h); note = n; return true;
    }
    // read packets until the reply to the last request arrives; events that come first are queued
    bool read_reply(std::vector<uint8_t> &rep) {
        for (;;) { uint8_t p[32]; if (!rd(p, 32)) return false;
            if (p[0] == 1) { rep.assign(p, p + 32); size_t extra = (size_t)get32(p + 4) * 4; if (extra) { rep.resize(32 + extra); if (!rd(rep.data() + 32, extra)) return false; } return true; }
            if (p[0] == 0) { errors++; fprintf(stderr, "X11 error: code %d, request major %d\n", p[1], p[10]); return false; }
            handle(p); }
    }
    uint32_t intern(const char *name) { size_t l = strlen(name); std::vector<uint8_t> r; r.push_back(16); r.push_back(0); put16(r, (uint32_t)(2 + pad4(l) / 4)); put16(r, (uint32_t)l); put16(r, 0); r.insert(r.end(), name, name + l); r.resize(8 + pad4(l)); if (!wr(r.data(), r.size())) return 0; seq++; std::vector<uint8_t> rep; return read_reply(rep) ? get32(rep.data() + 8) : 0; }
    uint32_t keysym_of(int keycode) const { if (!per || keycode < mink || keycode > maxk) return 0; return keysyms[(size_t)(keycode - mink) * per]; }
    void handle(const uint8_t *p) {
        int t = p[0] & 0x7f;
        if (t == 2 || t == 3) { int ks = game_key_from_keysym(keysym_of(p[1])); if (ks) pending.push_back({t == 2 ? EV_KEY_DOWN : EV_KEY_UP, ks, (int)get32(p + 4) /*time, for the repeat check*/}); }
        else if (t == 6) pending.push_back({EV_MOUSE, (int16_t)get16(p + 24), (int16_t)get16(p + 26)});
        else if (t == 33 && get32(p + 12) == wm_delete && wm_delete) pending.push_back({EV_CLOSE, 0, 0});
    }
    void poll_events(std::vector<Event> &out) {
        for (;;) { struct pollfd pf = {fd, POLLIN, 0}; if (poll(&pf, 1, 0) <= 0) break; uint8_t p[32]; if (!rd(p, 32, 100)) break; if (p[0] == 0) { errors++; continue; } if (p[0] == 1) continue; handle(p); }
        // auto-repeat arrives as a release and a press with the same time stamp: both are dropped
        for (size_t i = 0; i < pending.size(); i++) { Event e = pending[i];
            if (e.type == EV_KEY_UP && i + 1 < pending.size() && pending[i + 1].type == EV_KEY_DOWN && pending[i + 1].a == e.a && pending[i + 1].b == e.b) { i++; continue; }
            if (e.type == EV_KEY_DOWN || e.type == EV_KEY_UP) e.b = 0; out.push_back(e); }
        pending.clear();
    }
    bool present(const uint8_t *rgba, int fw, int fh) {
        size_t row = (size_t)fw * 4; size_t rows_per = (size_t)(maxreq * 4 - 64) / row; if (rows_per < 1) rows_per = 1; std::vector<uint8_t> px((size_t)fw * fh * 4);
        for (int i = 0; i < fw * fh; i++) { px[4 * i] = rgba[4 * i + 2]; px[4 * i + 1] = rgba[4 * i + 1]; px[4 * i + 2] = rgba[4 * i]; px[4 * i + 3] = 0; }
        for (int y = 0; y < fh; y += (int)rows_per) { int n = (int)std::min<size_t>(rows_per, (size_t)(fh - y)); std::vector<uint8_t> r; r.push_back(72); r.push_back(2); put16(r, (uint32_t)(6 + (size_t)n * row / 4)); put32(r, win); put32(r, gc);
            put16(r, (uint32_t)fw); put16(r, (uint32_t)n); put16(r, 0); put16(r, (uint32_t)y); r.push_back(0); r.push_back((uint8_t)depth); put16(r, 0); r.insert(r.end(), px.begin() + (size_t)y * row, px.begin() + (size_t)(y + n) * row); if (!wr(r.data(), r.size())) return false; seq++; }
        return true;
    }
    // read the window back with GetImage and count the pixels that differ from the frame (alpha ignored)
    bool verify(const uint8_t *rgba, int fw, int fh, int &mismatch) {
        mismatch = -1; std::vector<uint8_t> r; r.push_back(73); r.push_back(2); put16(r, 5); put32(r, win); put16(r, 0); put16(r, 0); put16(r, (uint32_t)fw); put16(r, (uint32_t)fh); put32(r, 0xffffffffu); if (!wr(r.data(), r.size())) return false; seq++;
        std::vector<uint8_t> rep; if (!read_reply(rep) || rep.size() < 32 + (size_t)fw * fh * 4) return false; mismatch = 0;
        for (int i = 0; i < fw * fh; i++) { const uint8_t *q = rep.data() + 32 + 4 * i; if (q[0] != rgba[4 * i + 2] || q[1] != rgba[4 * i + 1] || q[2] != rgba[4 * i]) mismatch++; }
        return true;
    }
    void close() { if (fd >= 0) { ::close(fd); fd = -1; } }
};


// ================================================================================================ Wayland, protocol only (wl_shm buffers, xdg-shell, wl_seat)
struct Wayland {
    int fd = -1, shmfd = -1; uint32_t next = 2, registry = 0, compositor = 0, shm = 0, wm_base = 0, seat = 0, surface = 0, xsurface = 0, toplevel = 0, pool = 0, pointer = 0, keyboard = 0, buf[2] = {0, 0};
    uint32_t g_comp = 0, g_shm = 0, g_wm = 0, g_seat = 0, v_comp = 0, v_seat = 0; struct Global { uint32_t name; std::string iface; uint32_t ver; }; std::vector<Global> globals; uint8_t *mem = nullptr; size_t memsz = 0; int w = 0, h = 0; bool configured = false, free_[2] = {true, true}, sync_done = false; uint32_t sync_cb = 0;
    std::vector<Event> pending; std::vector<uint8_t> in; std::vector<int> fds_in; std::string note; int errors = 0;
    void msg(uint32_t obj, uint32_t op, const std::vector<uint32_t> &args, const std::vector<std::string> &strs = {}, int sendfd = -1) {
        std::vector<uint8_t> b; auto p32 = [&](uint32_t v) { for (int i = 0; i < 4; i++) b.push_back((v >> (8 * i)) & 255); };
        p32(obj); p32(0); for (uint32_t a : args) p32(a);
        for (auto &st : strs) { p32((uint32_t)st.size() + 1); b.insert(b.end(), st.begin(), st.end()); b.push_back(0); while (b.size() % 4) b.push_back(0); }
        uint32_t sz = (uint32_t)b.size(); b[4] = op & 255; b[5] = (op >> 8) & 255; b[6] = sz & 255; b[7] = (sz >> 8) & 255;
        struct iovec iov = {b.data(), b.size()}; struct msghdr mh; memset(&mh, 0, sizeof mh); mh.msg_iov = &iov; mh.msg_iovlen = 1; alignas(8) char cbuf[CMSG_SPACE(sizeof(int))];
        if (sendfd >= 0) { memset(cbuf, 0, sizeof cbuf); mh.msg_control = cbuf; mh.msg_controllen = sizeof cbuf; struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = CMSG_LEN(sizeof(int)); memcpy(CMSG_DATA(c), &sendfd, sizeof(int)); }
        if (sendmsg(fd, &mh, 0) < 0) errors++;
    }
    // reads whatever is available (waiting up to timeout_ms for the first byte) and handles every complete message
    bool pump(int timeout_ms) {
        struct pollfd pf = {fd, POLLIN, 0}; if (poll(&pf, 1, timeout_ms) <= 0) return false;
        uint8_t tmp[4096]; alignas(8) char cbuf[CMSG_SPACE(sizeof(int) * 8)]; struct iovec iov = {tmp, sizeof tmp}; struct msghdr mh; memset(&mh, 0, sizeof mh); mh.msg_iov = &iov; mh.msg_iovlen = 1; mh.msg_control = cbuf; mh.msg_controllen = sizeof cbuf;
        ssize_t n = recvmsg(fd, &mh, 0); if (n <= 0) return false; in.insert(in.end(), tmp, tmp + n);
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c; c = CMSG_NXTHDR(&mh, c)) if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) { int cnt = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int)); for (int i = 0; i < cnt; i++) { int f; memcpy(&f, CMSG_DATA(c) + i * sizeof(int), sizeof f); fds_in.push_back(f); } }
        size_t off = 0; while (in.size() - off >= 8) { uint32_t obj = X11::get32(in.data() + off), w2 = X11::get32(in.data() + off + 4); uint32_t sz = w2 >> 16, op = w2 & 0xffff; if (sz < 8 || in.size() - off < sz) break; event(obj, op, in.data() + off + 8, sz - 8); off += sz; }
        in.erase(in.begin(), in.begin() + off); return true;
    }
    static std::string str_at(const uint8_t *p, size_t &o) { uint32_t l = X11::get32(p + o); std::string r(l ? (const char *)p + o + 4 : "", l ? l - 1 : 0); o += 4 + ((l + 3) & ~3u); return r; }
    void event(uint32_t obj, uint32_t op, const uint8_t *a, size_t n) {
        static const bool dbg = getenv("WINDOW_DEBUG") != nullptr; if (dbg && obj != 1) fprintf(stderr, "wl event: object %u (%s) opcode %u, %zu bytes\n", obj, obj == seat ? "seat" : obj == pointer ? "pointer" : obj == keyboard ? "keyboard" : obj == xsurface ? "xdg_surface" : obj == toplevel ? "toplevel" : "other", op, n);
        if (obj == 1) { if (op == 0) { errors++; size_t o = 8; fprintf(stderr, "wayland error: object %u code %u: %s\n", X11::get32(a), X11::get32(a + 4), str_at(a, o).c_str()); } }
        else if (obj == registry && op == 0) { uint32_t name = X11::get32(a); size_t o = 4; std::string iface = str_at(a, o); uint32_t ver = X11::get32(a + o); globals.push_back({name, iface, ver});
            if (iface == "wl_compositor") { g_comp = name; v_comp = ver; } else if (iface == "wl_shm") g_shm = name; else if (iface == "xdg_wm_base") g_wm = name; else if (iface == "wl_seat") { g_seat = name; v_seat = ver; } }
        else if (obj == sync_cb && op == 0) sync_done = true;
        else if (obj == wm_base && op == 0) msg(wm_base, 3, {X11::get32(a)});
        else if (obj == xsurface && op == 0) { msg(xsurface, 4, {X11::get32(a)}); configured = true; }
        else if (obj == toplevel && op == 1) pending.push_back({EV_CLOSE, 0, 0});
        else if (obj == buf[0] && op == 0) free_[0] = true; else if (obj == buf[1] && op == 0) free_[1] = true;
        else if (obj == seat && op == 0) { uint32_t caps = X11::get32(a); if (getenv("WINDOW_DEBUG")) fprintf(stderr, "wl seat capabilities %u (pointer %d, keyboard %d)\n", caps, !!(caps & 1), !!(caps & 2));   // devices come and go (a virtual keyboard, a USB mouse): get the object when the capability appears, release it when it goes
            if (!(caps & 1) && pointer) { msg(pointer, 1, {}); pointer = 0; } if (!(caps & 2) && keyboard) { msg(keyboard, 0, {}); keyboard = 0; }
            if ((caps & 1) && !pointer) { pointer = next++; msg(seat, 0, {pointer}); } if ((caps & 2) && !keyboard) { keyboard = next++; msg(seat, 1, {keyboard}); } }
        else if (obj == pointer && op == 2) pending.push_back({EV_MOUSE, (int)X11::get32(a + 4) >> 8, (int)X11::get32(a + 8) >> 8});
        else if (obj == pointer && op == 0) pending.push_back({EV_MOUSE, (int)X11::get32(a + 8) >> 8, (int)X11::get32(a + 12) >> 8});
        else if (obj == keyboard && op == 0) { if (!fds_in.empty()) { load_keymap(fds_in[0], X11::get32(a + 4)); for (int f : fds_in) ::close(f); fds_in.clear(); } }
        else if (obj == keyboard && op == 3) { uint32_t key = X11::get32(a + 8), state = X11::get32(a + 12); int g = 0;
            if (!keymap.empty()) { auto it = keymap.find(key + 8); if (it != keymap.end()) g = it->second; }   // xkb key code = evdev code + 8
            else switch (key) { case 30: case 105: g = 1; break; case 32: case 106: g = 2; break; case 17: case 103: g = 3; break; case 31: case 108: g = 4; break; case 57: g = 5; break; }
            if (g) pending.push_back({state ? EV_KEY_DOWN : EV_KEY_UP, g, 0}); }
        (void)n;
    }
    std::map<uint32_t, int> keymap;   // xkb key code -> game key, from the compositor's keymap
    // the keymap is xkb text: "<AC01> = 38;" in xkb_keycodes and "key <AC01> { [ a, A ] };" in xkb_symbols; the first symbol of every key is enough here
    void load_keymap(int kfd, uint32_t size) {
        if (!size) return; void *m = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, kfd, 0); if (m == MAP_FAILED) return; std::string t((const char *)m, strnlen((const char *)m, size)); munmap(m, size); keymap.clear(); if (const char *dump = getenv("WINDOW_KEYMAP_DUMP")) if (FILE *f = fopen(dump, "wb")) { fwrite(t.data(), 1, t.size(), f); fclose(f); }
        std::map<std::string, uint32_t> code; size_t kc = t.find("xkb_keycodes"), sy = t.find("xkb_symbols"); if (kc == std::string::npos || sy == std::string::npos) return;
        for (size_t p = kc; p < sy;) { size_t a = t.find('<', p); if (a == std::string::npos || a >= sy) break; size_t b = t.find('>', a); size_t eq = t.find('=', b); size_t sc = t.find(';', eq); if (b == std::string::npos || eq == std::string::npos || sc == std::string::npos) break;
            if (t.find_first_not_of(" \t", b + 1) == eq) code[t.substr(a + 1, b - a - 1)] = (uint32_t)atoi(t.c_str() + eq + 1); p = sc + 1; }
        for (size_t p = sy;;) { size_t k = t.find("key <", p); if (k == std::string::npos) break; size_t e = t.find('>', k); std::string name = t.substr(k + 5, e - k - 5); size_t br = t.find('[', e), end = t.find("};", e); if (br == std::string::npos || (end != std::string::npos && br > end)) { p = e; continue; }
            size_t c1 = t.find_first_of(",]", br + 1); std::string sym = t.substr(br + 1, c1 - br - 1); while (!sym.empty() && sym[0] == ' ') sym.erase(0, 1); while (!sym.empty() && sym.back() == ' ') sym.pop_back();
            int g = sym == "a" || sym == "Left" ? 1 : sym == "d" || sym == "Right" ? 2 : sym == "w" || sym == "Up" ? 3 : sym == "s" || sym == "Down" ? 4 : sym == "space" ? 5 : 0; auto it = code.find(name); if (g && it != code.end()) keymap[it->second] = g; p = e; }
    }
    bool roundtrip() { sync_cb = next++; sync_done = false; msg(1, 0, {sync_cb}); for (int i = 0; i < 200 && !sync_done; i++) pump(50); return sync_done; }
    uint32_t do_bind(uint32_t name, const char *iface, uint32_t ver) {
        uint32_t id = next++; std::vector<uint8_t> b; auto p32 = [&](uint32_t v) { for (int i = 0; i < 4; i++) b.push_back((v >> (8 * i)) & 255); };
        std::string st = iface; p32(registry); p32(0); p32(name); p32((uint32_t)st.size() + 1); b.insert(b.end(), st.begin(), st.end()); b.push_back(0); while (b.size() % 4) b.push_back(0); p32(ver); p32(id);
        uint32_t sz = (uint32_t)b.size(); b[4] = 0; b[5] = 0; b[6] = sz & 255; b[7] = (sz >> 8) & 255; if (write(fd, b.data(), b.size()) != (ssize_t)b.size()) errors++; return id;
    }
    bool open(int width, int height, const char *title, std::string &n) {
        const char *rd = getenv("XDG_RUNTIME_DIR"), *wd = getenv("WAYLAND_DISPLAY"); if (!rd || !*rd) { n = "XDG_RUNTIME_DIR is not set"; return false; } if (!wd || !*wd) wd = "wayland-0";
        std::string path = wd[0] == '/' ? std::string(wd) : std::string(rd) + "/" + wd; struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX; snprintf(sa.sun_path, sizeof sa.sun_path, "%s", path.c_str());
        fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0); if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof sa)) { n = "cannot connect to " + path + ": " + strerror(errno); return false; }
        w = width; h = height; registry = next++; msg(1, 1, {registry}); if (!roundtrip()) { n = "no answer from the compositor"; return false; }
        if (!g_comp || !g_shm || !g_wm) { n = "the compositor lacks wl_compositor, wl_shm or xdg_wm_base"; return false; }
        compositor = do_bind(g_comp, "wl_compositor", std::min<uint32_t>(v_comp, 4)); shm = do_bind(g_shm, "wl_shm", 1); wm_base = do_bind(g_wm, "xdg_wm_base", 1); if (g_seat) seat = do_bind(g_seat, "wl_seat", std::min<uint32_t>(v_seat, 5));
        surface = next++; msg(compositor, 0, {surface}); xsurface = next++; msg(wm_base, 2, {xsurface, surface}); toplevel = next++; msg(xsurface, 1, {toplevel}); msg(toplevel, 2, {}, {title}); msg(toplevel, 3, {}, {"celori"});
        size_t stride = (size_t)w * 4; memsz = stride * h * 2; shmfd = memfd_create("celori-shm", 1 /*MFD_CLOEXEC*/); if (shmfd < 0 || ftruncate(shmfd, (off_t)memsz)) { n = "memfd for the buffers failed"; return false; }
        mem = (uint8_t *)mmap(nullptr, memsz, PROT_READ | PROT_WRITE, MAP_SHARED, shmfd, 0); if (mem == MAP_FAILED) { n = "mmap of the buffers failed"; return false; }
        pool = next++; msg(shm, 0, {pool, (uint32_t)memsz}, {}, shmfd); for (int i = 0; i < 2; i++) { buf[i] = next++; msg(pool, 0, {buf[i], (uint32_t)(stride * h * i), (uint32_t)w, (uint32_t)h, (uint32_t)stride, 1 /*XRGB8888*/}); }
        msg(surface, 6, {});   // commit without a buffer: the compositor answers with the first configure
        for (int i = 0; i < 100 && !configured; i++) pump(50); if (!configured) { n = "no xdg_surface configure from the compositor"; return false; }
        roundtrip(); n = "Wayland protocol over " + path + ", " + std::to_string(w) + "x" + std::to_string(h) + (seat ? ", seat bound" : ", no seat"); note = n; return true;
    }
    bool present(const uint8_t *rgba, int fw, int fh) {
        if (fw != w || fh != h) return false; for (int i = 0; i < 100 && !free_[0] && !free_[1]; i++) pump(20); int b = free_[0] ? 0 : free_[1] ? 1 : -1; if (b < 0) return false;
        uint8_t *dst = mem + (size_t)b * w * h * 4; for (int i = 0; i < w * h; i++) { dst[4 * i] = rgba[4 * i + 2]; dst[4 * i + 1] = rgba[4 * i + 1]; dst[4 * i + 2] = rgba[4 * i]; dst[4 * i + 3] = 255; }
        free_[b] = false; msg(surface, 1, {buf[b], 0, 0}); msg(surface, 9, {0, 0, (uint32_t)w, (uint32_t)h}); msg(surface, 6, {}); return true;
    }
    void poll_events(std::vector<Event> &out) { while (pump(0)) {} for (auto &e : pending) out.push_back(e); pending.clear(); }
    void close() { if (fd >= 0) { ::close(fd); fd = -1; } }
};

// ================================================================================================ Windows: user32 + gdi32 through ms_abi pointers
#if defined(__x86_64__)
#define WMS __attribute__((ms_abi))
struct Gdi {
    typedef intptr_t (WMS *WndProc)(void *, unsigned, uintptr_t, intptr_t);
    struct WndClassExW { unsigned cbSize, style; WndProc proc; int cls_extra, wnd_extra; void *inst, *icon, *cursor, *brush; const uint16_t *menu, *name; void *icon_sm; };
    struct BmiHeader { unsigned size; int w, h; unsigned short planes, bits; unsigned comp, imgsize; int xppm, yppm; unsigned used, important; };
    void *u = nullptr, *g = nullptr, *k = nullptr, *hwnd = nullptr; int w = 0, h = 0; std::string note;
    static std::vector<Event> &events() { static std::vector<Event> e; return e; }
    static intptr_t WMS wndproc(void *hw, unsigned m, uintptr_t wp, intptr_t lp) {
        auto &ev = events();
        auto key = [](uintptr_t vk) { switch (vk) { case 0x25: case 'A': return 1; case 0x27: case 'D': return 2; case 0x26: case 'W': return 3; case 0x28: case 'S': return 4; case 0x20: return 5; default: return 0; } };
        if (m == 0x100) { if (!(lp & (1 << 30)) && key(wp)) ev.push_back({EV_KEY_DOWN, key(wp), 0}); return 0; }   // WM_KEYDOWN (bit 30: auto-repeat, ignored)
        if (m == 0x101) { if (key(wp)) ev.push_back({EV_KEY_UP, key(wp), 0}); return 0; }
        if (m == 0x200) { ev.push_back({EV_MOUSE, (int)(short)(lp & 0xFFFF), (int)(short)((lp >> 16) & 0xFFFF)}); return 0; }   // WM_MOUSEMOVE, client coordinates
        if (m == 0x10) { ev.push_back({EV_CLOSE, 0, 0}); return 0; }   // WM_CLOSE
        typedef intptr_t (WMS *Def)(void *, unsigned, uintptr_t, intptr_t); static Def def; if (!def) { void *uu = cosmo_dlopen("user32.dll", RTLD_NOW); def = (Def)cosmo_dlsym(uu, "DefWindowProcW"); } return def(hw, m, wp, lp);
    }
    bool open(int width, int height, const char *title, std::string &n) {
        u = cosmo_dlopen("user32.dll", RTLD_NOW); g = cosmo_dlopen("gdi32.dll", RTLD_NOW); k = cosmo_dlopen("kernel32.dll", RTLD_NOW); if (!u || !g || !k) { n = "user32/gdi32 not available"; return false; }
        typedef void *(WMS *GetMod)(const uint16_t *); typedef unsigned short (WMS *Reg)(const WndClassExW *); typedef void *(WMS *Create)(unsigned, const uint16_t *, const uint16_t *, unsigned, int, int, int, int, void *, void *, void *, void *);
        typedef int (WMS *AdjustRect)(int *, unsigned, int); typedef int (WMS *Show)(void *, int);
        GetMod getmod = (GetMod)cosmo_dlsym(k, "GetModuleHandleW"); Reg reg = (Reg)cosmo_dlsym(u, "RegisterClassExW"); Create create = (Create)cosmo_dlsym(u, "CreateWindowExW"); AdjustRect adj = (AdjustRect)cosmo_dlsym(u, "AdjustWindowRect"); Show show = (Show)cosmo_dlsym(u, "ShowWindow");
        static const uint16_t cls[] = {'C', 'e', 'l', 'o', 'r', 'i', 'W', 'i', 'n', 0}; std::vector<uint16_t> t; for (const char *c = title; *c; c++) t.push_back((uint8_t)*c); t.push_back(0);
        WndClassExW wc; memset(&wc, 0, sizeof wc); wc.cbSize = sizeof wc; wc.proc = wndproc; wc.inst = getmod(nullptr); wc.name = cls; if (!reg(&wc)) { n = "RegisterClassExW failed"; return false; }
        const unsigned style = 0x00CA0000u /*WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX*/; int rc[4] = {0, 0, width, height}; adj(rc, style, 0);
        hwnd = create(0, cls, t.data(), style, 100, 100, rc[2] - rc[0], rc[3] - rc[1], nullptr, nullptr, wc.inst, nullptr); if (!hwnd) { n = "CreateWindowExW failed"; return false; }
        show(hwnd, 5); typedef int (WMS *Upd)(void *); ((Upd)cosmo_dlsym(u, "UpdateWindow"))(hwnd); typedef int (WMS *SetFg)(void *); ((SetFg)cosmo_dlsym(u, "SetForegroundWindow"))(hwnd); w = width; h = height; pump();
        n = "GDI window (user32/gdi32), client area " + std::to_string(w) + "x" + std::to_string(h); note = n; return true;
    }
    void pump() { typedef int (WMS *Peek)(void *, void *, unsigned, unsigned, unsigned); typedef int (WMS *Tr)(const void *); typedef intptr_t (WMS *Disp)(const void *); static Peek peek = (Peek)cosmo_dlsym(u, "PeekMessageW"); static Tr tr = (Tr)cosmo_dlsym(u, "TranslateMessage"); static Disp disp = (Disp)cosmo_dlsym(u, "DispatchMessageW");
        uint8_t msg[64]; for (int i = 0; i < 500 && peek(msg, nullptr, 0, 0, 1); i++) { tr(msg); disp(msg); } }
    bool present(const uint8_t *rgba, int fw, int fh) {
        typedef void *(WMS *GetDC)(void *); typedef int (WMS *RelDC)(void *, void *); typedef int (WMS *SetDIB)(void *, int, int, unsigned, unsigned, int, int, unsigned, unsigned, const void *, const BmiHeader *, unsigned);
        static GetDC getdc = (GetDC)cosmo_dlsym(u, "GetDC"); static RelDC reldc = (RelDC)cosmo_dlsym(u, "ReleaseDC"); static SetDIB setdib = (SetDIB)cosmo_dlsym(g, "SetDIBitsToDevice");
        std::vector<uint8_t> px((size_t)fw * fh * 4); for (int i = 0; i < fw * fh; i++) { px[4 * i] = rgba[4 * i + 2]; px[4 * i + 1] = rgba[4 * i + 1]; px[4 * i + 2] = rgba[4 * i]; px[4 * i + 3] = 0; }
        BmiHeader bi; memset(&bi, 0, sizeof bi); bi.size = sizeof bi; bi.w = fw; bi.h = -fh; bi.planes = 1; bi.bits = 32; void *dc = getdc(hwnd); int lines = setdib(dc, 0, 0, (unsigned)fw, (unsigned)fh, 0, 0, 0, (unsigned)fh, px.data(), &bi, 0); reldc(hwnd, dc); pump(); return lines == fh;
    }
    bool verify(const uint8_t *rgba, int fw, int fh, int &mismatch) {   // copy the window's pixels out of its device context into a bitmap of our own and compare
        mismatch = -1; typedef void *(WMS *GetDC)(void *); typedef int (WMS *RelDC)(void *, void *); typedef void *(WMS *CCDC)(void *); typedef void *(WMS *CDIB)(void *, const BmiHeader *, unsigned, void **, void *, unsigned); typedef void *(WMS *Sel)(void *, void *); typedef int (WMS *Blt)(void *, int, int, int, int, void *, int, int, unsigned); typedef int (WMS *Del)(void *);
        GetDC getdc = (GetDC)cosmo_dlsym(u, "GetDC"); RelDC reldc = (RelDC)cosmo_dlsym(u, "ReleaseDC"); CCDC ccdc = (CCDC)cosmo_dlsym(g, "CreateCompatibleDC"); CDIB cdib = (CDIB)cosmo_dlsym(g, "CreateDIBSection"); Sel sel = (Sel)cosmo_dlsym(g, "SelectObject"); Blt blt = (Blt)cosmo_dlsym(g, "BitBlt"); Del delo = (Del)cosmo_dlsym(g, "DeleteObject"); Del deldc = (Del)cosmo_dlsym(g, "DeleteDC");
        void *dc = getdc(hwnd), *mem = ccdc(dc); BmiHeader bi; memset(&bi, 0, sizeof bi); bi.size = sizeof bi; bi.w = fw; bi.h = -fh; bi.planes = 1; bi.bits = 32; void *bits = nullptr; void *bmp = cdib(dc, &bi, 0, &bits, nullptr, 0); if (!bmp || !bits) { reldc(hwnd, dc); return false; }
        void *old = sel(mem, bmp); int ok = blt(mem, 0, 0, fw, fh, dc, 0, 0, 0x00CC0020 /*SRCCOPY*/); mismatch = 0; const uint8_t *q = (const uint8_t *)bits;
        if (ok) for (int i = 0; i < fw * fh; i++) { if (q[4 * i] != rgba[4 * i + 2] || q[4 * i + 1] != rgba[4 * i + 1] || q[4 * i + 2] != rgba[4 * i]) mismatch++; }
        sel(mem, old); delo(bmp); deldc(mem); reldc(hwnd, dc); return ok != 0;
    }
    void poll_events(std::vector<Event> &out) { pump(); auto &e = events(); out.insert(out.end(), e.begin(), e.end()); e.clear(); }
    // test input: through the system input queue (SendInput; reaches the window only if it is the foreground window of an interactive desktop), and posted messages as the second route
    std::string inject() {
        typedef int (WMS *SetCur)(int, int); typedef unsigned (WMS *SendIn)(unsigned, const void *, int); typedef int (WMS *Post)(void *, unsigned, uintptr_t, intptr_t); typedef int (WMS *Cl2Sc)(void *, int *);
        SetCur setcur = (SetCur)cosmo_dlsym(u, "SetCursorPos"); SendIn sendin = (SendIn)cosmo_dlsym(u, "SendInput"); Post post = (Post)cosmo_dlsym(u, "PostMessageW"); Cl2Sc c2s = (Cl2Sc)cosmo_dlsym(u, "ClientToScreen");
        int pt[2] = {0, 0}; c2s(hwnd, pt); setcur(pt[0] + 50, pt[1] + 60); win::wsleep_ms(50); pump();
        auto key = [&](unsigned short vk, bool down) { uint8_t in[40]; memset(in, 0, sizeof in); *(unsigned *)in = 1; *(unsigned short *)(in + 8) = vk; *(unsigned *)(in + 12) = down ? 0 : 2; return sendin(1, in, 40); };
        unsigned sent = 0; for (unsigned short vk : {(unsigned short)'A', (unsigned short)0x27, (unsigned short)0x20}) { sent += key(vk, true); sent += key(vk, false); win::wsleep_ms(30); pump(); }
        pump(); bool got = !events().empty() && std::any_of(events().begin(), events().end(), [](const Event &e) { return e.type == EV_KEY_DOWN; });
        if (!got) { post(hwnd, 0x200, 0, (50 & 0xFFFF) | (60 << 16)); for (uintptr_t vk : {(uintptr_t)'A', (uintptr_t)0x27, (uintptr_t)0x20}) { post(hwnd, 0x100, vk, 0); post(hwnd, 0x101, vk, 0); } pump(); }
        return std::string("SendInput accepted ") + std::to_string(sent) + " events; " + (got ? "they arrived through the system queue" : "they did not arrive (foreground window?), posted window messages were used instead");
    }
    void close() { if (hwnd) { typedef int (WMS *Dw)(void *); ((Dw)cosmo_dlsym(u, "DestroyWindow"))(hwnd); hwnd = nullptr; } }
};
#endif

// ================================================================================================ macOS: AppKit through the Objective-C runtime
#ifdef __aarch64__
struct Cocoa {
    typedef void *id; typedef void *SEL; typedef struct { double x, y; } Pt; typedef struct { double x, y, w, h; } Rc;
    void *rt = nullptr, *cg = nullptr, *msg = nullptr; SEL (*selreg)(const char *) = nullptr; id (*getclass)(const char *) = nullptr; id app = nullptr, win = nullptr, view = nullptr; int w = 0, h = 0; std::string note;
    void *(*cs_create)() = nullptr; void *(*dp_create)(void *, const void *, size_t, void *) = nullptr; void *(*img_create)(size_t, size_t, size_t, size_t, size_t, void *, unsigned, void *, const double *, signed char, int) = nullptr; void (*img_release)(void *) = nullptr;
    void *(*win_image)(Rc, unsigned, unsigned, unsigned) = nullptr; void *(*img_provider)(void *) = nullptr; void *(*prov_copy)(void *) = nullptr; const uint8_t *(*cfdata_ptr)(void *) = nullptr; long (*cfdata_len)(void *) = nullptr; void (*cf_release)(void *) = nullptr;
    void *space = nullptr; std::vector<Event> pend; std::string why, verify_note; int seen_types[32] = {};
    template <class R, class... A> R call(id o, const char *s, A... a) { return ((R (*)(id, SEL, A...))msg)(o, selreg(s), a...); }
    bool open(int width, int height, const char *title, std::string &n) {
        rt = cosmo_dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW); void *ak = cosmo_dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW); cg = cosmo_dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW);
        if (!rt || !ak || !cg) { n = "Objective-C runtime, AppKit or CoreGraphics not available"; return false; }
        auto sym = [](void *h, const char *nm) { void *p = h ? cosmo_dlsym(h, nm) : nullptr; return p ? cosmo_dltramp(p) : nullptr; };
        selreg = (decltype(selreg))sym(rt, "sel_registerName"); getclass = (decltype(getclass))sym(rt, "objc_getClass"); msg = sym(rt, "objc_msgSend"); if (!selreg || !getclass || !msg) { n = "objc entry points missing"; return false; }
        cs_create = (decltype(cs_create))sym(cg, "CGColorSpaceCreateDeviceRGB"); dp_create = (decltype(dp_create))sym(cg, "CGDataProviderCreateWithData"); img_create = (decltype(img_create))sym(cg, "CGImageCreate"); img_release = (decltype(img_release))sym(cg, "CGImageRelease");
        win_image = (decltype(win_image))sym(cg, "CGWindowListCreateImage"); img_provider = (decltype(img_provider))sym(cg, "CGImageGetDataProvider"); prov_copy = (decltype(prov_copy))sym(cg, "CGDataProviderCopyData");
        void *cf = cosmo_dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW); cfdata_ptr = (decltype(cfdata_ptr))sym(cf, "CFDataGetBytePtr"); cfdata_len = (decltype(cfdata_len))sym(cf, "CFDataGetLength"); cf_release = (decltype(cf_release))sym(cf, "CFRelease");
        if (!cs_create || !dp_create || !img_create) { n = "CoreGraphics entry points missing"; return false; }
        id NSApp = getclass("NSApplication"), NSWindow = getclass("NSWindow"), NSString = getclass("NSString"); app = call<id>(NSApp, "sharedApplication"); call<long, long>(app, "setActivationPolicy:", 0);
        win = call<id>(NSWindow, "alloc"); Rc rc = {100, 100, (double)width, (double)height}; win = call<id, Rc, unsigned long, unsigned long, signed char>(win, "initWithContentRect:styleMask:backing:defer:", rc, 3 /*titled, closable*/, 2, 0); if (!win) { n = "NSWindow creation failed"; return false; }
        id str = call<id, const char *>(NSString, "stringWithUTF8String:", title); call<void, id>(win, "setTitle:", str); call<void, signed char>(win, "setAcceptsMouseMovedEvents:", 1);
        view = call<id>(win, "contentView"); call<void, signed char>(view, "setWantsLayer:", 1); call<void, id>(win, "makeKeyAndOrderFront:", nullptr); call<void>(app, "finishLaunching"); call<void, signed char>(app, "activateIgnoringOtherApps:", 1);
        space = cs_create(); w = width; h = height; pump(); n = "AppKit window, layer contents from a CGImage, " + std::to_string(w) + "x" + std::to_string(h); note = n; return true;
    }
    void pump() {
        id past = call<id>(getclass("NSDate"), "distantPast"); id mode = call<id, const char *>(getclass("NSString"), "stringWithUTF8String:", "kCFRunLoopDefaultMode");
        for (int i = 0; i < 100; i++) { id ev = call<id, unsigned long, id, id, signed char>(app, "nextEventMatchingMask:untilDate:inMode:dequeue:", ~0ul, past, mode, 1); if (!ev) break;
            unsigned long t = call<unsigned long>(ev, "type"); if (t < 32) seen_types[t]++; auto key = [](unsigned short c) { switch (c) { case 0: case 123: return 1; case 2: case 124: return 2; case 13: case 126: return 3; case 1: case 125: return 4; case 49: return 5; default: return 0; } };
            if (t == 10 || t == 11) { int k = key(call<unsigned short>(ev, "keyCode")); bool rep = t == 10 && call<signed char>(ev, "isARepeat"); if (k && !rep) pend.push_back({t == 10 ? EV_KEY_DOWN : EV_KEY_UP, k, 0}); }
            else if (t == 5) { Pt p = call<Pt>(ev, "locationInWindow"); pend.push_back({EV_MOUSE, (int)p.x, h - (int)p.y}); }   // origin is the bottom left
            call<void, id>(app, "sendEvent:", ev); } }
    bool present(const uint8_t *rgba, int fw, int fh) {
        static std::vector<uint8_t> keep[3]; static int k = 0; auto &buf = keep[k++ % 3]; buf.assign(rgba, rgba + (size_t)fw * fh * 4);   // the image keeps pointing at this memory until a later frame replaces the layer contents
        void *prov = dp_create(nullptr, buf.data(), buf.size(), nullptr); void *img = img_create((size_t)fw, (size_t)fh, 8, 32, (size_t)fw * 4, space, 5 /*kCGImageAlphaNoneSkipLast*/, prov, nullptr, 0, 0);
        if (!img) { why = "CGImageCreate returned nothing"; return false; } id layer = call<id>(view, "layer"); if (!layer) { pump(); layer = call<id>(view, "layer"); } if (!layer) { img_release(img); why = "the content view has no layer"; return false; } call<void, id>(layer, "setContents:", (id)img); img_release(img); pump(); return true;
    }
    bool verify(const uint8_t *rgba, int fw, int fh, int &mismatch) {   // reads the window back with CGWindowListCreateImage: macOS asks for the Screen Recording permission and otherwise returns nothing or a blank image
        mismatch = -1; if (!win_image || !img_provider || !prov_copy || !cfdata_ptr) return false; long num = call<long>(win, "windowNumber"); Rc null_rect = {INFINITY, INFINITY, 0, 0}; void *img = win_image(null_rect, 8 /*kCGWindowListOptionIncludingWindow*/, (unsigned)num, 1 /*bounds ignore framing*/); if (!img) return false;
        void *data = prov_copy(img_provider(img)); if (!data) return false; long len = cfdata_len(data); if (len < (long)fw * fh * 4) { cf_release(data); return false; } const uint8_t *q = cfdata_ptr(data); mismatch = 0;
        // the captured pixels went through the display's colour management (the layer's colour space to the screen's), so they are close to, not equal to, what was set: count the pixels whose channels are all within 24 levels
        // of the frame (red and blue order of the capture is device dependent: the better of the two orders is used) and keep the mean absolute error for the log
        long err_a = 0, err_b = 0; int bad_a = 0, bad_b = 0; for (int i = 0; i < fw * fh; i++) { const uint8_t *c = q + 4 * i, *e = rgba + 4 * i;
            int da = abs(c[0] - e[0]) + abs(c[1] - e[1]) + abs(c[2] - e[2]), db = abs(c[0] - e[2]) + abs(c[1] - e[1]) + abs(c[2] - e[0]); err_a += da; err_b += db; if (abs(c[0] - e[0]) > 24 || abs(c[1] - e[1]) > 24 || abs(c[2] - e[2]) > 24) bad_a++; if (abs(c[0] - e[2]) > 24 || abs(c[1] - e[1]) > 24 || abs(c[2] - e[0]) > 24) bad_b++; }
        mismatch = std::min(bad_a, bad_b); verify_note = "colour-managed capture: mean absolute error per pixel (sum of three channels) " + std::to_string((double)std::min(err_a, err_b) / (fw * fh)) + ", " + std::to_string(mismatch) + " pixels with a channel more than 24 levels away";
        cf_release(data); img_release(img); return true;
    }
    void poll_events(std::vector<Event> &out) { pump(); out.insert(out.end(), pend.begin(), pend.end()); pend.clear(); }
    std::string inject() {   // synthetic NSEvents queued to the application: exercises the event mapping, not the operating system's input path
        id NSEvent = getclass("NSEvent"), NSString = getclass("NSString"); long num = call<long>(win, "windowNumber"); Pt loc = {50, (double)(h - 60)};
        for (const char *ch : {"a", "\xef\x9c\x83", " "}) { unsigned short kc = ch[0] == 'a' ? 0 : ch[0] == ' ' ? 49 : 124; id cs = call<id, const char *>(NSString, "stringWithUTF8String:", ch);
            for (unsigned long type : {10ul, 11ul}) { id ev = ((id (*)(id, SEL, unsigned long, Pt, unsigned long, double, long, id, id, id, signed char, unsigned short))msg)(NSEvent, selreg("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"), type, loc, 0, 0.0, num, nullptr, cs, cs, 0, kc); if (ev) call<void, id, signed char>(app, "postEvent:atStart:", ev, 0); } }
        id mev = ((id (*)(id, SEL, unsigned long, Pt, unsigned long, double, long, id, long, long, float))msg)(NSEvent, selreg("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"), 5, loc, 0, 0.0, num, nullptr, 0, 0, 0.0f); if (mev) call<void, id, signed char>(app, "postEvent:atStart:", mev, 0);
        for (int i = 0; i < 10; i++) { pump(); win::wsleep_ms(10); } return "synthetic NSEvents posted to the application";
    }
    void close() { if (win) { call<void>(win, "close"); win = nullptr; } }
};
#endif

// ================================================================================================ the one interface
class Window {
public:
    std::string backend, note;
    bool open(int w, int h, const char *title) {
        w_ = w; h_ = h;
        if (IsWindows()) {
#if defined(__x86_64__)
            backend = "gdi"; use_ = 1; return g_.open(w, h, title, note);
#endif
        } else if (IsXnu()) {
#ifdef __aarch64__
            backend = "appkit"; use_ = 2; return c_.open(w, h, title, note);
#endif
        }
        const char *want = getenv("WINDOW_BACKEND"); bool try_wl = !want ? (getenv("WAYLAND_DISPLAY") != nullptr) : !strcmp(want, "wayland");
        if (try_wl) { backend = "wayland"; if (wl_.open(w, h, title, note)) { use_ = 3; return true; } if (want) return false; std::string why = note; wl_.close(); wl_ = Wayland(); backend = "x11"; bool ok = x_.open(w, h, title, note); note += " (Wayland failed first: " + why + ")"; return ok; }
        backend = "x11"; return x_.open(w, h, title, note);
    }
    bool present(const uint8_t *rgba, int w, int h) {
#if defined(__x86_64__)
        if (use_ == 1) return g_.present(rgba, w, h);
#endif
#ifdef __aarch64__
        if (use_ == 2) return c_.present(rgba, w, h);
#endif
        return use_ == 3 ? wl_.present(rgba, w, h) : x_.present(rgba, w, h);
    }
    void poll(std::vector<Event> &out) {
#if defined(__x86_64__)
        if (use_ == 1) { g_.poll_events(out); return; }
#endif
#ifdef __aarch64__
        if (use_ == 2) { c_.poll_events(out); return; }
#endif
        if (use_ == 3) wl_.poll_events(out); else x_.poll_events(out);
    }
    bool verify(const uint8_t *rgba, int w, int h, int &mismatch) {   // (a Wayland compositor does not let a client read its window back; the test harness takes a screenshot)
#if defined(__x86_64__)
        if (use_ == 1) return g_.verify(rgba, w, h, mismatch);
#endif
#ifdef __aarch64__
        if (use_ == 2) return c_.verify(rgba, w, h, mismatch);
#endif
        if (use_ == 3) { mismatch = -1; return false; } return x_.verify(rgba, w, h, mismatch);
    }
    // test input where the program itself can supply it (Windows, macOS); empty on Linux, where the harness types and moves the pointer from outside
    std::string inject() {
#if defined(__x86_64__)
        if (use_ == 1) return g_.inject();
#endif
#ifdef __aarch64__
        if (use_ == 2) { std::string r = c_.inject(); char b[200]; snprintf(b, sizeof b, "; event types dequeued: key down %d, key up %d, mouse moved %d, other %d", c_.seen_types[10], c_.seen_types[11], c_.seen_types[5], c_.seen_types[1] + c_.seen_types[2] + c_.seen_types[4]); return r + b; }
#endif
        return "";
    }
    std::string detail() const {
#ifdef __aarch64__
        if (use_ == 2) return c_.why + (c_.verify_note.empty() ? "" : (c_.why.empty() ? "" : "; ") + c_.verify_note);
#endif
        return "";
    }
    void close() {
#if defined(__x86_64__)
        if (use_ == 1) { g_.close(); return; }
#endif
#ifdef __aarch64__
        if (use_ == 2) { c_.close(); return; }
#endif
        if (use_ == 3) wl_.close(); else x_.close();
    }
private:
    int w_ = 0, h_ = 0, use_ = 0; X11 x_; Wayland wl_;
#if defined(__x86_64__)
    Gdi g_;
#endif
#ifdef __aarch64__
    Cocoa c_;
#endif
};

}   // namespace win
