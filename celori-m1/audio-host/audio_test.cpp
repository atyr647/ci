// Tests of the host audio shim (celori_audio.c over miniaudio) in OFFLINE mode, natively and under ASan/UBSan: exact timing of voices, pan, spatialisation, pitch, stealing, determinism
// (including independence of how the frames are chunked), hostile WAV files, and the capture file. Usage: audio_test <dir containing step.wav> [capture.wav]
#include <time.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "celori_audio.h"

static int g_checks = 0, g_failed = 0;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_failed++; std::printf("FAIL %s:%d  %s   ", __FILE__, __LINE__, #cond); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

static std::vector<uint8_t> slurp(const std::string& p) { std::vector<uint8_t> b; FILE* f = std::fopen(p.c_str(), "rb"); if (!f) return b; uint8_t t[4096]; size_t n; while ((n = std::fread(t, 1, sizeof t, f)) > 0) b.insert(b.end(), t, t + n); std::fclose(f); return b; }
static uint64_t fnv(uint64_t h, const void* p, size_t n) { auto* b = static_cast<const uint8_t*>(p); for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; } return h; }

struct Mixer {
    celori_audio* a = nullptr; uint32_t sound = 0; char err[200] = {};
    explicit Mixer(const std::vector<uint8_t>& wav, const char* key = "sounds/step.wav") {
        a = celori_audio_create(CELORI_AUDIO_OFFLINE, 48000, err, sizeof err);
        if (a && celori_audio_load(a, key, wav.data(), wav.size(), &sound, err, sizeof err) != 0) { celori_audio_destroy(a); a = nullptr; }
    }
    ~Mixer() { celori_audio_destroy(a); }
    uint64_t play(float vol = 1, float pitch = 1, float pan = 0, bool spatial = false, float x = 0, float y = 0, float z = 0) { uint64_t v = 0; if (celori_audio_play(a, sound, vol, pitch, pan, spatial, x, y, z, &v, err, sizeof err) != 0) return ~0ull; return v; }
    void listener(float px, float py, float pz, float fx, float fy, float fz) { const float p[3] = {px, py, pz}, f[3] = {fx, fy, fz}, u[3] = {0, 1, 0}; celori_audio_set_listener(a, p, f, u); }
    celori_audio_stats stats() { celori_audio_stats s; celori_audio_stats_get(a, &s); return s; }
    void advance(uint32_t n) { celori_audio_advance(a, n); }
    // dump the capture through the WAV writer and read the samples back: also tests the writer
    std::vector<int16_t> mix(const char* path = "/tmp/celori_audio_test.wav") { std::vector<int16_t> out; if (celori_audio_write_wav(a, path) != 0) return out; auto b = slurp(path); if (b.size() < 44) return out; out.resize((b.size() - 44) / 2); std::memcpy(out.data(), b.data() + 44, out.size() * 2); return out; }
};
static int first_nonzero(const std::vector<int16_t>& m) { for (size_t i = 0; i < m.size(); i++) if (m[i]) return int(i / 2); return -1; }
static double peak(const std::vector<int16_t>& m, int ch) { double p = 0; for (size_t i = size_t(ch); i < m.size(); i += 2) p = std::fmax(p, std::fabs(double(m[i]))); return p; }
static double energy(const std::vector<int16_t>& m, int ch) { double e = 0; for (size_t i = size_t(ch); i < m.size(); i += 2) e += double(m[i]) * double(m[i]); return e; }

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: audio_test <dir with step.wav> [capture.wav]\n"); return 2; }
    const std::vector<uint8_t> wav = slurp(std::string(argv[1]) + "/step.wav");
    CHECK(wav.size() > 1000, "step.wav present");
    // the source's own peak, for level comparisons
    double src_peak = 0; { const int16_t* s = reinterpret_cast<const int16_t*>(wav.data() + 44); for (size_t i = 0; i < (wav.size() - 44) / 2; i++) src_peak = std::fmax(src_peak, std::fabs(double(s[i]))); }

    { Mixer m(wav); CHECK(m.a, "mixer: %s", m.err);
      celori_audio_info info; celori_audio_info_get(m.a, &info);
      CHECK(info.sample_rate == 48000 && info.channels == 2 && !info.realtime && std::string(info.backend) == "offline", "info: %u %u %d %s", info.sample_rate, info.channels, info.realtime, info.backend);
      m.advance(4800);
      auto mx = m.mix(); CHECK(mx.size() == 4800 * 2, "4800 frames of stereo, got %zu samples", mx.size()); CHECK(first_nonzero(mx) < 0, "silence when nothing plays");
      CHECK(celori_audio_find(m.a, "sounds/step.wav", &m.sound) == 1, "find"); uint32_t id2; CHECK(celori_audio_load(m.a, "sounds/step.wav", wav.data(), wav.size(), &id2, m.err, sizeof m.err) == 0 && id2 == m.sound, "loading the same key twice returns the same id"); }

    // exact onset: a voice started at frame N sounds from frame N
    { Mixer m(wav); m.advance(500); m.play(); m.advance(1000); auto mx = m.mix(); const int on = first_nonzero(mx);
      std::printf("  onset: a voice started at frame 500 first sounds at frame %d (miniaudio's pitch resampler adds a fixed latency of %d frame(s) = %.3f ms)\n", on, on - 500, 1000.0 * (on - 500) / 48000.0);
      CHECK(on == 501, "a voice started after 500 frames first sounds at frame 501 (500 + the resampler's one frame), got %d", on);
      Mixer two(wav); two.advance(1234); two.play(1, 2.0f, 0); two.advance(2000); const int on2 = first_nonzero(two.mix()); CHECK(on2 == 1235 || on2 == 1236, "the latency does not grow with the offset or the pitch: %d", on2); }
    // level and pan law (measured, then pinned)
    { Mixer m(wav); m.play(1, 1, 0); m.advance(12000); auto mx = m.mix(); const double pl = peak(mx, 0), pr = peak(mx, 1);
      std::printf("  centre: source peak %.0f, left peak %.0f, right peak %.0f (ratio %.4f)\n", src_peak, pl, pr, pl / src_peak);
      CHECK(pl == pr && pl > 0, "pan 0: both channels equal (%.0f / %.0f)", pl, pr);
      Mixer l(wav); l.play(1, 1, -1); l.advance(12000); auto ml = l.mix(); CHECK(peak(ml, 1) == 0 && peak(ml, 0) > 0, "pan -1 is left only: L %.0f R %.0f", peak(ml, 0), peak(ml, 1));
      Mixer r(wav); r.play(1, 1, 1); r.advance(12000); auto mr = r.mix(); CHECK(peak(mr, 0) == 0 && peak(mr, 1) > 0, "pan +1 is right only: L %.0f R %.0f", peak(mr, 0), peak(mr, 1));
      Mixer h(wav); h.play(0.5f, 1, 0); h.advance(12000); auto mh = h.mix(); CHECK(std::fabs(peak(mh, 0) / pl - 0.5) < 0.01, "volume 0.5 halves the level: %.4f", peak(mh, 0) / pl);
      Mixer z(wav); z.play(0, 1, 0); z.advance(12000); CHECK(first_nonzero(z.mix()) < 0, "volume 0 is silent"); }
    // spatial: left/right placement relative to a listener looking down -z, and inverse-distance attenuation
    { Mixer m(wav); m.listener(0, 0, 0, 0, 0, -1); m.play(1, 1, 0, true, -5, 0, 0); m.advance(12000); auto mx = m.mix();
      CHECK(energy(mx, 0) > 4 * energy(mx, 1), "a source at x=-5 is on the left: L %.3g R %.3g", energy(mx, 0), energy(mx, 1));
      Mixer r(wav); r.listener(0, 0, 0, 0, 0, -1); r.play(1, 1, 0, true, 5, 0, 0); r.advance(12000); auto mr = r.mix(); CHECK(energy(mr, 1) > 4 * energy(mr, 0), "x=+5 is on the right: L %.3g R %.3g", energy(mr, 0), energy(mr, 1));
      Mixer n(wav); n.listener(0, 0, 0, 0, 0, -1); n.play(1, 1, 0, true, 0, 0, -2); n.advance(12000); const double pn = peak(n.mix(), 0) + peak(n.mix(), 1);
      Mixer f(wav); f.listener(0, 0, 0, 0, 0, -1); f.play(1, 1, 0, true, 0, 0, -10); f.advance(12000); const double pf = peak(f.mix(), 0) + peak(f.mix(), 1);
      std::printf("  distance: peak at 2 m %.0f, at 10 m %.0f, ratio %.3f (inverse model with min distance 1 predicts 5)\n", pn, pf, pn / pf);
      CHECK(std::fabs(pn / pf - 5.0) < 0.15, "inverse distance attenuation: ratio %.3f", pn / pf);
      Mixer t(wav); t.listener(0, 0, 0, 0, 0, 1); t.play(1, 1, 0, true, -5, 0, 0); t.advance(12000); auto mt = t.mix(); CHECK(energy(mt, 1) > 4 * energy(mt, 0), "turning the listener round (forward +z) swaps the sides: L %.3g R %.3g", energy(mt, 0), energy(mt, 1)); }
    // pitch: a sound one octave up lasts half as long
    { auto length_of = [&](float pitch) { Mixer m(wav); m.play(1, pitch, 0); m.advance(24000); auto mx = m.mix(); int last = -1; for (size_t i = 0; i < mx.size(); i++) if (std::abs(mx[i]) > 3) last = int(i / 2); return last; };
      const int l1 = length_of(1.0f), l2 = length_of(2.0f); std::printf("  pitch: last audible frame %d at 1x, %d at 2x\n", l1, l2); CHECK(l1 > 0 && l2 > 0 && std::abs(2 * l2 - l1) < 400, "2x pitch halves the duration: %d vs %d", l1, l2); }
    // determinism, and independence of the chunking of advance()
    { auto run = [&](int chunk, std::vector<int16_t>* out) { Mixer m(wav); for (int t = 0; t < 120; t++) { if (t % 17 == 3) m.play(0.8f, 1.0f + 0.01f * float(t % 5), 0.2f * float((t % 3) - 1)); if (t % 23 == 5) m.play(1, 1.0f + 0.02f * float(t % 3), 0, true, float(t % 7) - 3, 0, -3); for (int k = 0; k < 800 / chunk; k++) m.advance(uint32_t(chunk)); } if (out) *out = m.mix(); return m.stats().mix_hash; };
      std::vector<int16_t> s800, s1;
      const uint64_t a = run(800, &s800), b = run(800, nullptr);
      CHECK(a == b, "same calls, same hash");
      // The contract is "same calls -> same samples" (the engine calls advance() with the same frame count every tick, and both hosts run this same code). How the frames are chunked changes a
      // few samples by at most a few LSB (miniaudio's block-wise float arithmetic): measured here and reported, not asserted to be zero.
      run(1, &s1); size_t nd = 0; int maxd = 0; for (size_t i = 0; i < s800.size() && i < s1.size(); i++) if (s800[i] != s1[i]) { nd++; maxd = std::max(maxd, std::abs(int(s800[i]) - int(s1[i]))); }
      std::printf("  chunking: 800 frames per call vs 1 frame per call differ in %zu of %zu samples, by at most %d LSB\n", nd, s800.size(), maxd);
      CHECK(maxd <= 4 && nd * 100 < s800.size(), "chunking changes at most a few LSB in under 1%% of samples: %zu samples, max %d", nd, maxd);
      std::printf("AUDIO_HASH %016llx\n", (unsigned long long)a);
      Mixer s1m(wav); s1m.play(); s1m.advance(4800); Mixer s2m(wav); s2m.play(); s2m.advance(4801); CHECK(s1m.stats().mix_hash != s2m.stats().mix_hash, "the hash is sensitive"); }
    // the capture hash equals an independent FNV over the file's samples; the file is a valid 16-bit stereo WAV
    { Mixer m(wav); m.play(); m.advance(9600); auto mx = m.mix(argc > 2 ? argv[2] : "/tmp/celori_audio_test.wav"); uint64_t h = 14695981039346656037ull; for (int16_t s : mx) h = fnv(h, &s, 2); CHECK(h == m.stats().mix_hash, "mix hash equals FNV-1a over the WAV samples"); std::printf("AUDIO_CAPTURE_HASH %016llx\n", (unsigned long long)m.stats().mix_hash);
      auto b = slurp(argc > 2 ? argv[2] : "/tmp/celori_audio_test.wav"); CHECK(b.size() == 44 + 9600 * 4 && std::memcmp(b.data(), "RIFF", 4) == 0 && std::memcmp(b.data() + 8, "WAVEfmt ", 8) == 0, "WAV header and size"); }
    // voice pool: more voices than slots steals the oldest and still counts
    { Mixer m(wav); for (int i = 0; i < 40; i++) m.play(); auto s = m.stats(); CHECK(s.voices_started == 40 && s.voices_stolen == 8, "40 voices on a pool of 32: started %llu stolen %llu", (unsigned long long)s.voices_started, (unsigned long long)s.voices_stolen);
      m.advance(48000); CHECK(m.stats().voices_active == 0, "finished voices are released"); }
    // bad parameters and unknown sounds are errors, not crashes
    { Mixer m(wav); uint64_t v; char err[100];
      CHECK(celori_audio_play(m.a, 999, 1, 1, 0, 0, 0, 0, 0, &v, err, sizeof err) != 0, "unknown sound id");
      CHECK(celori_audio_play(m.a, m.sound, 9, 1, 0, 0, 0, 0, 0, &v, err, sizeof err) != 0, "volume 9"); CHECK(celori_audio_play(m.a, m.sound, 1, 0, 0, 0, 0, 0, 0, &v, err, sizeof err) != 0, "pitch 0");
      CHECK(celori_audio_play(m.a, m.sound, 1, 1, 2, 0, 0, 0, 0, &v, err, sizeof err) != 0, "pan 2"); CHECK(celori_audio_play(m.a, m.sound, 1, 1, 0, 1, NAN, 0, 0, &v, err, sizeof err) != 0, "NaN position");
      m.advance(1u << 21); CHECK(m.stats().frames_mixed == 0, "an oversized advance is ignored"); }
    // hostile WAV files: truncations, bit flips, garbage. Whatever happens must be a clean error or a clean success, never a crash (ASan/UBSan build).
    { Mixer m(wav); int accepted = 0, rejected = 0; uint32_t id; char err[100];
      for (size_t len = 0; len < wav.size(); len += (len < 200 ? 1 : 997)) { std::vector<uint8_t> t(wav.begin(), wav.begin() + long(len)); (celori_audio_load(m.a, ("t" + std::to_string(len)).c_str(), t.data(), t.size(), &id, err, sizeof err) == 0 ? accepted : rejected)++; }
        uint64_t s = 99; auto rnd = [&]() { s = s * 6364136223846793005ull + 1442695040888963407ull; return uint32_t(s >> 33); };
      for (int k = 0; k < 400; k++) { std::vector<uint8_t> t = wav; for (int j = 0; j < 1 + int(rnd() % 4); j++) t[rnd() % std::min<size_t>(t.size(), 120)] = uint8_t(rnd()); if (m.stats().sounds_loaded >= 60) break; (celori_audio_load(m.a, ("m" + std::to_string(k)).c_str(), t.data(), t.size(), &id, err, sizeof err) == 0 ? accepted : rejected)++; }
      std::vector<uint8_t> junk(5000); for (auto& b : junk) b = uint8_t(rnd()); CHECK(celori_audio_load(m.a, "junk", junk.data(), junk.size(), &id, err, sizeof err) != 0, "random bytes are not a sound");
      std::printf("  hostile WAV files: %d rejected, %d accepted (all handled)\n", rejected, accepted); CHECK(rejected > 0, "some hostile files are rejected"); }
    // the null backend works as a real-time mode; with no output device the DEVICE mode must fail cleanly
    { char err[200]; celori_audio* n = celori_audio_create(CELORI_AUDIO_NULL, 48000, err, sizeof err); CHECK(n != nullptr, "null backend: %s", err);
      if (n) { celori_audio_info i; celori_audio_info_get(n, &i); CHECK(i.realtime && std::string(i.backend) == "null", "null backend info: %s", i.backend); uint32_t id; CHECK(celori_audio_load(n, "s", wav.data(), wav.size(), &id, err, sizeof err) == 0, "load"); uint64_t v; CHECK(celori_audio_play(n, id, 1, 1, 0, 0, 0, 0, 0, &v, err, sizeof err) == 0, "play");
        struct timespec ts = {0, 150 * 1000 * 1000}; nanosleep(&ts, nullptr); celori_audio_destroy(n); }
      celori_audio* d = celori_audio_create(CELORI_AUDIO_DEVICE, 48000, err, sizeof err); std::printf("  device mode in this environment: %s (%s)\n", d ? "created" : "unavailable", d ? "an output device exists" : err); celori_audio_destroy(d); }
    std::printf("audio_test: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
