// Windowing, input and audio from a Cosmopolitan program, per OS, with nothing but the operating system's own libraries reached at run time (no Dawn here).
//   Windows: user32 + winmm through ms_abi function pointers (window class, window, message loop, posted and injected input, waveOut)
//   Linux:   libX11 + libXtst (window, events, synthetic input) and libasound (PCM) through cosmo_dlopen, calls through cosmo_dltramp
//   macOS:   the Objective-C runtime and AppKit (NSApplication, NSWindow, synthetic NSEvents) and AudioToolbox (AudioQueue), through cosmo_dlopen
// Prints "PROBE <area>: <result>" lines and a final RESULT line. Window and input are required to work; audio is reported (the CI machines may have no sound device).
#define _COSMO_SOURCE 1
#include <cosmo.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int g_window = 0, g_key = 0, g_mouse = 0, g_audio = -99; static int g_mx = -1, g_my = -1; static char g_audio_note[160] = "";
static void *sym(void *h, const char *n) { void *p = cosmo_dlsym(h, n); return p ? cosmo_dltramp(p) : NULL; }
static void tone(int16_t *b, int frames) { for (int i = 0; i < frames; i++) { int16_t v = (int16_t)(8000 * sinf(6.2831853f * 440.0f * i / 48000.0f)); b[2 * i] = v; b[2 * i + 1] = v; } }
static void msleep(int ms) { struct timespec t = {ms / 1000, (ms % 1000) * 1000000}; nanosleep(&t, NULL); }

