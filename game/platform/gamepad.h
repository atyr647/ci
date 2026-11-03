// Gamepads for a Cosmopolitan program, one interface, three operating-system back ends reached at run time (no library is linked in):
//   Linux:   evdev, /dev/input/event* opened directly (ioctl and read, nothing from the C library of the system; works without glibc)
//   Windows: XInput (xinput1_4.dll) through ms_abi function pointers (x86-64 half; the Windows arm64 machines run that half too)
//   macOS:   the GameController framework through the Objective-C runtime (polling the extended gamepad profile, no blocks needed)
// Events use the XInput conventions on every OS: buttons 0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 Back, 7 Start, 8 Guide, 9 LS, 10 RS, 11 DUp, 12 DDown, 13 DLeft, 14 DRight (value 0 or 1);
// axes 0 LX, 1 LY, 2 RX, 3 RY (-32768..32767, up and right positive), 4 LT, 5 RT (0..32767).
#pragma once
#define _COSMO_SOURCE 1
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cosmo.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>

namespace pad {

enum { EV_BUTTON = 1, EV_AXIS = 2, EV_CONNECT = 3, EV_DISCONNECT = 4 };
struct Event { int type, pad, index, value; };
enum { B_A, B_B, B_X, B_Y, B_LB, B_RB, B_BACK, B_START, B_GUIDE, B_LS, B_RS, B_DUP, B_DDOWN, B_DLEFT, B_DRIGHT, kButtons };
enum { A_LX, A_LY, A_RX, A_RY, A_LT, A_RT, kAxes };

static inline void *psym(void *h, const char *n) { void *p = h ? cosmo_dlsym(h, n) : nullptr; return p ? cosmo_dltramp(p) : nullptr; }
static inline double now_s() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

// ================================================================================================ Linux evdev
struct Evdev {
    struct Dev { int fd; std::string path, name; int pad; int32_t amin[kAxes + 2], amax[kAxes + 2]; int hatx = 0, haty = 0; };
    std::vector<Dev> devs; std::vector<std::string> seen_bad; double last_scan = -10; int next_pad = 0;
    static unsigned long ioc(unsigned dir, unsigned type, unsigned nr, unsigned size) { return ((unsigned long)dir << 30) | ((unsigned long)size << 16) | ((unsigned long)type << 8) | nr; }
    static bool bit(const uint8_t *m, int b) { return m[b / 8] & (1 << (b % 8)); }
    static int map_button(int code) { switch (code) { case 0x130: return B_A; case 0x131: return B_B; case 0x133: return B_Y; case 0x134: return B_X; case 0x136: return B_LB; case 0x137: return B_RB; case 0x13a: return B_BACK; case 0x13b: return B_START; case 0x13c: return B_GUIDE;
        case 0x13d: return B_LS; case 0x13e: return B_RS; case 0x220: return B_DUP; case 0x221: return B_DDOWN; case 0x222: return B_DLEFT; case 0x223: return B_DRIGHT; default: return -1; } }
    // returns the standard axis for an evdev ABS code, -1 when it is not an axis we use
    static int map_axis(int code) { switch (code) { case 0: return A_LX; case 1: return A_LY; case 3: return A_RX; case 4: return A_RY; case 2: return A_LT; case 5: return A_RT; default: return -1; } }
    void scan(std::vector<Event> &out) {
        double t = now_s(); if (t - last_scan < 0.5) return; last_scan = t;
        for (int i = 0; i < 64; i++) {
            char path[32]; snprintf(path, sizeof path, "/dev/input/event%d", i);
            bool have = false; for (auto &d : devs) if (d.path == path) have = true; if (have) continue;
            int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC); if (fd < 0) continue;
            uint8_t ev[4] = {}, key[96] = {}, abs[8] = {}; ioctl(fd, ioc(2, 'E', 0x20, sizeof ev), ev); ioctl(fd, ioc(2, 'E', 0x20 + 1, sizeof key), key); ioctl(fd, ioc(2, 'E', 0x20 + 3, sizeof abs), abs);
            bool gamepad = bit(ev, 1) && bit(ev, 3) && bit(key, 0x130) && bit(abs, 0) && bit(abs, 1);   // EV_KEY and EV_ABS, BTN_SOUTH, ABS_X and ABS_Y
            if (!gamepad) { close(fd); continue; }
            char name[128] = {}; ioctl(fd, ioc(2, 'E', 0x06, sizeof name - 1), name);
            Dev d; d.fd = fd; d.path = path; d.name = name; d.pad = next_pad++;
            for (int a = 0; a <= 5; a++) { int32_t ai[6] = {}; if (ioctl(fd, ioc(2, 'E', 0x40 + a, sizeof ai), ai) == 0) { d.amin[a] = ai[1]; d.amax[a] = ai[2]; } else { d.amin[a] = 0; d.amax[a] = 0; } }
            devs.push_back(d); out.push_back({EV_CONNECT, d.pad, 0, 0});
        }
    }
    void poll(std::vector<Event> &out) {
        scan(out);
        for (size_t i = 0; i < devs.size();) {
            Dev &d = devs[i]; bool dead = false;
            for (int n = 0; n < 256; n++) {
                struct { int64_t sec, usec; uint16_t type, code; int32_t value; } e;
                ssize_t r = read(d.fd, &e, sizeof e); if (r != (ssize_t)sizeof e) { if (r < 0 && errno != EAGAIN && errno != EINTR) dead = true; break; }
                if (e.type == 1) { int b = map_button(e.code); if (b >= 0) out.push_back({EV_BUTTON, d.pad, b, e.value ? 1 : 0}); }
                else if (e.type == 3) {
                    if (e.code == 0x10) { int h = e.value < 0 ? -1 : e.value > 0 ? 1 : 0; if (d.hatx != h) { if (d.hatx) out.push_back({EV_BUTTON, d.pad, d.hatx < 0 ? B_DLEFT : B_DRIGHT, 0}); if (h) out.push_back({EV_BUTTON, d.pad, h < 0 ? B_DLEFT : B_DRIGHT, 1}); d.hatx = h; } }
                    else if (e.code == 0x11) { int h = e.value < 0 ? -1 : e.value > 0 ? 1 : 0; if (d.haty != h) { if (d.haty) out.push_back({EV_BUTTON, d.pad, d.haty < 0 ? B_DUP : B_DDOWN, 0}); if (h) out.push_back({EV_BUTTON, d.pad, h < 0 ? B_DUP : B_DDOWN, 1}); d.haty = h; } }
                    else { int ax = map_axis(e.code); if (ax >= 0 && e.code <= 5 && d.amax[e.code] > d.amin[e.code]) {
                        double span = (double)d.amax[e.code] - d.amin[e.code], f = ((double)e.value - d.amin[e.code]) / span;   // 0..1
                        int v = (ax == A_LT || ax == A_RT) ? (int)(f * 32767.0 + 0.5) : (int)(f * 65535.0 - 32768.0 + 0.5);
                        if (ax == A_LY || ax == A_RY) v = -v - 1;   // evdev has up negative, the standard layout up positive
                        out.push_back({EV_AXIS, d.pad, ax, std::max(-32768, std::min(32767, v))}); } }
                }
            }
            if (dead) { out.push_back({EV_DISCONNECT, d.pad, 0, 0}); close(d.fd); devs.erase(devs.begin() + i); } else i++;
        }
    }
    int count() const { return (int)devs.size(); }
    std::string names() const { std::string s; for (auto &d : devs) s += (s.empty() ? "" : "; ") + d.name; return s; }
};

