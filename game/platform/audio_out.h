// Real-time audio output for a Cosmopolitan program.
//   producer: the game thread (the guest's audio_write) pushes interleaved stereo int16 frames into a lock-free single-producer single-consumer ring and never blocks;
//   consumer: an audio thread pops one device period at a time and hands it to a backend that blocks until the device has room (the device is the clock);
//             when the ring holds less than a period the missing frames are silence and the event is counted (an under-run).
// Backends: "timed" (a software clock, always available, models a device), Linux ALSA (libasound reached with cosmo_dlopen), macOS AudioQueue (AudioToolbox), Windows waveOut (winmm).
// Selected by GAME_AUDIO=timed|device|off (default timed); GAME_AUDIO_DEV=<ALSA pcm name>; with GAME_AUDIO_REQUIRE=1 a device that cannot be opened is a failure instead of a note.
#pragma once
#define _COSMO_SOURCE 1
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include <cosmo.h>
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifdef AUDIO_FOREIGN
// Calls into the system's C library (libasound, libpulse) from a thread Cosmopolitan created need that library's own thread block: the Dawn loader keeps a pool of them (dawn-cosmo/DawnCosmoForeign.h).
// The program calls DawnCosmoForeignInit() on its main thread first; ForeignCall then puts a parked thread's block in place for the duration of one foreign call.
#include "src/dawn/native/vulkan/DawnCosmoForeign.h"
#endif

