// Gamepad back end test: polls for N seconds, prints every event and checks it against the sequence the Linux uinput feeder (uinput_feeder.c) injects.
//   pad_test [--seconds=N] [--expect=uinput] [--allow-none]
// Without a controller (--allow-none): reports what the API said and ends with RESULT API-ONLY (the API path ran, no controller input was tested).
#include "gamepad.h"
static const char *bn[] = {"A", "B", "X", "Y", "LB", "RB", "Back", "Start", "Guide", "LS", "RS", "DUp", "DDown", "DLeft", "DRight"}, *an[] = {"LX", "LY", "RX", "RY", "LT", "RT"};
int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0); ShowCrashReports(); double secs = 3; bool uin = false, none_ok = false;
    for (int i = 1; i < argc; i++) { if (!strncmp(argv[i], "--seconds=", 10)) secs = atof(argv[i] + 10); else if (!strcmp(argv[i], "--expect=uinput")) uin = true; else if (!strcmp(argv[i], "--allow-none")) none_ok = true; }
    pad::Gamepads g; bool ok = g.init();
    printf("pad_test: platform=%s arch=%s backend=%s init=%s (%s)\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", IsAarch64() ? "aarch64" : "x86_64", g.backend.c_str(), ok ? "ok" : "failed", g.note.c_str());
    if (!ok && !none_ok) { puts("RESULT FAIL no gamepad back end"); return 2; }
    std::vector<pad::Event> got; double t0 = pad::now_s(); int connects = 0;
    while (pad::now_s() - t0 < secs) { std::vector<pad::Event> ev; g.poll(ev);
        for (auto &e : ev) { got.push_back(e);
            if (e.type == pad::EV_CONNECT) { connects++; printf("pad_test: pad %d connected\n", e.pad); } else if (e.type == pad::EV_DISCONNECT) printf("pad_test: pad %d disconnected\n", e.pad);
            else if (e.type == pad::EV_BUTTON) printf("pad_test: pad %d button %s = %d\n", e.pad, bn[e.index], e.value); else printf("pad_test: pad %d axis %s = %d\n", e.pad, an[e.index], e.value); }
        struct timespec ts = {0, 2000000}; nanosleep(&ts, nullptr); }
    printf("pad_test: %d event(s), %d controller(s) connected during the run, now %d; %s\n", (int)got.size(), connects, g.count(), g.detail().c_str());
    if (uin) {
        // what uinput_feeder.c sends, in this order (value normalised to the standard layout; evdev's up-negative Y is inverted)
        struct X { int type, index, value; } want[] = {{pad::EV_BUTTON, pad::B_A, 1}, {pad::EV_BUTTON, pad::B_A, 0}, {pad::EV_AXIS, pad::A_LX, 16384}, {pad::EV_AXIS, pad::A_LX, -32768}, {pad::EV_AXIS, pad::A_LY, 32767},
            {pad::EV_AXIS, pad::A_RT, 32767}, {pad::EV_BUTTON, pad::B_DRIGHT, 1}, {pad::EV_BUTTON, pad::B_DRIGHT, 0}, {pad::EV_BUTTON, pad::B_START, 1}, {pad::EV_BUTTON, pad::B_START, 0}, {pad::EV_AXIS, pad::A_LX, 0}};
        size_t k = 0; for (auto &e : got) if (k < sizeof want / sizeof *want && e.type == want[k].type && e.index == want[k].index && e.value == want[k].value) k++;
        size_t total = sizeof want / sizeof *want; printf("pad_test: matched %zu of %zu expected events in order\n", k, total);
        bool pass = k == total && connects >= 1; printf("RESULT %s gamepad uinput events=%zu/%zu\n", pass ? "PASS" : "FAIL", k, total); return pass ? 0 : 1;
    }
    if (got.empty() || g.count() == 0) { printf("RESULT API-ONLY gamepad no controller connected (backend %s ran, no input was tested)\n", g.backend.c_str()); return none_ok ? 0 : 1; }
    printf("RESULT PASS gamepad events=%zu\n", got.size()); return 0;
}