// ======================================================================== Windows
#ifdef __x86_64__
#define MS __attribute__((ms_abi))
typedef intptr_t (MS *WndProc)(void *, unsigned, uintptr_t, intptr_t);
struct WndClassExW { unsigned cbSize, style; WndProc proc; int cls_extra, wnd_extra; void *inst, *icon, *cursor, *brush; const uint16_t *menu, *name; void *icon_sm; };
static MS intptr_t wndproc(void *h, unsigned m, uintptr_t w, intptr_t l) {
    if (m == 0x100) { g_key = (int)w; }                                    // WM_KEYDOWN
    else if (m == 0x200) { g_mouse = 1; g_mx = (int)(l & 0xFFFF); g_my = (int)((l >> 16) & 0xFFFF); }   // WM_MOUSEMOVE
    typedef intptr_t (MS *Def)(void *, unsigned, uintptr_t, intptr_t); static Def def; if (!def) { void *u = cosmo_dlopen("user32.dll", RTLD_NOW); def = (Def)cosmo_dlsym(u, "DefWindowProcW"); }
    return def(h, m, w, l);
}
static void probe_windows(void) {
    void *k = cosmo_dlopen("kernel32.dll", RTLD_NOW), *u = cosmo_dlopen("user32.dll", RTLD_NOW), *mm = cosmo_dlopen("winmm.dll", RTLD_NOW);
    if (!k || !u) { puts("PROBE window: user32 not available"); return; }
    typedef void *(MS *GetMod)(const uint16_t *); typedef unsigned short (MS *RegCls)(const struct WndClassExW *);
    typedef void *(MS *CreateWin)(unsigned, const uint16_t *, const uint16_t *, unsigned, int, int, int, int, void *, void *, void *, void *);
    typedef int (MS *Show)(void *, int); typedef int (MS *Post)(void *, unsigned, uintptr_t, intptr_t); typedef int (MS *Peek)(void *, void *, unsigned, unsigned, unsigned); typedef intptr_t (MS *Disp)(const void *);
    typedef int (MS *SetFg)(void *); typedef unsigned (MS *SendIn)(unsigned, const void *, int); typedef int (MS *DestroyW)(void *);
    GetMod getmod = (GetMod)cosmo_dlsym(k, "GetModuleHandleW"); RegCls reg = (RegCls)cosmo_dlsym(u, "RegisterClassExW"); CreateWin create = (CreateWin)cosmo_dlsym(u, "CreateWindowExW");
    Show show = (Show)cosmo_dlsym(u, "ShowWindow"); Post post = (Post)cosmo_dlsym(u, "PostMessageW"); Peek peek = (Peek)cosmo_dlsym(u, "PeekMessageW"); Disp disp = (Disp)cosmo_dlsym(u, "DispatchMessageW");
    SetFg setfg = (SetFg)cosmo_dlsym(u, "SetForegroundWindow"); SendIn sendin = (SendIn)cosmo_dlsym(u, "SendInput"); DestroyW destroy = (DestroyW)cosmo_dlsym(u, "DestroyWindow");
    static const uint16_t cls[] = {'C', 'e', 'l', 'o', 'r', 'i', 'P', 'r', 'o', 'b', 'e', 0}, title[] = {'p', 'r', 'o', 'b', 'e', 0};
    void *inst = getmod(NULL); struct WndClassExW wc; memset(&wc, 0, sizeof wc); wc.cbSize = sizeof wc; wc.proc = wndproc; wc.inst = inst; wc.name = cls;
    if (!reg(&wc)) { puts("PROBE window: RegisterClassExW failed"); return; }
    void *hw = create(0, cls, title, 0x00CF0000u, 100, 100, 320, 240, NULL, NULL, inst, NULL);
    if (!hw) { puts("PROBE window: CreateWindowExW failed"); return; }
    show(hw, 5); g_window = 1; setfg(hw);
    uint8_t msg[64];
    auto_pump: ;
    #define PUMP() do { for (int n = 0; n < 200 && peek(msg, NULL, 0, 0, 1); n++) disp(msg); } while (0)
    post(hw, 0x100, 'A', 0); post(hw, 0x200, 0, (50 & 0xFFFF) | (60 << 16)); msleep(20); PUMP();
    printf("PROBE input: posted key 'A' -> %d, posted mouse (50,60) -> (%d,%d)\n", g_key, g_mx, g_my);
    int posted_key = g_key; g_key = 0;
    if (sendin) {   // injected through the system input queue: arrives only if the window is the foreground window of an interactive desktop
        uint8_t in[40]; memset(in, 0, sizeof in); *(unsigned *)in = 1; *(unsigned short *)(in + 8) = 'B'; unsigned n = sendin(1, in, 40); *(unsigned *)(in + 12) = 2; sendin(1, in, 40); msleep(50); PUMP();
        printf("PROBE input: SendInput accepted %u event(s); WM_KEYDOWN seen: %d\n", n, g_key);
    }
    g_key = posted_key;
    // audio: winmm waveOut
    if (mm) {
        typedef unsigned (MS *WOOpen)(void **, unsigned, const void *, uintptr_t, uintptr_t, unsigned); typedef unsigned (MS *WOPrep)(void *, void *, unsigned); typedef unsigned (MS *WOWrite)(void *, void *, unsigned); typedef unsigned (MS *WOClose)(void *);
        WOOpen open = (WOOpen)cosmo_dlsym(mm, "waveOutOpen"); WOPrep prep = (WOPrep)cosmo_dlsym(mm, "waveOutPrepareHeader"); WOWrite wr = (WOWrite)cosmo_dlsym(mm, "waveOutWrite"); WOClose cl = (WOClose)cosmo_dlsym(mm, "waveOutClose");
        typedef unsigned (MS *WOCount)(void); WOCount cnt = (WOCount)cosmo_dlsym(mm, "waveOutGetNumDevs");
        struct { unsigned short tag, ch; unsigned rate, avg; unsigned short align, bits, cb; } __attribute__((packed)) fmt = {1, 2, 48000, 192000, 4, 16, 0};
        static int16_t pcm[4800 * 2]; tone(pcm, 4800); void *wo = NULL; unsigned devs = cnt ? cnt() : 0, rc = open(&wo, 0xFFFFFFFFu, &fmt, 0, 0, 0);
        snprintf(g_audio_note, sizeof g_audio_note, "waveOut devices %u, open rc %u", devs, rc);
        if (rc == 0) { struct { char *data; unsigned len, rec; uintptr_t user; unsigned flags, loops; void *next; uintptr_t res; } hdr; memset(&hdr, 0, sizeof hdr); hdr.data = (char *)pcm; hdr.len = sizeof pcm;
            unsigned a = prep(wo, &hdr, sizeof hdr), b = wr(wo, &hdr, sizeof hdr); g_audio = (a == 0 && b == 0) ? 0 : -1; msleep(150); cl(wo); }
        else g_audio = -2;
    }
    destroy(hw);
}
#else
static void probe_windows(void) {}
#endif