namespace audio {

struct ForeignCall {
#ifdef AUDIO_FOREIGN
    unsigned long tcb = 0, saved = 0;
    ForeignCall() { static thread_local bool got = false; static thread_local unsigned long t = 0; if (!got) { t = DawnCosmoForeignTcb(); got = true; } tcb = t; if (tcb) saved = DawnCosmoSwapIn(tcb); }
    ~ForeignCall() { if (tcb) DawnCosmoSwapOut(saved); }
#endif
};

constexpr int kRate = 48000, kChannels = 2;

// ------------------------------------------------------------------------------------------------ ring
struct Ring {
    std::vector<int16_t> buf; uint64_t cap = 0;   // capacity in frames, a power of two
    std::atomic<uint64_t> w{0}, r{0};
    void init(uint64_t frames) { cap = 1; while (cap < frames) cap <<= 1; buf.assign(cap * kChannels, 0); w = r = 0; }
    uint64_t fill() const { return w.load(std::memory_order_acquire) - r.load(std::memory_order_acquire); }
    uint64_t push(const int16_t *s, uint64_t n) {   // producer only; returns the number of frames stored (less than n when the ring is full)
        uint64_t wi = w.load(std::memory_order_relaxed), ri = r.load(std::memory_order_acquire), room = cap - (wi - ri); if (n > room) n = room;
        for (uint64_t i = 0; i < n; i++) { uint64_t p = ((wi + i) & (cap - 1)) * kChannels; buf[p] = s[2 * i]; buf[p + 1] = s[2 * i + 1]; }
        w.store(wi + n, std::memory_order_release); return n;
    }
    uint64_t pop(int16_t *d, uint64_t n) {   // consumer only
        uint64_t ri = r.load(std::memory_order_relaxed), wi = w.load(std::memory_order_acquire), have = wi - ri; if (n > have) n = have;
        for (uint64_t i = 0; i < n; i++) { uint64_t p = ((ri + i) & (cap - 1)) * kChannels; d[2 * i] = buf[p]; d[2 * i + 1] = buf[p + 1]; }
        r.store(ri + n, std::memory_order_release); return n;
    }
};

static inline uint64_t fnv(uint64_t h, const int16_t *s, uint64_t frames) { for (uint64_t i = 0; i < frames * kChannels; i++) { h ^= (uint16_t)s[i]; h *= 1099511628211ull; } return h; }
static inline void msleep_ns(long ns) { struct timespec t = {ns / 1000000000L, ns % 1000000000L}; nanosleep(&t, nullptr); }
static inline void *sym(void *h, const char *n) { void *p = h ? cosmo_dlsym(h, n) : nullptr; return p ? cosmo_dltramp(p) : nullptr; }

// ------------------------------------------------------------------------------------------------ backends
struct Backend {
    virtual ~Backend() {}
    virtual const char *name() const = 0;
    virtual bool open(int period_frames, std::string &note) = 0;
    virtual bool write(const int16_t *frames, int n) = 0;   // blocks until the device accepts n frames
    virtual void close() {}
    virtual bool prime() { return true; }   // bring the device to the running state (a sound server wakes its sink from suspend on the first data) before the game starts producing
    uint64_t device_xruns = 0;   // under-runs the device reported itself (ALSA -EPIPE)
};

struct TimedBackend : Backend {   // a clock: every period takes period/rate seconds, whatever else happens
    std::chrono::steady_clock::time_point next; bool started = false;
    const char *name() const override { return "timed"; }
    bool open(int, std::string &note) override { note = "software clock, 48000 Hz"; return true; }
    bool write(const int16_t *, int n) override {
        auto now = std::chrono::steady_clock::now(); if (!started) { next = now; started = true; }
        next += std::chrono::nanoseconds((long long)n * 1000000000LL / kRate);
        if (next > now) msleep_ns((long)std::chrono::duration_cast<std::chrono::nanoseconds>(next - now).count()); else if (now - next > std::chrono::milliseconds(50)) next = now;   // (after a long stall the clock restarts)
        return true;
    }
};

#ifndef _WIN32
struct AlsaBackend : Backend {   // Linux: libasound's blocking PCM interface
    void *lib = nullptr, *pcm = nullptr;
    int (*p_open)(void **, const char *, int, int) = nullptr; int (*p_params)(void *, int, int, unsigned, unsigned, int, unsigned) = nullptr;
    long (*p_writei)(void *, const void *, unsigned long) = nullptr; int (*p_recover)(void *, int, int) = nullptr; int (*p_drain)(void *) = nullptr; int (*p_close)(void *) = nullptr;
    const char *name() const override { return "alsa"; }
    bool open(int, std::string &note) override {
        ForeignCall fc; lib = cosmo_dlopen("libasound.so.2", RTLD_NOW); if (!lib) { note = "libasound.so.2 not available"; return false; }
        p_open = (decltype(p_open))sym(lib, "snd_pcm_open"); p_params = (decltype(p_params))sym(lib, "snd_pcm_set_params"); p_writei = (decltype(p_writei))sym(lib, "snd_pcm_writei");
        p_recover = (decltype(p_recover))sym(lib, "snd_pcm_recover"); p_drain = (decltype(p_drain))sym(lib, "snd_pcm_drain"); p_close = (decltype(p_close))sym(lib, "snd_pcm_close");
        if (!p_open || !p_params || !p_writei || !p_recover) { note = "libasound entry points missing"; return false; }
        const char *dev = getenv("GAME_AUDIO_DEV"); if (!dev || !*dev) dev = "default";
        int rc = p_open(&pcm, dev, 0 /*PLAYBACK*/, 0); if (rc < 0) { note = std::string("snd_pcm_open(") + dev + ") failed: " + std::to_string(rc); return false; }
        rc = p_params(pcm, 2 /*S16_LE*/, 3 /*RW_INTERLEAVED*/, kChannels, kRate, 1 /*soft resample*/, 100000 /*100 ms*/); if (rc < 0) { note = "snd_pcm_set_params failed: " + std::to_string(rc); return false; }
        note = std::string("ALSA pcm \"") + dev + "\", 48000 Hz stereo S16, 100 ms buffer"; return true;
    }
    bool write(const int16_t *f, int n) override {
        ForeignCall fc; while (n > 0) { long w = p_writei(pcm, f, (unsigned long)n);
            if (w < 0) { device_xruns++; if (p_recover(pcm, (int)w, 1) < 0) return false; continue; }
            f += w * kChannels; n -= (int)w; }
        return true;
    }
    void close() override { ForeignCall fc; if (pcm) { if (p_drain) p_drain(pcm); p_close(pcm); pcm = nullptr; } }
};
#endif


#ifndef _WIN32
// The PulseAudio native protocol, spoken directly over the unix socket (PulseAudio and PipeWire's pulse server both answer it): no libpulse, no libasound, nothing from the system's C library, so it works from any
// thread and without glibc. Protocol version 13 (the first with property lists). The server's REQUEST messages say how many bytes it wants: write() blocks until it does, which makes the sound server the clock.
struct PulseBackend : Backend {
    int fd = -1; uint32_t tag = 0, chan = 0xffffffffu, stream = 0; uint64_t requested = 0, underflows = 0; bool ready = false, started = false; std::string err;
    const char *name() const override { return "pulse"; }
    static void p32(std::vector<uint8_t> &b, uint32_t v) { for (int i = 3; i >= 0; i--) b.push_back((v >> (8 * i)) & 255); }
    static uint32_t g32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
    static void tL(std::vector<uint8_t> &b, uint32_t v) { b.push_back('L'); p32(b, v); }
    static void tBool(std::vector<uint8_t> &b, bool v) { b.push_back(v ? '1' : '0'); }
    static void tStr(std::vector<uint8_t> &b, const char *s) { if (!s) { b.push_back('N'); return; } b.push_back('t'); b.insert(b.end(), s, s + strlen(s) + 1); }
    bool send_packet(uint32_t channel, const uint8_t *data, size_t n) {
        std::vector<uint8_t> d; p32(d, (uint32_t)n); p32(d, channel); p32(d, 0); p32(d, 0); p32(d, 0); d.insert(d.end(), data, data + n);
        size_t off = 0; while (off < d.size()) { ssize_t k = ::write(fd, d.data() + off, d.size() - off); if (k < 0) { if (errno == EINTR) continue; return false; } off += (size_t)k; } return true;
    }
    bool rd(void *p, size_t n, int timeout_ms) { uint8_t *b = (uint8_t *)p; while (n) { struct pollfd pf = {fd, POLLIN, 0}; if (poll(&pf, 1, timeout_ms) <= 0) return false; ssize_t k = read(fd, b, n); if (k <= 0) return false; b += k; n -= (size_t)k; } return true; }
    // one packet from the server; control packets are handled here (REQUEST adds to the byte count, UNDERFLOW is counted), a reply to our command is returned in `reply` with its tag
    bool read_packet(std::vector<uint8_t> &reply, uint32_t &rtag, int timeout_ms) {
        uint8_t dsc[20]; if (!rd(dsc, 20, timeout_ms)) return false; uint32_t len = g32(dsc), channel = g32(dsc + 4); std::vector<uint8_t> pl(len); if (len && !rd(pl.data(), len, 2000)) return false;
        if (channel != 0xffffffffu) return true;   // audio data for a record stream: none here
        size_t o = 0; auto u32 = [&]() -> uint32_t { if (o + 5 > pl.size() || pl[o] != 'L') { o = pl.size(); return 0; } uint32_t v = g32(&pl[o + 1]); o += 5; return v; };
        uint32_t cmd = u32(); uint32_t t = u32(); static const bool dbg = getenv("AUDIO_DEBUG") != nullptr; if (dbg) fprintf(stderr, "pulse: command %u tag %u, %u bytes\n", cmd, t, len);
        if (cmd == 61) { u32(); uint32_t nb = u32(); requested += nb; if (dbg) fprintf(stderr, "pulse: server requests %u bytes (now %llu)\n", nb, (unsigned long long)requested); }          // PA_COMMAND_REQUEST: channel, bytes
        else if (cmd == 86) started = true;                                         // PA_COMMAND_STARTED: playback began
        else if (cmd == 57) underflows++;                                           // PA_COMMAND_UNDERFLOW
        else if (cmd == 2 || cmd == 1) { rtag = t; reply.assign(pl.begin() + (long)o, pl.end()); if (cmd == 1) { err = "server error " + std::to_string(reply.size() >= 5 ? g32(&reply[1]) : 0); reply.clear(); reply.push_back(0xff); } return true; }
        return read_packet_again(reply, rtag, timeout_ms, cmd);
    }
    bool read_packet_again(std::vector<uint8_t> &, uint32_t &, int, uint32_t) { return true; }
    bool command(const std::vector<uint8_t> &body, std::vector<uint8_t> &reply) {   // body starts with the command number; the tag is appended after it
        uint32_t my = ++tag; std::vector<uint8_t> b; b.push_back('L'); b.insert(b.end(), body.begin() + 1, body.begin() + 5); tL(b, my); b.insert(b.end(), body.begin() + 5, body.end());
        if (!send_packet(0xffffffffu, b.data(), b.size())) return false;
        for (int i = 0; i < 100; i++) { std::vector<uint8_t> r; uint32_t rt = 0; if (!read_packet(r, rt, 3000)) return false; if (rt == my && !r.empty()) { if (r[0] == 0xff) return false; reply = r; return true; } if (rt == my) { reply.clear(); return true; } }
        return false;
    }
    bool open(int, std::string &note) override {
        const char *srv = getenv("PULSE_SERVER"), *rt = getenv("XDG_RUNTIME_DIR"); std::string path;
        if (srv && !strncmp(srv, "unix:", 5)) path = srv + 5; else if (srv && *srv == '/') path = srv; else if (rt && *rt) path = std::string(rt) + "/pulse/native"; else path = "/run/user/" + std::to_string(getuid()) + "/pulse/native";
        struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX; snprintf(sa.sun_path, sizeof sa.sun_path, "%s", path.c_str());
        fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0); if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof sa)) { note = "cannot connect to the sound server socket " + path + ": " + strerror(errno); return false; }
        // authentication: the cookie file when there is one (a server also trusts a local peer with the same user id)
        std::vector<uint8_t> cookie(256, 0); { std::string cp; if (const char *c = getenv("PULSE_COOKIE")) cp = c; else if (const char *h = getenv("HOME")) cp = std::string(h) + "/.config/pulse/cookie"; if (FILE *f = fopen(cp.c_str(), "rb")) { size_t k = fread(cookie.data(), 1, 256, f); (void)k; fclose(f); } }
        std::vector<uint8_t> b; tL(b, 8); tL(b, 0); tL(b, 13); b.push_back('x'); p32(b, 256); b.insert(b.end(), cookie.begin(), cookie.end());   // PA_COMMAND_AUTH, tag, version, cookie
        std::vector<uint8_t> rep; if (!command_raw(b, rep)) { note = "the sound server refused the connection" + (err.empty() ? std::string() : " (" + err + ")"); return false; }
        std::vector<uint8_t> c; tL(c, 9); tL(c, 0); c.push_back('P'); tStr(c, "application.name"); tL(c, 7); c.push_back('x'); p32(c, 7); { const char *an = "celori"; c.insert(c.end(), an, an + 7); } tStr(c, nullptr);   // PA_COMMAND_SET_CLIENT_NAME with a property list
        if (!command_raw(c, rep)) { note = "set client name failed"; return false; }
        std::vector<uint8_t> s; tL(s, 3); tL(s, 0);   // PA_COMMAND_CREATE_PLAYBACK_STREAM
        s.push_back('a'); s.push_back(3 /*S16LE*/); s.push_back(2); p32(s, 48000); s.push_back('m'); s.push_back(2); s.push_back(1); s.push_back(2);   // sample spec, channel map: front left, front right
        tL(s, 0xffffffffu); tStr(s, nullptr); tL(s, 0xffffffffu /*maxlength*/); tBool(s, false); tL(s, 19200 /*tlength: 100 ms*/); tL(s, 0xffffffffu /*prebuf*/); tL(s, 0xffffffffu /*minreq*/); tL(s, 0); s.push_back('v'); s.push_back(2); p32(s, 0x10000); p32(s, 0x10000);
        for (int i = 0; i < 7; i++) tBool(s, false);   // no_remap, no_remix, fix_format, fix_rate, fix_channels, no_move, variable_rate
        tBool(s, false); tBool(s, true); s.push_back('P'); tStr(s, "media.name"); tL(s, 5); s.push_back('x'); p32(s, 5); { const char *mn = "game"; s.insert(s.end(), mn, mn + 5); } tStr(s, nullptr);   // muted, adjust_latency, property list
        if (!command_raw(s, rep) || rep.size() < 15) { note = "the sound server did not create the stream" + (err.empty() ? std::string() : " (" + err + ")"); return false; }
        size_t o = 0; auto u32 = [&]() -> uint32_t { if (o + 5 > rep.size() || rep[o] != 'L') { o = rep.size(); return 0; } uint32_t v = g32(&rep[o + 1]); o += 5; return v; };
        chan = u32(); stream = u32(); uint32_t missing = u32(); requested = missing; ready = true;
        note = "PulseAudio native protocol on " + path + ", 48000 Hz stereo S16, stream " + std::to_string(stream) + ", " + std::to_string(missing) + " bytes requested at the start"; return true;
    }
    bool command_raw(const std::vector<uint8_t> &body, std::vector<uint8_t> &reply) {   // body already holds command and tag (tag 0 here: replace it)
        uint32_t my = ++tag; std::vector<uint8_t> b(body); b[6] = (my >> 24) & 255; b[7] = (my >> 16) & 255; b[8] = (my >> 8) & 255; b[9] = my & 255; err.clear();
        if (!send_packet(0xffffffffu, b.data(), b.size())) return false;
        for (int i = 0; i < 100; i++) { std::vector<uint8_t> r; uint32_t rt = 0; if (!read_packet(r, rt, 3000)) return false; if (rt == my) { if (!r.empty() && r[0] == 0xff) return false; reply = r; return true; } }
        return false;
    }
    bool write(const int16_t *frames, int n) override {
        const uint8_t *p = (const uint8_t *)frames; size_t bytes = (size_t)n * 4;
        while (bytes) { while (requested == 0) { std::vector<uint8_t> r; uint32_t rt; if (!read_packet(r, rt, 3000)) { if (getenv("AUDIO_DEBUG")) fprintf(stderr, "pulse: no request from the server for 3 s (errno %d)\n", errno); return false; } }
            size_t k = std::min<size_t>(bytes, (size_t)requested); if (!send_packet(chan, p, k)) { if (getenv("AUDIO_DEBUG")) fprintf(stderr, "pulse: send failed (errno %d)\n", errno); return false; } requested -= k; p += k; bytes -= k; }
        std::vector<uint8_t> r; uint32_t rt; struct pollfd pf = {fd, POLLIN, 0}; while (poll(&pf, 1, 0) > 0) { if (!read_packet(r, rt, 100)) break; }   // pick up REQUEST and UNDERFLOW messages that arrived meanwhile
        device_xruns = underflows; return true;
    }
    bool prime() override {   // feed silence until the server has started the stream (a sink wakes from suspend, which takes up to a second), then for 100 ms more: the device buffer is full when the game starts producing
        std::vector<int16_t> z(480 * 2, 0); auto t0 = std::chrono::steady_clock::now(), ts = t0; bool seen = false;
        while (std::chrono::steady_clock::now() - t0 < std::chrono::seconds(3)) {
            if (requested >= 1920) { if (!write(z.data(), 480)) return false; }
            else { struct pollfd pf = {fd, POLLIN, 0}; std::vector<uint8_t> r; uint32_t rt = 0; if (poll(&pf, 1, 5) > 0) read_packet(r, rt, 100); }
            if (started && !seen) { seen = true; ts = std::chrono::steady_clock::now(); }
            if (seen && std::chrono::steady_clock::now() - ts > std::chrono::milliseconds(100)) break;
        }
        return true;
    }
    void close() override { if (fd >= 0) { ::close(fd); fd = -1; } }
};
#endif
#ifdef __aarch64__
static std::atomic<int> g_aq_done{0};   // incremented by CoreAudio's thread: the callback touches nothing of the C library
static void aq_callback(void *, void *, void *) { g_aq_done.fetch_add(1, std::memory_order_release); }
struct AudioQueueBackend : Backend {   // macOS: AudioToolbox's AudioQueue, three buffers in flight
    void *at = nullptr, *q = nullptr; void *bufs[3] = {}; int enq = 0; int period = 0;
    int (*p_new)(const void *, void *, void *, void *, void *, unsigned, void **) = nullptr; int (*p_alloc)(void *, unsigned, void **) = nullptr; int (*p_enq)(void *, void *, unsigned, const void *) = nullptr;
    int (*p_start)(void *, const void *) = nullptr; int (*p_stop)(void *, signed char) = nullptr; int (*p_dispose)(void *, signed char) = nullptr;
    const char *name() const override { return "audioqueue"; }
    bool open(int period_frames, std::string &note) override {
        if (!IsXnu()) { note = "not macOS"; return false; }
        at = cosmo_dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW); if (!at) { note = "AudioToolbox not available"; return false; }
        p_new = (decltype(p_new))sym(at, "AudioQueueNewOutput"); p_alloc = (decltype(p_alloc))sym(at, "AudioQueueAllocateBuffer"); p_enq = (decltype(p_enq))sym(at, "AudioQueueEnqueueBuffer");
        p_start = (decltype(p_start))sym(at, "AudioQueueStart"); p_stop = (decltype(p_stop))sym(at, "AudioQueueStop"); p_dispose = (decltype(p_dispose))sym(at, "AudioQueueDispose");
        if (!p_new || !p_alloc || !p_enq || !p_start || !p_stop) { note = "AudioToolbox entry points missing"; return false; }
        struct { double rate; unsigned fid, flags, bpp, fpp, bpf, ch, bits, res; } asbd = {48000.0, 0x6c70636d /*lpcm*/, 12 /*signed int, packed*/, 4, 1, 4, 2, 16, 0};
        int st = p_new(&asbd, (void *)aq_callback, nullptr, nullptr, nullptr, 0, &q); if (st) { note = "AudioQueueNewOutput status " + std::to_string(st); return false; }
        period = period_frames; g_aq_done = 3;   // all three buffers are free at the start
        for (int i = 0; i < 3; i++) { st = p_alloc(q, (unsigned)period * 4, &bufs[i]); if (st || !bufs[i]) { note = "AudioQueueAllocateBuffer status " + std::to_string(st); return false; } }
        started = false; note = "AudioQueue, 48000 Hz stereo S16, 3 buffers of " + std::to_string(period) + " frames"; return true;
    }
    bool started = false; int used = 0;
    bool write(const int16_t *f, int n) override {
        while (g_aq_done.load(std::memory_order_acquire) == 0) msleep_ns(500000);   // wait for a free buffer (0.5 ms polls)
        g_aq_done.fetch_sub(1, std::memory_order_acq_rel);
        void *b = bufs[enq % 3]; enq++; memcpy(*(void **)((char *)b + 8), f, (size_t)n * 4); *(unsigned *)((char *)b + 16) = (unsigned)n * 4;
        int st = p_enq(q, b, 0, nullptr); if (st) return false;
        if (!started && enq >= 2) { if (p_start(q, nullptr)) return false; started = true; }   // start once two buffers are queued
        return true;
    }
    void close() override { if (q) { if (!started) p_start(q, nullptr); p_stop(q, 0); if (p_dispose) p_dispose(q, 1); q = nullptr; } }
};
#endif

