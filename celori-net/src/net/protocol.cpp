#include "protocol.hpp"

#include <cmath>
#include <cstring>

extern "C" {
#include "monocypher.h"
}

namespace celori::net {
namespace {

struct Writer {
    std::vector<uint8_t>* b;
    void u8(uint8_t v) { b->push_back(v); }
    void u16(uint16_t v) { for (int i = 0; i < 2; i++) b->push_back(uint8_t(v >> (8 * i))); }
    void u32(uint32_t v) { for (int i = 0; i < 4; i++) b->push_back(uint8_t(v >> (8 * i))); }
    void u64(uint64_t v) { for (int i = 0; i < 8; i++) b->push_back(uint8_t(v >> (8 * i))); }
    void f32(float f) { uint32_t v; std::memcpy(&v, &f, 4); u32(v); }
    void raw(const uint8_t* p, size_t n) { b->insert(b->end(), p, p + n); }
};

struct Reader {
    const uint8_t* p; size_t n; size_t at = 0; bool bad = false;
    bool need(size_t k) { if (bad || n - at < k) { bad = true; return false; } return true; }
    uint8_t u8() { if (!need(1)) return 0; return p[at++]; }
    uint16_t u16() { if (!need(2)) return 0; uint16_t v = uint16_t(p[at] | (p[at + 1] << 8)); at += 2; return v; }
    uint32_t u32() { if (!need(4)) return 0; uint32_t v = 0; for (int i = 0; i < 4; i++) v |= uint32_t(p[at + i]) << (8 * i); at += 4; return v; }
    uint64_t u64() { if (!need(8)) return 0; uint64_t v = 0; for (int i = 0; i < 8; i++) v |= uint64_t(p[at + i]) << (8 * i); at += 8; return v; }
    float f32() { const uint32_t v = u32(); float f; std::memcpy(&f, &v, 4); return f; }
    void raw(uint8_t* out, size_t k) { if (!need(k)) return; std::memcpy(out, p + at, k); at += k; }
};

bool axis_ok(float v) { return std::isfinite(v) && v >= -1.0f && v <= 1.0f; }
bool input_ok(const Input& i) { return axis_ok(i.x) && axis_ok(i.y) && axis_ok(i.look) && axis_ok(i.look_y); }
uint8_t buttons(const Input& i) { return uint8_t(i.run) | uint8_t(i.jump) << 1 | uint8_t(i.interact) << 2 | uint8_t(i.attack) << 3 | uint8_t(i.alt) << 4 | uint8_t(i.menu) << 5; }

Mac mac_of(const Key& key, const uint8_t* data, size_t n) {
    Mac m{};
    crypto_blake2b_keyed(m.data(), m.size(), key.data(), key.size(), data, n);
    return m;
}

void context(std::vector<uint8_t>& b, const char* label, const Nonce& c, const Nonce& s, uint32_t conn) {
    b.insert(b.end(), label, label + std::strlen(label));
    b.insert(b.end(), c.begin(), c.end());
    b.insert(b.end(), s.begin(), s.end());
    for (int i = 0; i < 4; i++) b.push_back(uint8_t(conn >> (8 * i)));
}

bool known(uint8_t t) { return t >= uint8_t(Type::Hello) && t <= uint8_t(Type::Pong); }

}  // namespace

const char* refusal_name(Refusal r) {
    switch (r) {
        case Refusal::Version: return "version"; case Refusal::Game: return "game"; case Refusal::Account: return "account"; case Refusal::Auth: return "auth";
        case Refusal::Full: return "full"; case Refusal::Protocol: return "protocol"; case Refusal::TimedOut: return "timed_out"; case Refusal::Left: return "left"; case Refusal::Kicked: return "kicked";
    }
    return "?";
}

bool authenticated(Type t) { return t == Type::Welcome || t == Type::Inputs || t == Type::Snapshot || t == Type::Leave || t == Type::Ping || t == Type::Pong; }

Mac login_proof(const Key& player_key, const Nonce& client, const Nonce& server, uint32_t connection) {
    std::vector<uint8_t> b; context(b, "celori-auth", client, server, connection);
    return mac_of(player_key, b.data(), b.size());
}

Key session_key(const Key& player_key, const Nonce& client, const Nonce& server, uint32_t connection) {
    std::vector<uint8_t> b; context(b, "celori-session", client, server, connection);
    Key k{};
    crypto_blake2b_keyed(k.data(), k.size(), player_key.data(), player_key.size(), b.data(), b.size());
    return k;
}

bool mac_equal(const Mac& a, const Mac& b) { return crypto_verify16(a.data(), b.data()) == 0; }

bool encode(const Message& m, const Key* session, std::vector<uint8_t>* out, std::string* error) {
    auto fail = [&](const char* why) { if (error) *error = why; return false; };
    if (authenticated(m.type) && !session) return fail("an authenticated message needs the session key");
    std::vector<uint8_t> b;
    b.reserve(kMaxDatagram);
    Writer w{&b};
    w.u32(kMagic); w.u16(kProtocolVersion); w.u8(uint8_t(m.type)); w.u32(m.connection); w.u32(m.sequence);
    switch (m.type) {
        case Type::Hello: w.u64(m.game); w.u32(m.account); w.raw(m.client_nonce.data(), kNonceSize); break;
        case Type::Challenge: w.raw(m.server_nonce.data(), kNonceSize); break;
        case Type::Auth: w.raw(m.proof.data(), kMacSize); break;
        case Type::Welcome: w.u32(uint32_t(m.player)); w.u64(m.tick); w.u16(m.tick_hz); break;
        case Type::Refused: case Type::Leave:
            if (m.text.size() > kMaxReason) return fail("reason too long");
            w.u8(uint8_t(m.reason)); w.u16(uint16_t(m.text.size())); w.raw(reinterpret_cast<const uint8_t*>(m.text.data()), m.text.size()); break;
        case Type::Inputs:
            if (m.inputs.empty() || m.inputs.size() > kMaxInputsPerMessage) return fail("1..16 inputs per message");
            w.u64(m.ack); w.u64(m.tick); w.u8(uint8_t(m.inputs.size()));
            for (const Input& i : m.inputs) {
                if (!input_ok(i)) return fail("an input value is not finite or outside -1..1");
                w.f32(i.x); w.f32(i.y); w.f32(i.look); w.f32(i.look_y); w.u8(buttons(i));
            }
            break;
        case Type::Snapshot:
            if (m.bytes.size() > kMaxFragment) return fail("fragment too large");
            if (m.fragments == 0 || m.fragments > kMaxFragments || m.fragment >= m.fragments) return fail("bad fragment numbers");
            w.u64(m.tick); w.u32(m.snapshot); w.u64(m.baseline); w.u64(m.input_tick); w.u16(m.fragment); w.u16(m.fragments); w.u16(uint16_t(m.bytes.size())); w.raw(m.bytes.data(), m.bytes.size()); break;
        case Type::Ping: case Type::Pong: w.u64(m.stamp); break;
    }
    if (authenticated(m.type)) { const Mac mac = mac_of(*session, b.data(), b.size()); w.raw(mac.data(), kMacSize); }
    if (b.size() > kMaxDatagram) return fail("message larger than a datagram");
    *out = std::move(b);
    return true;
}

bool peek(const uint8_t* data, size_t size, Type* type, uint32_t* connection) {
    if (!data || size < kHeaderSize || size > kMaxDatagram) return false;
    Reader r{data, size};
    if (r.u32() != kMagic || r.u16() != kProtocolVersion) return false;
    const uint8_t t = r.u8();
    if (!known(t)) return false;
    *type = Type(t); *connection = r.u32();
    return true;
}

bool decode(const uint8_t* data, size_t size, const Key* session, Message* out, std::string* error) {
    auto fail = [&](const char* why) { if (error) *error = why; return false; };
    if (!data || size < kHeaderSize) return fail("shorter than a header");
    if (size > kMaxDatagram) return fail("larger than a datagram");
    Reader r{data, size};
    if (r.u32() != kMagic) return fail("not a Celori datagram");
    if (r.u16() != kProtocolVersion) return fail("another protocol version");
    const uint8_t t = r.u8();
    if (!known(t)) return fail("unknown message type");
    Message m;
    m.type = Type(t); m.connection = r.u32(); m.sequence = r.u32();
    size_t body_end = size;
    if (authenticated(m.type)) {
        if (!session) return fail("an authenticated message without a session");
        if (size < kHeaderSize + kMacSize) return fail("no room for the MAC");
        body_end = size - kMacSize;
        Mac got; std::memcpy(got.data(), data + body_end, kMacSize);
        if (!mac_equal(got, mac_of(*session, data, body_end))) return fail("wrong MAC");
    }
    r.n = body_end;
    switch (m.type) {
        case Type::Hello: m.game = r.u64(); m.account = r.u32(); r.raw(m.client_nonce.data(), kNonceSize); break;
        case Type::Challenge: r.raw(m.server_nonce.data(), kNonceSize); break;
        case Type::Auth: r.raw(m.proof.data(), kMacSize); break;
        case Type::Welcome: m.player = int32_t(r.u32()); m.tick = r.u64(); m.tick_hz = r.u16(); if (m.tick_hz == 0 || m.tick_hz > 1000) return fail("bad tick rate"); break;
        case Type::Refused: case Type::Leave: {
            const uint8_t reason = r.u8();
            if (reason < uint8_t(Refusal::Version) || reason > uint8_t(Refusal::Kicked)) return fail("unknown reason");
            m.reason = Refusal(reason);
            const uint16_t n = r.u16();
            if (n > kMaxReason) return fail("reason too long");
            if (!r.need(n)) return fail("cut short");
            m.text.assign(reinterpret_cast<const char*>(data + r.at), n); r.at += n;
            break;
        }
        case Type::Inputs: {
            m.ack = r.u64(); m.tick = r.u64();
            const uint8_t n = r.u8();
            if (n == 0 || n > kMaxInputsPerMessage) return fail("1..16 inputs per message");
            m.inputs.resize(n);
            for (Input& i : m.inputs) {
                i.x = r.f32(); i.y = r.f32(); i.look = r.f32(); i.look_y = r.f32();
                const uint8_t bt = r.u8();
                if (bt & 0xC0) return fail("unknown button bits");
                i.run = bt & 1; i.jump = bt & 2; i.interact = bt & 4; i.attack = bt & 8; i.alt = bt & 16; i.menu = bt & 32;
                if (!r.bad && !input_ok(i)) return fail("an input value is not finite or outside -1..1");
            }
            break;
        }
        case Type::Snapshot: {
            m.tick = r.u64(); m.snapshot = r.u32(); m.baseline = r.u64(); m.input_tick = r.u64(); m.fragment = r.u16(); m.fragments = r.u16();
            const uint16_t n = r.u16();
            if (m.fragments == 0 || m.fragments > kMaxFragments || m.fragment >= m.fragments) return fail("bad fragment numbers");
            if (n > kMaxFragment) return fail("fragment too large");
            if (!r.need(n)) return fail("cut short");
            m.bytes.assign(data + r.at, data + r.at + n); r.at += n;
            if (m.baseline >= m.tick && m.baseline != 0) return fail("a baseline that is not older than the snapshot");
            break;
        }
        case Type::Ping: case Type::Pong: m.stamp = r.u64(); break;
    }
    if (r.bad) return fail("cut short");
    if (r.at != body_end) return fail("bytes left over");
    *out = std::move(m);
    return true;
}

}  // namespace celori::net
