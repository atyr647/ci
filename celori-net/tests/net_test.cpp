// E10 part 2: the wire format (net/protocol.cpp). Natively under ASan+UBSan and in the guest; the gate compares the NET_HASH lines.
//   A  every type encodes and decodes to itself
//   B  the login: the proof and the session key depend on the key, both nonces and the connection; a wrong key's proof differs
//   C  every truncation of every message is refused; every message with a byte added is refused
//   D  an authenticated message with any one bit changed is refused (the MAC), and with another session's key
//   E  limits: inputs (count, finite, -1..1, unknown buttons), fragments (size, numbers), reasons, versions, magic, types, the datagram size
//   F  random datagrams and mutated real ones never crash, never decode to an authenticated type without the key
#include <cstdio>
#include <limits>
#include <cstring>
#include <string>
#include <vector>

#include "../src/net/protocol.hpp"

using namespace celori;
using namespace celori::net;

static int g_checks = 0, g_failed = 0;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_failed++; std::printf("FAIL %s:%d  %s   ", __FILE__, __LINE__, #cond); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

void celori_test_mac(const Key& k, const std::vector<uint8_t>& v, Mac* out);      // a raw keyed BLAKE2b, to seal hand-built messages (defined at the end)

namespace {
uint64_t g_hash = 1469598103934665603ull;
void mix(const std::vector<uint8_t>& b) { for (uint8_t c : b) { g_hash ^= c; g_hash *= 1099511628211ull; } }
uint32_t rng_state = 12345;
uint32_t rnd() { rng_state ^= rng_state << 13; rng_state ^= rng_state >> 17; rng_state ^= rng_state << 5; return rng_state; }
Key key_of(uint8_t seed) { Key k{}; for (size_t i = 0; i < k.size(); i++) k[i] = uint8_t(seed * 31 + i); return k; }
Nonce nonce_of(uint8_t seed) { Nonce n{}; for (size_t i = 0; i < n.size(); i++) n[i] = uint8_t(seed + 7 * i); return n; }

std::vector<Message> samples() {
    std::vector<Message> v;
    Message h; h.type = Type::Hello; h.game = 0x1122334455667788ull; h.account = 42; h.client_nonce = nonce_of(1); v.push_back(h);
    Message c; c.type = Type::Challenge; c.connection = 7; c.server_nonce = nonce_of(2); v.push_back(c);
    Message a; a.type = Type::Auth; a.connection = 7; a.proof = login_proof(key_of(1), nonce_of(1), nonce_of(2), 7); v.push_back(a);
    Message w; w.type = Type::Welcome; w.connection = 7; w.sequence = 1; w.player = 3; w.tick = 1234; w.tick_hz = 60; v.push_back(w);
    Message r; r.type = Type::Refused; r.reason = Refusal::Game; r.text = "another build of the game"; v.push_back(r);
    Message in; in.type = Type::Inputs; in.connection = 7; in.sequence = 9; in.ack = 1200; in.tick = 1300;
    for (int i = 0; i < 16; i++) { Input x; x.x = float(i) / 16.0f - 0.5f; x.y = -1; x.look = 1; x.look_y = 0.25f; x.jump = i & 1; x.interact = i & 2; x.menu = i & 4; x.run = i & 8; in.inputs.push_back(x); }
    v.push_back(in);
    Message s; s.type = Type::Snapshot; s.connection = 7; s.sequence = 10; s.tick = 1310; s.snapshot = 55; s.baseline = 1300; s.input_tick = 1305; s.fragment = 2; s.fragments = 5;
    for (size_t i = 0; i < kMaxFragment; i++) s.bytes.push_back(uint8_t(i * 7));
    v.push_back(s);
    Message l; l.type = Type::Leave; l.connection = 7; l.reason = Refusal::Left; v.push_back(l);
    Message p; p.type = Type::Ping; p.connection = 7; p.stamp = 99; v.push_back(p);
    Message q; q.type = Type::Pong; q.connection = 7; q.stamp = 99; v.push_back(q);
    return v;
}

bool same(const Message& a, const Message& b) {
    if (a.type != b.type || a.connection != b.connection || a.sequence != b.sequence) return false;
    switch (a.type) {
        case Type::Hello: return a.game == b.game && a.account == b.account && a.client_nonce == b.client_nonce;
        case Type::Challenge: return a.server_nonce == b.server_nonce;
        case Type::Auth: return a.proof == b.proof;
        case Type::Welcome: return a.player == b.player && a.tick == b.tick && a.tick_hz == b.tick_hz;
        case Type::Refused: case Type::Leave: return a.reason == b.reason && a.text == b.text;
        case Type::Inputs: {
            if (a.ack != b.ack || a.tick != b.tick || a.inputs.size() != b.inputs.size()) return false;
            for (size_t i = 0; i < a.inputs.size(); i++) {
                const Input& x = a.inputs[i]; const Input& y = b.inputs[i];
                if (x.x != y.x || x.y != y.y || x.look != y.look || x.look_y != y.look_y || x.run != y.run || x.jump != y.jump || x.interact != y.interact || x.attack != y.attack || x.alt != y.alt || x.menu != y.menu) return false;
            }
            return true;
        }
        case Type::Snapshot: return a.tick == b.tick && a.snapshot == b.snapshot && a.baseline == b.baseline && a.input_tick == b.input_tick && a.fragment == b.fragment && a.fragments == b.fragments && a.bytes == b.bytes;
        case Type::Ping: case Type::Pong: return a.stamp == b.stamp;
    }
    return false;
}
}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    const Key session = session_key(key_of(1), nonce_of(1), nonce_of(2), 7);
    const Key other = session_key(key_of(2), nonce_of(1), nonce_of(2), 7);
    std::string err;

    // ---- A: round trips
    std::vector<std::vector<uint8_t>> wire;
    for (const Message& m : samples()) {
        std::vector<uint8_t> b;
        const bool encoded = encode(m, &session, &b, &err);
        CHECK(encoded, "encode type %d: %s", int(m.type), err.c_str());
        if (!encoded) continue;
        CHECK(b.size() <= kMaxDatagram, "type %d fits a datagram: %zu", int(m.type), b.size());
        Message d;
        CHECK(decode(b.data(), b.size(), &session, &d, &err) && same(m, d), "type %d decodes to itself: %s", int(m.type), err.c_str());
        Type t; uint32_t conn;
        CHECK(peek(b.data(), b.size(), &t, &conn) && t == m.type && conn == m.connection, "peek type %d", int(m.type));
        mix(b); wire.push_back(b);
    }
    CHECK(wire.size() == 10 && wire[6].size() == kMaxDatagram, "a full snapshot fragment fills a datagram exactly: %zu", wire.size() == 10 ? wire[6].size() : size_t(0));
    if (wire.size() != 10) { std::printf("net_test: %d checks, %d failed\n", g_checks, g_failed); return 1; }

    // ---- B: the login
    {
        const Mac p = login_proof(key_of(1), nonce_of(1), nonce_of(2), 7);
        CHECK(!mac_equal(p, login_proof(key_of(2), nonce_of(1), nonce_of(2), 7)), "another key gives another proof");
        CHECK(!mac_equal(p, login_proof(key_of(1), nonce_of(3), nonce_of(2), 7)) && !mac_equal(p, login_proof(key_of(1), nonce_of(1), nonce_of(3), 7)) && !mac_equal(p, login_proof(key_of(1), nonce_of(1), nonce_of(2), 8)),
              "the proof depends on both nonces and the connection");
        CHECK(session != other && session != session_key(key_of(1), nonce_of(1), nonce_of(2), 8), "the session key depends on the key and the connection");
        Mac pk; std::memcpy(pk.data(), session.data(), kMacSize);
        CHECK(!mac_equal(p, pk), "the proof is not the session key");
        std::vector<uint8_t> pb(p.begin(), p.end()); mix(pb);
    }

    // ---- C: truncations and extensions
    for (const std::vector<uint8_t>& b : wire) {
        int accepted = 0;
        for (size_t n = 0; n < b.size(); n++) { Message d; if (decode(b.data(), n, &session, &d, &err)) accepted++; }
        CHECK(accepted == 0, "every truncation of a type %d message is refused (%d accepted)", int(b[6]), accepted);
        std::vector<uint8_t> longer = b; longer.push_back(0);
        Message d;
        CHECK(!decode(longer.data(), longer.size(), &session, &d, &err), "a type %d message with a byte added is refused", int(b[6]));
    }

    // ---- D: the MAC
    for (const std::vector<uint8_t>& b : wire) {
        if (!authenticated(Type(b[6]))) continue;
        int accepted = 0;
        for (size_t i = 0; i < b.size(); i++) for (int bit = 0; bit < 8; bit++) {
            std::vector<uint8_t> x = b; x[i] ^= uint8_t(1u << bit);
            Message d;
            if (decode(x.data(), x.size(), &session, &d, &err)) accepted++;
        }
        CHECK(accepted == 0, "type %d: every one-bit change is refused (%d accepted)", int(b[6]), accepted);
        Message d;
        CHECK(!decode(b.data(), b.size(), &other, &d, &err) && err == "wrong MAC", "type %d under another session's key: %s", int(b[6]), err.c_str());
        CHECK(!decode(b.data(), b.size(), nullptr, &d, &err), "type %d without a session", int(b[6]));
    }

    // ---- E: limits
    {
        std::vector<uint8_t> b;
        Message m; m.type = Type::Inputs;
        CHECK(!encode(m, &session, &b, &err), "no inputs: refused to encode");
        m.inputs.assign(17, Input{});
        CHECK(!encode(m, &session, &b, &err), "17 inputs: refused to encode");
        for (float bad : {1.5f, -1.01f, std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity()}) {
            m.inputs.assign(1, Input{}); m.inputs[0].look = bad;
            CHECK(!encode(m, &session, &b, &err), "an input value %f: refused to encode", double(bad));
        }
        // the same values written into a valid message (MAC recomputed by encoding a valid one and patching before the MAC is added is not possible, so: decode without a MAC type is not
        // available for INPUTS; the check is that a correctly MAC'd message with a bad value is refused: build it by hand)
        auto sealed = [&](std::vector<uint8_t> body) {      // header + body + MAC under `session`
            std::vector<uint8_t> v;
            Message h; h.type = Type::Ping; h.connection = 7; std::vector<uint8_t> tmp; encode(h, &session, &tmp, nullptr);
            v.assign(tmp.begin(), tmp.begin() + long(kHeaderSize));
            v[6] = uint8_t(Type::Inputs);
            v.insert(v.end(), body.begin(), body.end());
            Mac mac{};
            celori_test_mac(session, v, &mac);
            v.insert(v.end(), mac.begin(), mac.end());
            return v;
        };
        auto input_body = [](uint8_t count, float look, uint8_t buttons) {      // ack u64, first tick u64, count u8, then count x (x, y, look, look_y f32, buttons u8)
            std::vector<uint8_t> b(16, 0); b.push_back(count);
            for (int i = 0; i < count; i++) { const float f[4] = {0, 0, look, 0}; for (float x : f) { uint8_t q[4]; std::memcpy(q, &x, 4); b.insert(b.end(), q, q + 4); } b.push_back(buttons); }
            return b;
        };
        Message d;
        std::vector<uint8_t> ok = sealed(input_body(2, 0.5f, 3));
        CHECK(decode(ok.data(), ok.size(), &session, &d, &err) && d.inputs.size() == 2 && d.inputs[0].look == 0.5f && d.inputs[1].run && d.inputs[1].jump, "a hand-built input message decodes: %s", err.c_str());
        std::vector<uint8_t> x = sealed(input_body(2, 2.0f, 0));
        CHECK(!decode(x.data(), x.size(), &session, &d, &err) && err.find("outside") != std::string::npos, "look 2.0 is refused: %s", err.c_str());
        x = sealed(input_body(1, std::numeric_limits<float>::quiet_NaN(), 0));
        CHECK(!decode(x.data(), x.size(), &session, &d, &err) && err.find("finite") != std::string::npos, "NaN is refused: %s", err.c_str());
        x = sealed(input_body(1, 0, 0x40));
        CHECK(!decode(x.data(), x.size(), &session, &d, &err) && err.find("button") != std::string::npos, "an unknown button bit is refused: %s", err.c_str());
        x = sealed(input_body(0, 0, 0));
        CHECK(!decode(x.data(), x.size(), &session, &d, &err), "zero inputs are refused");
        x = sealed(input_body(17, 0, 0));
        CHECK(!decode(x.data(), x.size(), &session, &d, &err), "17 inputs are refused");
        Message f; f.type = Type::Snapshot; f.fragments = 0;
        CHECK(!encode(f, &session, &b, &err), "zero fragments: refused to encode");
        f.fragments = 2; f.fragment = 2;
        CHECK(!encode(f, &session, &b, &err), "fragment 2 of 2: refused to encode");
        f.fragment = 0; f.bytes.assign(kMaxFragment + 1, 0);
        CHECK(!encode(f, &session, &b, &err), "a fragment one byte too large: refused to encode");
        Message r; r.type = Type::Refused; r.text.assign(kMaxReason + 1, 'x');
        CHECK(!encode(r, nullptr, &b, &err), "a reason of 201 bytes: refused to encode");
        CHECK(!encode(samples()[3], nullptr, &b, &err), "WELCOME without a session key: refused to encode");
        std::vector<uint8_t> hello = wire[0];
        std::vector<uint8_t> v = hello; v[4] = 2;
        CHECK(!decode(v.data(), v.size(), &session, &d, &err) && err == "another protocol version", "version 2: %s", err.c_str());
        v = hello; v[0] = 'X';
        CHECK(!decode(v.data(), v.size(), &session, &d, &err) && err == "not a Celori datagram", "wrong magic: %s", err.c_str());
        for (uint8_t t : {uint8_t(0), uint8_t(11), uint8_t(255)}) { v = hello; v[6] = t; CHECK(!decode(v.data(), v.size(), &session, &d, &err) && err == "unknown message type", "type %d: %s", t, err.c_str()); }
        std::vector<uint8_t> big(kMaxDatagram + 1, 0);
        CHECK(!decode(big.data(), big.size(), &session, &d, &err), "a datagram of 1201 bytes is refused");
        std::vector<uint8_t> rf = wire[4]; rf[kHeaderSize] = 0;
        CHECK(!decode(rf.data(), rf.size(), &session, &d, &err) && err == "unknown reason", "reason 0: %s", err.c_str());
    }

    // ---- F: random and mutated datagrams
    {
        int authed = 0, crashed_not = 0;
        for (int i = 0; i < 200000; i++) {
            std::vector<uint8_t> b;
            if (i % 2 == 0) { b.resize(rnd() % (kMaxDatagram + 16)); for (uint8_t& c : b) c = uint8_t(rnd()); if (b.size() >= 7 && (i % 4 == 0)) { b[0] = 'C'; b[1] = 'L'; b[2] = 'R'; b[3] = 'N'; b[4] = 1; b[5] = 0; b[6] = uint8_t(1 + rnd() % 10); } }
            else { b = wire[rnd() % wire.size()]; const int k = 1 + int(rnd() % 4); for (int j = 0; j < k && !b.empty(); j++) b[rnd() % b.size()] = uint8_t(rnd()); if (rnd() % 3 == 0 && !b.empty()) b.resize(rnd() % b.size()); }
            Message d;
            if (decode(b.data(), b.size(), &session, &d, &err) && authenticated(d.type)) {
                // a mutated authenticated message can only decode if the mutation left it unchanged
                bool unchanged = false; for (const auto& w : wire) if (w == b) unchanged = true;
                if (!unchanged) authed++;
            }
            crashed_not++;
        }
        CHECK(authed == 0, "no random or mutated datagram decodes to an authenticated message (%d did)", authed);
        CHECK(crashed_not == 200000, "200000 random and mutated datagrams decoded without a crash");
    }

    std::printf("NET_HASH %016llx\n", (unsigned long long)g_hash);
    std::printf("net_test: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}

extern "C" {
#include "monocypher.h"
}
void celori_test_mac(const Key& k, const std::vector<uint8_t>& v, Mac* out) { crypto_blake2b_keyed(out->data(), out->size(), k.data(), k.size(), v.data(), v.size()); }