#if defined(__x86_64__)
#define AMS __attribute__((ms_abi))
struct WaveOutBackend : Backend {   // Windows: winmm waveOut, four headers in flight
    void *mm = nullptr, *wo = nullptr; int period = 0; int next = 0; std::vector<int16_t> pcm[4];
    struct Hdr { char *data; unsigned len, rec; uintptr_t user; unsigned flags, loops; void *nxt; uintptr_t res; } hdr[4];
    unsigned (AMS *p_open)(void **, unsigned, const void *, uintptr_t, uintptr_t, unsigned) = nullptr; unsigned (AMS *p_prep)(void *, void *, unsigned) = nullptr; unsigned (AMS *p_write)(void *, void *, unsigned) = nullptr;
    unsigned (AMS *p_unprep)(void *, void *, unsigned) = nullptr; unsigned (AMS *p_reset)(void *) = nullptr; unsigned (AMS *p_close)(void *) = nullptr; unsigned (AMS *p_count)(void) = nullptr;
    const char *name() const override { return "waveout"; }
    bool open(int period_frames, std::string &note) override {
        if (!IsWindows()) { note = "not Windows"; return false; }
        mm = cosmo_dlopen("winmm.dll", RTLD_NOW); if (!mm) { note = "winmm.dll not available"; return false; }
        p_open = (decltype(p_open))cosmo_dlsym(mm, "waveOutOpen"); p_prep = (decltype(p_prep))cosmo_dlsym(mm, "waveOutPrepareHeader"); p_write = (decltype(p_write))cosmo_dlsym(mm, "waveOutWrite");
        p_unprep = (decltype(p_unprep))cosmo_dlsym(mm, "waveOutUnprepareHeader"); p_reset = (decltype(p_reset))cosmo_dlsym(mm, "waveOutReset"); p_close = (decltype(p_close))cosmo_dlsym(mm, "waveOutClose"); p_count = (decltype(p_count))cosmo_dlsym(mm, "waveOutGetNumDevs");
        if (!p_open || !p_prep || !p_write || !p_close) { note = "winmm entry points missing"; return false; }
        unsigned devs = p_count ? p_count() : 0; struct { unsigned short tag, ch; unsigned rate, avg; unsigned short align, bits, cb; } __attribute__((packed)) fmt = {1, 2, 48000, 192000, 4, 16, 0};
        unsigned rc = p_open(&wo, 0xFFFFFFFFu /*WAVE_MAPPER*/, &fmt, 0, 0, 0); if (rc) { note = "waveOutOpen failed: " + std::to_string(rc) + " (" + std::to_string(devs) + " output devices)"; return false; }
        period = period_frames; for (int i = 0; i < 4; i++) { pcm[i].assign((size_t)period * 2, 0); memset(&hdr[i], 0, sizeof hdr[i]); hdr[i].data = (char *)pcm[i].data(); hdr[i].len = (unsigned)period * 4; if (p_prep(wo, &hdr[i], sizeof hdr[i])) { note = "waveOutPrepareHeader failed"; return false; } hdr[i].flags |= 1; /*WHDR_DONE: free*/ }
        note = "waveOut, 48000 Hz stereo S16, 4 buffers of " + std::to_string(period) + " frames, " + std::to_string(devs) + " output device(s)"; return true;
    }
    bool write(const int16_t *f, int n) override {
        Hdr &h = hdr[next]; while (!(((volatile unsigned &)h.flags) & 1)) msleep_ns(500000);   // WHDR_DONE: the device finished with this buffer
        memcpy(pcm[next].data(), f, (size_t)n * 4); h.len = (unsigned)n * 4; if (p_write(wo, &h, sizeof h)) return false; next = (next + 1) & 3; return true;
    }
    void close() override { if (wo) { if (p_reset) p_reset(wo); for (int i = 0; i < 4; i++) if (p_unprep) p_unprep(wo, &hdr[i], sizeof hdr[i]); p_close(wo); wo = nullptr; } }
};
#endif