// ================================================================================================ Windows XInput
#if defined(__x86_64__)
#define PMS __attribute__((ms_abi))
struct XInput {
    struct State { unsigned packet; unsigned short buttons; unsigned char lt, rt; short lx, ly, rx, ry; };
    unsigned (PMS *get)(unsigned, State *) = nullptr; void *lib = nullptr; State prev[4]; bool conn[4] = {}; double last_probe[4] = {-10, -10, -10, -10}; unsigned last_rc[4] = {0xffff, 0xffff, 0xffff, 0xffff}; std::string lib_name;
    bool init(std::string &note) {
        if (!IsWindows()) { note = "not Windows"; return false; }
        for (const char *n : {"xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll"}) { lib = cosmo_dlopen(n, RTLD_NOW); if (lib) { lib_name = n; break; } }
        if (!lib) { note = "no XInput library"; return false; }
        get = (decltype(get))cosmo_dlsym(lib, "XInputGetState"); if (!get) { note = "XInputGetState missing"; return false; }
        note = lib_name + " loaded"; return true;
    }
    void poll(std::vector<Event> &out) {
        static const struct { unsigned short mask; int b; } map[] = {{0x1000, B_A}, {0x2000, B_B}, {0x4000, B_X}, {0x8000, B_Y}, {0x100, B_LB}, {0x200, B_RB}, {0x20, B_BACK}, {0x10, B_START}, {0x40, B_LS}, {0x80, B_RS}, {0x1, B_DUP}, {0x2, B_DDOWN}, {0x4, B_DLEFT}, {0x8, B_DRIGHT}};
        double t = now_s();
        for (unsigned i = 0; i < 4; i++) {
            if (!conn[i] && t - last_probe[i] < 1.0) continue;   // looking for a controller in an empty slot is slow on some systems: once a second
            last_probe[i] = t; State s; memset(&s, 0, sizeof s); unsigned rc = get(i, &s); last_rc[i] = rc;
            if (rc != 0) { if (conn[i]) { conn[i] = false; out.push_back({EV_DISCONNECT, (int)i, 0, 0}); } continue; }
            if (!conn[i]) { conn[i] = true; memset(&prev[i], 0, sizeof prev[i]); out.push_back({EV_CONNECT, (int)i, 0, 0}); }
            if (s.packet == prev[i].packet) continue;
            for (auto &m : map) if ((s.buttons ^ prev[i].buttons) & m.mask) out.push_back({EV_BUTTON, (int)i, m.b, (s.buttons & m.mask) ? 1 : 0});
            if (s.lx != prev[i].lx) out.push_back({EV_AXIS, (int)i, A_LX, s.lx}); if (s.ly != prev[i].ly) out.push_back({EV_AXIS, (int)i, A_LY, s.ly});
            if (s.rx != prev[i].rx) out.push_back({EV_AXIS, (int)i, A_RX, s.rx}); if (s.ry != prev[i].ry) out.push_back({EV_AXIS, (int)i, A_RY, s.ry});
            if (s.lt != prev[i].lt) out.push_back({EV_AXIS, (int)i, A_LT, s.lt * 32767 / 255}); if (s.rt != prev[i].rt) out.push_back({EV_AXIS, (int)i, A_RT, s.rt * 32767 / 255});
            prev[i] = s;
        }
    }
    int count() const { int n = 0; for (bool c : conn) n += c; return n; }
    std::string status() const { std::string s = lib_name + ", XInputGetState results per slot:"; for (int i = 0; i < 4; i++) s += " " + std::to_string(last_rc[i] == 0xffff ? -1 : (int)last_rc[i]); s += " (0 = connected, 1167 = no controller)"; return s; }
};
#endif