// ======================================================================== Linux
static void probe_linux(void) {
    void *x = cosmo_dlopen("libX11.so.6", RTLD_NOW), *xt = cosmo_dlopen("libXtst.so.6", RTLD_NOW), *as = cosmo_dlopen("libasound.so.2", RTLD_NOW);
    if (!x) { puts("PROBE window: libX11 not available"); }
    else {
        void *(*XOpenDisplay)(const char *) = sym(x, "XOpenDisplay"); int (*XDefaultScreen)(void *) = sym(x, "XDefaultScreen"); unsigned long (*XRootWindow)(void *, int) = sym(x, "XRootWindow");
        unsigned long (*XCreateSimpleWindow)(void *, unsigned long, int, int, unsigned, unsigned, unsigned, unsigned long, unsigned long) = sym(x, "XCreateSimpleWindow");
        int (*XSelectInput)(void *, unsigned long, long) = sym(x, "XSelectInput"); int (*XMapWindow)(void *, unsigned long) = sym(x, "XMapWindow"); int (*XFlush)(void *) = sym(x, "XFlush");
        int (*XPending)(void *) = sym(x, "XPending"); int (*XNextEvent)(void *, void *) = sym(x, "XNextEvent"); unsigned long (*XStringToKeysym)(const char *) = sym(x, "XStringToKeysym");
        unsigned char (*XKeysymToKeycode)(void *, unsigned long) = sym(x, "XKeysymToKeycode"); int (*XSync)(void *, int) = sym(x, "XSync");
        void *d = XOpenDisplay ? XOpenDisplay(NULL) : NULL;
        if (!d) puts("PROBE window: XOpenDisplay failed (no X server; DISPLAY unset?)");
        else {
            int scr = XDefaultScreen(d); unsigned long root = XRootWindow(d, scr), w = XCreateSimpleWindow(d, root, 0, 0, 320, 240, 0, 0, 0x203040);
            XSelectInput(d, w, (1L << 0) | (1L << 6) | (1L << 2));   // KeyPress, PointerMotion, KeyRelease
            XMapWindow(d, w); XSync(d, 0); g_window = 1;
            if (xt) {
                int (*FakeMotion)(void *, int, int, int, unsigned long) = sym(xt, "XTestFakeMotionEvent"); int (*FakeKey)(void *, unsigned, int, unsigned long) = sym(xt, "XTestFakeKeyEvent");
                FakeMotion(d, scr, 50, 60, 0); XSync(d, 0); msleep(30); unsigned kc = XKeysymToKeycode(d, XStringToKeysym("a")); FakeKey(d, kc, 1, 0); FakeKey(d, kc, 0, 0); XSync(d, 0); msleep(30);
                for (int n = 0; n < 50 && XPending(d); n++) { uint8_t ev[192]; XNextEvent(d, ev); int type = *(int *)ev;
                    if (type == 2) g_key = (int)*(unsigned *)(ev + 84); else if (type == 6) { g_mouse = 1; g_mx = *(int *)(ev + 64); g_my = *(int *)(ev + 68); } }
                printf("PROBE input: XTest key 'a' (keycode %u) -> keycode seen %d, pointer motion -> (%d,%d)\n", kc, g_key, g_mx, g_my); if (g_key == (int)kc) g_key = 'a';
            } else puts("PROBE input: libXtst not available");
        }
    }
    if (!as) { snprintf(g_audio_note, sizeof g_audio_note, "libasound not available"); return; }
    int (*snd_pcm_open)(void **, const char *, int, int) = sym(as, "snd_pcm_open"); int (*set_params)(void *, int, int, unsigned, unsigned, int, unsigned) = sym(as, "snd_pcm_set_params");
    long (*writei)(void *, const void *, unsigned long) = sym(as, "snd_pcm_writei"); int (*drain)(void *) = sym(as, "snd_pcm_drain"); int (*pclose)(void *) = sym(as, "snd_pcm_close");
    static int16_t pcm[4800 * 2]; tone(pcm, 4800); const char *names[] = {"default", "null"};
    for (int i = 0; i < 2; i++) {
        void *pcmh = NULL; int rc = snd_pcm_open(&pcmh, names[i], 0, 0);
        if (rc < 0) { snprintf(g_audio_note + strlen(g_audio_note), sizeof g_audio_note - strlen(g_audio_note), "%s: open %d; ", names[i], rc); continue; }
        rc = set_params(pcmh, 2 /*S16_LE*/, 3 /*RW_INTERLEAVED*/, 2, 48000, 1, 500000); long n = rc < 0 ? rc : writei(pcmh, pcm, 4800); drain(pcmh); pclose(pcmh);
        snprintf(g_audio_note + strlen(g_audio_note), sizeof g_audio_note - strlen(g_audio_note), "%s: set_params %d, wrote %ld frames", names[i], rc, n); g_audio = n == 4800 ? 0 : -1; if (g_audio == 0) break;
    }
}

