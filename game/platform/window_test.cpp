// Window back end test: opens a window, presents a known pattern, reads it back (verify), then collects input for N seconds.
//   window_test [--seconds=N] [--expect=keys]   (--expect=keys: a test harness types 'a', Right, space and moves the pointer to (50,60); all four must arrive)
#include "window.h"
#include <chrono>
int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0); ShowCrashReports(); double secs = 3; bool keys = false;
    for (int i = 1; i < argc; i++) { if (!strncmp(argv[i], "--seconds=", 10)) secs = atof(argv[i] + 10); else if (!strcmp(argv[i], "--expect=keys")) keys = true; }
    printf("window_test: platform=%s arch=%s\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", IsAarch64() ? "aarch64" : "x86_64");
    win::Window w; const int W = 256, H = 256; if (!w.open(W, H, "celori window test")) { printf("window_test: cannot open (%s): %s\nRESULT FAIL window\n", w.backend.c_str(), w.note.c_str()); return 2; }
    printf("window_test: %s: %s\n", w.backend.c_str(), w.note.c_str());
    std::vector<uint8_t> fr((size_t)W * H * 4);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { uint8_t *p = &fr[((size_t)y * W + x) * 4]; p[0] = (uint8_t)x; p[1] = (uint8_t)y; p[2] = (uint8_t)((x ^ y) & 255); p[3] = 255; if (x >= 100 && x < 140 && y >= 60 && y < 100) { p[0] = 255; p[1] = 0; p[2] = 0; } }
    auto t0 = std::chrono::steady_clock::now(); bool ok = true; int frames = 0;
    for (int i = 0; i < 20; i++) { ok = w.present(fr.data(), W, H) && ok; frames++; }
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    printf("window_test: presented %d frames of %dx%d in %.2f ms (%.3f ms each, includes the transfer to the display)\n", frames, W, H, ms, ms / frames);
    win::wsleep_ms(300); std::vector<win::Event> ev; w.poll(ev);   // Expose etc.
    int mismatch = -2; bool rb = w.verify(fr.data(), W, H, mismatch);
    printf("window_test: read-back of the window: %s, %d of %d pixels differ\n", rb ? "ok" : "not possible", mismatch, W * H);
    if (keys) { std::string how = w.inject(); if (!how.empty()) printf("window_test: input from inside the program: %s\n", how.c_str()); }
    bool k_left = false, k_right = false, k_fire = false, mouse = false; auto ts = std::chrono::steady_clock::now();
    while (std::chrono::duration<double>(std::chrono::steady_clock::now() - ts).count() < secs) { ev.clear(); w.poll(ev);
        for (auto &e : ev) { if (e.type == win::EV_KEY_DOWN) { printf("window_test: key down %d\n", e.a); if (e.a == 1) k_left = true; if (e.a == 2) k_right = true; if (e.a == 5) k_fire = true; }
            else if (e.type == win::EV_KEY_UP) printf("window_test: key up %d\n", e.a); else if (e.type == win::EV_MOUSE) { if (e.a == 50 && e.b == 60) { mouse = true; printf("window_test: mouse at (50,60)\n"); } } else if (e.type == win::EV_CLOSE) printf("window_test: close requested\n"); }
        win::wsleep_ms(5); }
    w.close();
    bool pix_ok = rb && mismatch == 0;
    if (!pix_ok && !(rb == false)) ok = false;
    bool input_ok = !keys || (k_left && k_right && k_fire && mouse);
    printf("RESULT %s window present=%s readback=%s input=%s\n", (ok && (pix_ok || !rb) && input_ok) ? (rb ? "PASS" : "PRESENT-ONLY") : "FAIL", ok ? "ok" : "failed", rb ? (mismatch == 0 ? "exact" : "differs") : "not-possible", keys ? (input_ok ? "ok" : "missing") : "not-tested");
    return (ok && (pix_ok || !rb) && input_ok) ? 0 : 1;
}