// ================================================================================================ macOS GameController
#ifdef __aarch64__
struct GameController {
    typedef void *id; typedef void *SEL;
    void *rt = nullptr, *fw = nullptr; void *msg = nullptr; SEL (*selreg)(const char *) = nullptr; id (*getclass)(const char *) = nullptr; id cls = nullptr; std::vector<id> known; struct S { bool b[kButtons]; int a[kAxes]; }; std::vector<S> prev; std::string note_;
    id call(id o, const char *s) { return ((id (*)(id, SEL))msg)(o, selreg(s)); }
    float fcall(id o, const char *s) { return ((float (*)(id, SEL))msg)(o, selreg(s)); }
    bool bcall(id o, const char *s) { return ((signed char (*)(id, SEL))msg)(o, selreg(s)) != 0; }
    unsigned long ucall(id o, const char *s) { return ((unsigned long (*)(id, SEL))msg)(o, selreg(s)); }
    bool init(std::string &note) {
        if (!IsXnu()) { note = "not macOS"; return false; }
        rt = cosmo_dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW); fw = cosmo_dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_NOW);
        if (!rt || !fw) { note = "Objective-C runtime or GameController.framework not available"; return false; }
        selreg = (decltype(selreg))psym(rt, "sel_registerName"); getclass = (decltype(getclass))psym(rt, "objc_getClass"); msg = psym(rt, "objc_msgSend");
        if (!selreg || !getclass || !msg) { note = "objc entry points missing"; return false; }
        cls = getclass("GCController"); if (!cls) { note = "GCController class not found"; return false; }
        note = "GameController.framework loaded"; return true;
    }
    void poll(std::vector<Event> &out) {
        id arr = call(cls, "controllers"); unsigned long n = arr ? ucall(arr, "count") : 0;
        std::vector<id> cur; for (unsigned long i = 0; i < n; i++) cur.push_back(((id (*)(id, SEL, unsigned long))msg)(arr, selreg("objectAtIndex:"), i));
        for (size_t i = 0; i < known.size(); i++) if (std::find(cur.begin(), cur.end(), known[i]) == cur.end()) { out.push_back({EV_DISCONNECT, (int)i, 0, 0}); }
        for (size_t i = 0; i < cur.size(); i++) if (std::find(known.begin(), known.end(), cur[i]) == known.end()) { out.push_back({EV_CONNECT, (int)i, 0, 0}); }
        known = cur; prev.resize(cur.size(), S{});
        for (size_t i = 0; i < cur.size(); i++) {
            id g = call(cur[i], "extendedGamepad"); if (!g) continue; S s; memset(&s, 0, sizeof s);
            auto btn = [&](int idx, const char *prop) { id b = call(g, prop); if (b) s.b[idx] = bcall(b, "isPressed"); };
            btn(B_A, "buttonA"); btn(B_B, "buttonB"); btn(B_X, "buttonX"); btn(B_Y, "buttonY"); btn(B_LB, "leftShoulder"); btn(B_RB, "rightShoulder"); btn(B_START, "buttonMenu"); btn(B_BACK, "buttonOptions"); btn(B_GUIDE, "buttonHome"); btn(B_LS, "leftThumbstickButton"); btn(B_RS, "rightThumbstickButton");
            if (id d = call(g, "dpad")) { auto dd = [&](int idx, const char *p) { id b = call(d, p); if (b) s.b[idx] = bcall(b, "isPressed"); }; dd(B_DUP, "up"); dd(B_DDOWN, "down"); dd(B_DLEFT, "left"); dd(B_DRIGHT, "right"); }
            auto stick = [&](int ax, int ay, const char *p) { id st = call(g, p); if (!st) return; id x = call(st, "xAxis"), y = call(st, "yAxis"); if (x) s.a[ax] = (int)(fcall(x, "value") * 32767.0f); if (y) s.a[ay] = (int)(fcall(y, "value") * 32767.0f); };
            stick(A_LX, A_LY, "leftThumbstick"); stick(A_RX, A_RY, "rightThumbstick");
            if (id t = call(g, "leftTrigger")) s.a[A_LT] = (int)(fcall(t, "value") * 32767.0f); if (id t = call(g, "rightTrigger")) s.a[A_RT] = (int)(fcall(t, "value") * 32767.0f);
            for (int b = 0; b < kButtons; b++) if (s.b[b] != prev[i].b[b]) out.push_back({EV_BUTTON, (int)i, b, s.b[b] ? 1 : 0});
            for (int a = 0; a < kAxes; a++) if (s.a[a] != prev[i].a[a]) out.push_back({EV_AXIS, (int)i, a, s.a[a]});
            prev[i] = s;
        }
    }
    int count() const { return (int)known.size(); }
};
#endif