// ======================================================================== macOS
typedef void *id; typedef void *SEL; typedef struct { double x, y; } Pt; typedef struct { double x, y, w, h; } Rc;
static void aq_cb(void *u, void *q, void *b) { (void)u; (void)q; (void)b; }
static void probe_macos(void) {
    void *rt = cosmo_dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW); void *ak = cosmo_dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW);
    if (!rt || !ak) { puts("PROBE window: Objective-C runtime or AppKit not available"); return; }
    SEL (*selreg)(const char *) = sym(rt, "sel_registerName"); id (*getclass)(const char *) = sym(rt, "objc_getClass"); void *msg = cosmo_dlsym(rt, "objc_msgSend"); if (msg) msg = cosmo_dltramp(msg);
    if (!selreg || !getclass || !msg) { puts("PROBE window: objc entry points missing"); return; }
#define S(n) selreg(n)
#define M0(R, o, n) ((R (*)(id, SEL))msg)(o, S(n))
    id NSApp = getclass("NSApplication"), NSWindow = getclass("NSWindow"), NSEvent = getclass("NSEvent"), NSString = getclass("NSString");
    id app = M0(id, NSApp, "sharedApplication"); ((long (*)(id, SEL, long))msg)(app, S("setActivationPolicy:"), 0);
    id win = ((id (*)(id, SEL))msg)(NSWindow, S("alloc")); Rc rc = {100, 100, 320, 240};
    win = ((id (*)(id, SEL, Rc, unsigned long, unsigned long, signed char))msg)(win, S("initWithContentRect:styleMask:backing:defer:"), rc, 15, 2, 0);
    if (!win) { puts("PROBE window: NSWindow creation failed"); return; }
    ((void (*)(id, SEL, id))msg)(win, S("makeKeyAndOrderFront:"), NULL); M0(void, app, "finishLaunching"); g_window = 1;
    long winno = M0(long, win, "windowNumber");
    id chars = ((id (*)(id, SEL, const char *))msg)(NSString, S("stringWithUTF8String:"), "a"), mode = ((id (*)(id, SEL, const char *))msg)(NSString, S("stringWithUTF8String:"), "kCFRunLoopDefaultMode");
    Pt loc = {50, 60};
    id kev = ((id (*)(id, SEL, unsigned long, Pt, unsigned long, double, long, id, id, id, signed char, unsigned short))msg)(NSEvent, S("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"), 10, loc, 0, 0.0, winno, NULL, chars, chars, 0, 0);
    id mev = ((id (*)(id, SEL, unsigned long, Pt, unsigned long, double, long, id, long, long, float))msg)(NSEvent, S("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"), 5, loc, 0, 0.0, winno, NULL, 0, 0, 0.0f);
    ((void (*)(id, SEL, id, signed char))msg)(app, S("postEvent:atStart:"), kev, 0); ((void (*)(id, SEL, id, signed char))msg)(app, S("postEvent:atStart:"), mev, 0);
    for (int n = 0; n < 20; n++) {
        id ev = ((id (*)(id, SEL, unsigned long, id, id, signed char))msg)(app, S("nextEventMatchingMask:untilDate:inMode:dequeue:"), ~0ul, NULL, mode, 1); if (!ev) break;
        unsigned long type = ((unsigned long (*)(id, SEL))msg)(ev, S("type")); if (type == 10) g_key = 'a'; else if (type == 5) { Pt p = ((Pt (*)(id, SEL))msg)(ev, S("locationInWindow")); g_mouse = 1; g_mx = (int)p.x; g_my = (int)p.y; }
    }
    printf("PROBE input: synthetic NSEvents -> key %d, mouse (%d,%d)\n", g_key, g_mx, g_my);
    void *at = cosmo_dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
    if (!at) { snprintf(g_audio_note, sizeof g_audio_note, "AudioToolbox not available"); return; }
    int (*newout)(const void *, void *, void *, void *, void *, unsigned, void **) = sym(at, "AudioQueueNewOutput"); int (*alloc)(void *, unsigned, void **) = sym(at, "AudioQueueAllocateBuffer");
    int (*enq)(void *, void *, unsigned, const void *) = sym(at, "AudioQueueEnqueueBuffer"); int (*start)(void *, const void *) = sym(at, "AudioQueueStart"); int (*stop)(void *, signed char) = sym(at, "AudioQueueStop");
    struct { double rate; unsigned fid, flags, bpp, fpp, bpf, ch, bits, res; } asbd = {48000.0, 0x6c70636d, 12, 4, 1, 4, 2, 16, 0};
    void *q = NULL; int st = newout(&asbd, (void *)aq_cb, NULL, NULL, NULL, 0, &q);
    if (st) { snprintf(g_audio_note, sizeof g_audio_note, "AudioQueueNewOutput status %d", st); g_audio = -2; return; }
    void *buf = NULL; st = alloc(q, 19200, &buf); if (st || !buf) { snprintf(g_audio_note, sizeof g_audio_note, "AudioQueueAllocateBuffer status %d", st); g_audio = -2; return; }
    static int16_t pcm[4800 * 2]; tone(pcm, 4800); memcpy(*(void **)((char *)buf + 8), pcm, sizeof pcm); *(unsigned *)((char *)buf + 16) = sizeof pcm;
    int s1 = enq(q, buf, 0, NULL), s2 = start(q, NULL); msleep(150); stop(q, 1);
    snprintf(g_audio_note, sizeof g_audio_note, "AudioQueue enqueue %d, start %d", s1, s2); g_audio = (s1 == 0 && s2 == 0) ? 0 : -1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); ShowCrashReports();
    printf("PROBE platform: %s %s\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", IsAarch64() ? "aarch64" : "x86_64");
    if (IsWindows()) probe_windows(); else if (IsXnu()) probe_macos(); else probe_linux();
    int input_ok = g_key != 0 && g_mouse;
    printf("PROBE window: %s\nPROBE audio: %s (%s)\n", g_window ? "created" : "NOT created", g_audio == 0 ? "played a tone" : "not played", g_audio_note);
    printf("RESULT %s window=%s input=%s audio=%s\n", g_window && input_ok ? "PASS" : "FAIL", g_window ? "ok" : "no", input_ok ? "ok" : "no", g_audio == 0 ? "ok" : "no-device-or-failed");
    return g_window && input_ok ? 0 : 1;
}
