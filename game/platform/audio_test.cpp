// The audio ring and its backends, driven the way the game drives them: 800 stereo frames every 1/60 s from the game thread.
//   audio_test [--mode=timed|device] [--frames=N] [--stall]      env: GAME_AUDIO_REQUIRE=1 makes a missing device a failure
// Normal run: every produced frame must come out, in order (integrity). --stall: the producer stops for 200 ms at frame 60; the accounting must see the under-run (silence inserted), which also shows that the counters work.
#include "audio_out.h"
#include <cmath>
using Clock = std::chrono::steady_clock;
int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0); ShowCrashReports();
    const char *mode = "timed"; int frames = 180; bool stall = false;
    for (int i = 1; i < argc; i++) { if (!strncmp(argv[i], "--mode=", 7)) mode = argv[i] + 7; else if (!strncmp(argv[i], "--frames=", 9)) frames = atoi(argv[i] + 9); else if (!strcmp(argv[i], "--stall")) stall = true; }
    printf("audio_test: platform=%s arch=%s mode=%s frames=%d stall=%d\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", IsAarch64() ? "aarch64" : "x86_64", mode, frames, (int)stall);
    audio::Output out; if (!out.start(mode)) { out.report("audio_test"); puts("RESULT FAIL audio device required but not available"); return 2; }
    printf("audio_test: backend %s: %s\n", out.st.backend.c_str(), out.st.note.c_str());
    const int spf = 800; std::vector<int16_t> blk((size_t)spf * 2); uint64_t n = 0; double maxlate = 0; int late = 0;
    auto t0 = Clock::now();
    for (int f = 0; f < frames; f++) {
        auto due = t0 + std::chrono::nanoseconds((long long)f * 1000000000LL / 60); std::this_thread::sleep_until(due - std::chrono::microseconds(300)); while (Clock::now() < due) {}   // the last 0.3 ms by spinning
        double l = std::chrono::duration<double, std::milli>(Clock::now() - due).count(); if (l > maxlate) maxlate = l; if (l > 1.0) late++;
        if (stall && f == 60) std::this_thread::sleep_for(std::chrono::milliseconds(200));
        for (int i = 0; i < spf; i++, n++) { int16_t v = (int16_t)(9000 * std::sin(6.2831853 * 440.0 * (double)n / 48000.0)); blk[2 * i] = v; blk[2 * i + 1] = (int16_t)(v / 2 + (int16_t)(n & 0xff)); }
        out.submit(blk.data(), spf);
    }
    out.finish(); out.report("audio_test");
    printf("audio_test: producer pacing: %d of %d frames started more than 1 ms late, worst %.2f ms\n", late, frames, maxlate);
    bool ok = out.integrity() && out.st.opened;
    if (stall) { bool seen = out.st.underruns >= 1 && out.st.silence > 0; printf("audio_test: the 200 ms stall was %s by the counters (%llu under-run(s), %llu frames of silence)\n", seen ? "seen" : "NOT SEEN", (unsigned long long)out.st.underruns, (unsigned long long)out.st.silence); ok = ok && seen; }
    printf("RESULT %s audio backend=%s underruns=%llu silence=%llu\n", ok ? "PASS" : "FAIL", out.st.backend.c_str(), (unsigned long long)out.st.underruns, (unsigned long long)out.st.silence);
    return ok ? 0 : 1;
}