// ================================================================================================ the one interface
class Gamepads {
public:
    std::string backend, note;
    bool init() {
        std::string n;
        if (IsWindows()) {
#if defined(__x86_64__)
            backend = "xinput"; bool ok = xi_.init(n); note = n; return ok;
#endif
        } else if (IsXnu()) {
#ifdef __aarch64__
            backend = "gamecontroller"; bool ok = gc_.init(n); note = n; return ok;
#endif
        } else { backend = "evdev"; note = "/dev/input/event*"; return true; }
        backend = "none"; note = "no gamepad back end for this platform"; return false;
    }
    void poll(std::vector<Event> &out) {
        if (IsWindows()) {
#if defined(__x86_64__)
            if (xi_.get) xi_.poll(out);
#endif
        } else if (IsXnu()) {
#ifdef __aarch64__
            if (gc_.msg) gc_.poll(out);
#endif
        } else ev_.poll(out);
    }
    int count() const {
        if (IsWindows()) {
#if defined(__x86_64__)
            return xi_.count();
#endif
        } else if (IsXnu()) {
#ifdef __aarch64__
            return gc_.count();
#endif
        }
        return ev_.count();
    }
    std::string detail() const {
        if (IsWindows()) {
#if defined(__x86_64__)
            return xi_.status();
#endif
        } else if (!IsXnu()) return ev_.names();
        return "";
    }
private:
    Evdev ev_;
#if defined(__x86_64__)
    XInput xi_;
#endif
#ifdef __aarch64__
    GameController gc_;
#endif
};

}   // namespace pad