// ------------------------------------------------------------------------------------------------ the output
struct Stats {
    uint64_t produced = 0, dropped = 0, played = 0, silence = 0, underruns = 0, periods = 0, device_xruns = 0, in_hash = 0, out_hash = 0; uint64_t fill_min = ~0ull, fill_max = 0; double fill_sum = 0; std::string backend, note; bool opened = false;
};

class Output {
public:
    Ring ring; Stats st; int period = 480;   // 10 ms
    // returns false only when a device was required and could not be opened
    bool start(const char *mode_in = nullptr, int period_frames = 480) {
        const char *mode = mode_in ? mode_in : getenv("GAME_AUDIO"); if (!mode || !*mode) mode = "timed"; period = period_frames; mode_ = mode;
        if (!strcmp(mode, "off")) { st.backend = "off"; return true; }
        std::string note;
        if (!strcmp(mode, "device")) {
#ifdef _WIN32
#elif defined(__x86_64__)
            if (IsWindows()) be_ = new WaveOutBackend();
#endif
#ifdef __aarch64__
            if (!be_ && IsXnu()) be_ = new AudioQueueBackend();
#endif
#ifndef _WIN32
            if (!be_) { const char *dev = getenv("GAME_AUDIO_DEV"); bool want_alsa = dev && *dev && strcmp(dev, "pulse") != 0; if (want_alsa) be_ = new AlsaBackend(); else be_ = new PulseBackend(); }
#endif
        } else be_ = new TimedBackend();
        if (!be_) { st.backend = "none"; st.note = "no device backend on this platform"; return !require(); }
        st.backend = be_->name(); ring.init(16384);
        // open, write and close all happen on the audio thread: a device library with locks (libpulse behind ALSA's pulse plugin) must see one thread, and that thread's thread block, for the lifetime of the device
        auto start_thread = [&] { opened_ = 0; run_ = true; th_ = std::thread([this] { open_loop(); }); for (int i = 0; i < 10000 && opened_.load() == 0; i++) msleep_ns(1000000); return opened_.load() == 1; };
        if (!start_thread()) {
            run_ = false; if (th_.joinable()) th_.join(); st.note = open_note_; delete be_; be_ = nullptr;
#ifndef _WIN32
            if (!strcmp(mode, "device") && !IsWindows() && !IsXnu() && st.backend == "pulse" && !getenv("GAME_AUDIO_DEV")) {   // no sound server: the kernel's ALSA devices through libasound
                be_ = new AlsaBackend(); std::string why = st.note; st.backend = "alsa"; if (start_thread()) { st.note = open_note_ + " (the sound server was not available: " + why + ")"; st.opened = true; return true; }
                run_ = false; if (th_.joinable()) th_.join(); st.note = why + "; " + open_note_; delete be_; be_ = nullptr;
            }
#endif
            if (require()) return false;
            be_ = new TimedBackend(); st.backend = "timed (fallback: no device)"; std::string n2; st.note += "; using the software clock instead"; if (!start_thread()) return false;
        } else st.note = open_note_;
        st.opened = true; return true;
    }
    // game thread: never blocks; frames that do not fit are dropped and counted
    void submit(const int16_t *s, uint64_t frames) {
        if (!be_) return;
        st.in_hash = fnv(st.in_hash ? st.in_hash : 14695981039346656037ull, s, frames); st.produced += frames; uint64_t n = ring.push(s, frames);
        if (n < frames) { st.dropped += frames - n; /* the hash covers what was produced, the dropped frames break the equality on purpose */ }
    }
    // after the last submit: let the consumer play what is left, then stop
    void finish() {
        if (!be_) return; auto t = std::chrono::steady_clock::now();
        while (ring.fill() > 0 && std::chrono::steady_clock::now() - t < std::chrono::seconds(10)) msleep_ns(1000000);
        draining_ = true; run_ = false; if (th_.joinable()) th_.join(); delete be_; be_ = nullptr;
    }
    bool integrity() const { return st.dropped == 0 && st.played == st.produced && (st.in_hash == st.out_hash); }
    void report(const char *prefix = "host") const {
        printf("%s : audio out [%s]: %s\n", prefix, st.backend.c_str(), st.note.c_str());
        printf("%s : audio out: produced %llu frames, played %llu, dropped by a full ring %llu, silence inserted %llu frames in %llu under-run(s) over %llu periods, device-reported xruns %llu, ring fill min/mean/max %llu/%.0f/%llu frames, stream integrity %s\n", prefix,
            (unsigned long long)st.produced, (unsigned long long)st.played, (unsigned long long)st.dropped, (unsigned long long)st.silence, (unsigned long long)st.underruns, (unsigned long long)st.periods,
            (unsigned long long)st.device_xruns, (unsigned long long)(st.fill_min == ~0ull ? 0 : st.fill_min), st.periods ? st.fill_sum / st.periods : 0.0, (unsigned long long)st.fill_max, integrity() ? "ok (same frames, same order)" : "BROKEN");
    }
    static bool require() { const char *r = getenv("GAME_AUDIO_REQUIRE"); return r && *r == '1'; }
private:
    Backend *be_ = nullptr; std::thread th_; std::atomic<bool> run_{false}, draining_{false}; std::string mode_;
    std::atomic<int> opened_{0}; std::string open_note_;
    void open_loop() {
        std::string note; bool ok = be_->open(period, note); if (ok) be_->prime(); open_note_ = note; opened_.store(ok ? 1 : 2); if (!ok) return;
        loop(); be_->close(); st.device_xruns = be_->device_xruns;
    }
    void loop() {
        std::vector<int16_t> tmp((size_t)period * kChannels);
        // prefill: three periods (30 ms) before the first one is handed to the device, so that the game thread's jitter is absorbed; gives up after 250 ms (a producer that is not running yet)
        auto t0 = std::chrono::steady_clock::now(); while (ring.fill() < (uint64_t)period * 3 && std::chrono::steady_clock::now() - t0 < std::chrono::milliseconds(250)) msleep_ns(500000);
        bool producing = true;
        while (run_.load() || ring.fill() > 0) {
            if (ring.fill() < (uint64_t)period && run_.load() && !draining_.load()) {   // a device with buffer to spare lets the consumer run ahead of the producer: wait up to one period (10 ms) for data before putting silence into the stream
                auto tw = std::chrono::steady_clock::now(); while (ring.fill() < (uint64_t)period && std::chrono::steady_clock::now() - tw < std::chrono::microseconds((long long)period * 1000000 / kRate)) msleep_ns(300000); }
            uint64_t fill = ring.fill(); uint64_t n = ring.pop(tmp.data(), (uint64_t)period);
            st.fill_sum += (double)fill; st.fill_min = std::min<uint64_t>(st.fill_min, fill); st.fill_max = std::max<uint64_t>(st.fill_max, fill); st.periods++;
            st.out_hash = fnv(st.out_hash ? st.out_hash : 14695981039346656037ull, tmp.data(), n); st.played += n;
            if (n < (uint64_t)period) { memset(tmp.data() + n * kChannels, 0, ((uint64_t)period - n) * kChannels * sizeof(int16_t)); if (run_.load() && !draining_.load()) { st.underruns++; st.silence += (uint64_t)period - n; } }
            if (!be_->write(tmp.data(), period)) { st.note += " [device write failed]"; break; }
            (void)producing;
        }
    }
};

}   // namespace audio
