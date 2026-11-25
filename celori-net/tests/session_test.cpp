// E10 part 2: server and client sessions (net/session.cpp) over the simulated network (net/netsim.hpp). Natively (also under ASan+UBSan) and in the guest; the gate compares the SESSION_HASH lines.
//   A  logins: a good one; a wrong key, another build, an unknown account, an account already playing, a full server: each refused with its reason
//   B  inputs over a bad network (latency, jitter, loss, duplicates): with each input sent in 8 consecutive messages the server uses exactly the client's input on every tick
//   C  snapshots split into fragments over the same network: the client only ever holds a whole snapshot, byte for byte what was sent, and never an older one after a newer one
//   D  acks: the server's baseline follows the client's ack; an ack of a snapshot never sent is ignored
//   E  attacks: a datagram sent again (replay), a datagram from another address, a refusal from a stranger during the login, inputs far ahead or long past
//   F  endings: leave, kick, a silent client timed out (and told)
#include <cstdio>
#include <cstring>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "../src/net/netsim.hpp"

using namespace celori;
using namespace celori::net;

static int g_checks = 0, g_failed = 0;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_failed++; std::printf("FAIL %s:%d  %s   ", __FILE__, __LINE__, #cond); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

namespace {
uint64_t g_hash = 1469598103934665603ull;
void mix(const void* p, size_t n) { const uint8_t* b = static_cast<const uint8_t*>(p); for (size_t i = 0; i < n; i++) { g_hash ^= b[i]; g_hash *= 1099511628211ull; } }
void mix_u64(uint64_t v) { mix(&v, 8); }

Key key_of(uint32_t account) { Key k{}; for (size_t i = 0; i < k.size(); i++) k[i] = uint8_t(account * 13 + i * 7 + 1); return k; }
struct Nonces { uint64_t s; Nonce operator()() { Nonce n{}; for (auto& b : n) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; b = uint8_t(s); } return n; } };

constexpr Peer kServer = 1;
constexpr uint64_t kGame = 0xC0FFEE;

ServerConfig config(uint32_t max_players = 4) {
    ServerConfig c; c.game = kGame; c.max_players = max_players; c.timeout_ticks = 120; c.login_timeout_ticks = 60;
    c.key_of = [](uint32_t a) -> std::optional<Key> { if (a >= 100 && a < 200) return key_of(a); return std::nullopt; };
    c.nonce = Nonces{77};
    return c;
}

struct Rig {
    NetSim net; Server server; std::map<Peer, Client*> clients; uint64_t now = 1;
    Rig(NetSimConfig nc, ServerConfig sc) : net(nc), server(std::move(sc)) {}
    void add(Peer p, Client* c) { clients[p] = c; }
    void flush() {
        for (Datagram& d : server.take_outbox()) net.send(kServer, d.peer, std::move(d.bytes), now);
        for (auto& [p, c] : clients) for (Datagram& d : c->take_outbox()) net.send(p, d.peer, std::move(d.bytes), now);
    }
    void step() {        // one tick: deliver what is due, let the server tick, send what was produced
        flush();
        for (auto& [from, bytes] : net.receive(kServer, now)) server.receive(from, bytes.data(), bytes.size(), now);
        for (auto& [p, c] : clients) for (auto& [from, bytes] : net.receive(p, now)) c->receive(from, bytes.data(), bytes.size());
        server.tick(now);
        flush();
        now++;
    }
    void run(int n) { for (int i = 0; i < n; i++) step(); }
};
}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    // ---- A: logins
    {
        Rig r({2, 0, 0, 0, 1}, config(2));
        Client good(kGame, 100, key_of(100), Nonces{1}), wrong_key(kGame, 101, key_of(999), Nonces{2}), other_build(kGame + 1, 102, key_of(102), Nonces{3}),
               unknown(kGame, 7, key_of(7), Nonces{4}), twin(kGame, 100, key_of(100), Nonces{5}), second(kGame, 103, key_of(103), Nonces{6}), third(kGame, 104, key_of(104), Nonces{7});
        r.add(2, &good); r.add(3, &wrong_key); r.add(4, &other_build); r.add(5, &unknown);
        good.connect(kServer); wrong_key.connect(kServer); other_build.connect(kServer); unknown.connect(kServer);
        r.run(20);
        CHECK(good.state() == Client::State::Live && good.player() == 1, "a good login: live as player 1 (state %d, player %d)", int(good.state()), good.player());
        CHECK(wrong_key.state() == Client::State::Refused && wrong_key.refusal() == Refusal::Auth, "a wrong key: refused (auth): %d %s", int(wrong_key.refusal()), wrong_key.refusal_text().c_str());
        CHECK(other_build.state() == Client::State::Refused && other_build.refusal() == Refusal::Game, "another build: refused (game)");
        CHECK(unknown.state() == Client::State::Refused && unknown.refusal() == Refusal::Account, "an unknown account: refused (account)");
        r.add(6, &twin); twin.connect(kServer); r.run(20);
        CHECK(twin.state() == Client::State::Refused && twin.refusal() == Refusal::Account && twin.refusal_text().find("already") != std::string::npos, "an account already playing: refused: %s", twin.refusal_text().c_str());
        r.add(7, &second); second.connect(kServer); r.run(20);
        CHECK(second.state() == Client::State::Live && second.player() == 2, "a second player: live as player 2");
        r.add(8, &third); third.connect(kServer); r.run(20);
        CHECK(third.state() == Client::State::Refused && third.refusal() == Refusal::Full, "a third on a server for two: refused (full)");
        const auto ev = r.server.take_events();
        CHECK(ev.size() == 2 && ev[0].kind == Server::Event::Joined && ev[0].player == 1 && ev[0].account == 100 && ev[1].player == 2 && ev[1].account == 103, "two joined events (%zu)", ev.size());
        CHECK(r.server.stats().logins == 2 && r.server.stats().refused == 5, "2 logins, 5 refusals (%llu, %llu)", (unsigned long long)r.server.stats().logins, (unsigned long long)r.server.stats().refused);
        mix_u64(r.server.stats().sent_bytes);
    }

    // ---- B, C, D: a bad network: latency 5 + jitter 0..4 ticks, 20 % lost, 5 % duplicated
    {
        Rig r({5, 4, 200, 50, 1234}, config());
        Client c(kGame, 150, key_of(150), Nonces{9});
        r.add(2, &c); c.connect(kServer);
        int waited = 0;
        while (c.state() != Client::State::Live && waited < 600) {       // a lost login is retried: a new HELLO after 30 ticks of nothing
            r.step(); waited++;
            if (waited % 30 == 0 && c.state() != Client::State::Live) c.connect(kServer);
        }
        CHECK(c.state() == Client::State::Live, "the login succeeds over the bad network (after %d ticks)", waited);
        const int32_t player = c.player();
        // the client sends its input for tick (server tick + 16), as a real client keeps a lead larger than the one-way delay; the server uses its inputs on every tick
        std::map<uint64_t, Input> sent;
        std::map<uint64_t, Input> used;
        std::map<uint64_t, std::vector<uint8_t>> snapshots_sent;
        uint64_t last_whole = 0; bool order_ok = true, bytes_ok = true; int wholes = 0;
        const uint64_t start = r.now;
        for (int i = 0; i < 900; i++) {
            const uint64_t t = r.now + 16;
            Input in; in.x = float((t * 37) % 21) / 10.0f - 1.0f; in.y = float((t * 11) % 3) - 1.0f; in.jump = (t % 7) == 0; in.interact = (t % 13) == 0;
            sent[t] = in;
            c.send_input(t, in);
            // the server simulates tick r.now: it takes this tick's inputs
            for (const PlayerInput& pi : r.server.inputs_for(r.now)) if (pi.player == player) used[r.now] = pi.in;
            if (r.now % 3 == 0) {       // a snapshot of 5 fragments every 3 ticks
                std::vector<uint8_t> bytes(kMaxFragment * 4 + 100);
                for (size_t k = 0; k < bytes.size(); k++) bytes[k] = uint8_t(k * 31 + r.now);
                const uint64_t base = r.server.players().at(player).acked;
                CHECK(r.server.send_snapshot(player, r.now, base, bytes), "send a snapshot at %llu", (unsigned long long)r.now);
                snapshots_sent[r.now] = bytes;
            }
            r.step();
            if (auto s = c.take_snapshot()) {
                wholes++;
                if (s->tick <= last_whole) order_ok = false;
                last_whole = s->tick;
                auto it = snapshots_sent.find(s->tick);
                if (it == snapshots_sent.end() || it->second != s->bytes) bytes_ok = false;
                c.acknowledge(s->tick);
                mix_u64(s->tick);
            }
        }
        int exact = 0, compared = 0;
        for (const auto& [t, in] : used) {
            if (t < start + 16) continue;       // before the first input the client sent for
            compared++;
            const Input& want = sent[t];
            if (want.x == in.x && want.y == in.y && want.jump == in.jump && want.interact == in.interact) exact++;
        }
        CHECK(compared > 800 && exact == compared, "the server used exactly the client's input on every tick: %d of %d (lost %llu of %llu datagrams)", exact, compared,
              (unsigned long long)r.net.lost(), (unsigned long long)r.net.sent());
        CHECK(r.net.lost() > r.net.sent() / 10, "the network did lose datagrams (%llu of %llu)", (unsigned long long)r.net.lost(), (unsigned long long)r.net.sent());
        CHECK(wholes > 20 && order_ok && bytes_ok, "whole snapshots arrive byte for byte and in order (%d whole, order %d, bytes %d; %llu fragments, %llu dropped)", wholes, order_ok, bytes_ok,
              (unsigned long long)c.stats().fragments, (unsigned long long)c.stats().fragments_dropped);
        const uint64_t acked = r.server.players().at(player).acked;
        CHECK(acked > 0 && acked <= last_whole && snapshots_sent.count(acked), "the server's baseline is a snapshot the client acknowledged: %llu (newest whole %llu)", (unsigned long long)acked, (unsigned long long)last_whole);
        std::printf("measured: %d whole snapshots of 5 fragments in 300 sent at 20%% loss; %llu inputs repeated by the server before the first arrived\n", wholes, (unsigned long long)r.server.stats().inputs_repeated);
        for (const auto& [t, in] : used) { mix_u64(t); mix(&in.x, 4); mix(&in.y, 4); }
    }

    // ---- E: attacks (a clean network, so each datagram's fate is the session's doing)
    {
        Rig r({1, 0, 0, 0, 5}, config());
        Client c(kGame, 120, key_of(120), Nonces{11});
        r.add(2, &c); c.connect(kServer); r.run(5);
        CHECK(c.state() == Client::State::Live, "live");
        c.send_input(r.now + 2, Input{});
        std::vector<Datagram> out = c.take_outbox();
        CHECK(out.size() == 1, "one INPUTS datagram");
        const uint64_t dropped0 = r.server.stats().dropped;
        r.server.receive(2, out[0].bytes.data(), out[0].bytes.size(), r.now);
        r.server.receive(2, out[0].bytes.data(), out[0].bytes.size(), r.now);
        CHECK(r.server.stats().dropped == dropped0 + 1, "the same datagram twice: the second is dropped (a replay)");
        r.server.receive(9, out[0].bytes.data(), out[0].bytes.size(), r.now);
        CHECK(r.server.stats().dropped == dropped0 + 2, "a valid datagram from another address is dropped");
        // inputs 100 ticks ahead and 50 behind, sent through the client so they carry its MAC
        c.send_input(r.now + 100, Input{}); for (Datagram& d : c.take_outbox()) r.server.receive(2, d.bytes.data(), d.bytes.size(), r.now);
        CHECK(r.server.stats().inputs_early >= 1, "an input 100 ticks ahead is dropped (early %llu)", (unsigned long long)r.server.stats().inputs_early);
        r.server.inputs_for(r.now + 1); r.server.inputs_for(r.now + 2);
        c.send_input(r.now + 1, Input{}); for (Datagram& d : c.take_outbox()) r.server.receive(2, d.bytes.data(), d.bytes.size(), r.now);      // tick now+1 was simulated with the last input
        CHECK(r.server.stats().inputs_past >= 1 && r.server.stats().inputs_late >= 1, "an input for a tick already simulated without it is dropped and counted late (past %llu, late %llu)",
              (unsigned long long)r.server.stats().inputs_past, (unsigned long long)r.server.stats().inputs_late);
        // a stranger refusing the client during a login: dropped
        Client d(kGame, 121, key_of(121), Nonces{12});
        r.add(3, &d); d.connect(kServer);
        Message ref; ref.type = Type::Refused; ref.reason = Refusal::Full; ref.text = "go away";
        std::vector<uint8_t> rb; encode(ref, nullptr, &rb);
        d.receive(66, rb.data(), rb.size());
        CHECK(d.state() == Client::State::Hello, "a refusal from another address during the login is ignored");
        r.run(5);
        CHECK(d.state() == Client::State::Live, "and the login goes on");
        Message ref2 = ref; ref2.connection = 999; encode(ref2, nullptr, &rb);
        d.receive(kServer, rb.data(), rb.size());
        CHECK(d.state() == Client::State::Live, "a refusal once live is ignored (unauthenticated)");
    }

    // ---- F: endings
    {
        Rig r({1, 0, 0, 0, 6}, config());
        Client a(kGame, 130, key_of(130), Nonces{21}), b(kGame, 131, key_of(131), Nonces{22}), c(kGame, 132, key_of(132), Nonces{23});
        r.add(2, &a); r.add(3, &b); r.add(4, &c);
        a.connect(kServer); b.connect(kServer); c.connect(kServer); r.run(5);
        r.server.take_events();
        a.leave(); r.run(3);
        auto ev = r.server.take_events();
        CHECK(ev.size() == 1 && ev[0].kind == Server::Event::Left && ev[0].player == 1 && ev[0].reason == Refusal::Left, "a client that leaves: left event for player 1");
        r.server.kick(2, "cheating"); r.run(3);
        ev = r.server.take_events();
        CHECK(b.state() == Client::State::Closed && b.refusal() == Refusal::Kicked && b.refusal_text() == "cheating" && ev.size() == 1 && ev[0].reason == Refusal::Kicked, "a kicked client is told why");
        // c stops sending: after 120 ticks of silence the server drops it and says so
        for (int i = 0; i < 130; i++) r.step();
        ev = r.server.take_events();
        CHECK(ev.size() == 1 && ev[0].player == 3 && ev[0].reason == Refusal::TimedOut && c.state() == Client::State::Closed && c.refusal() == Refusal::TimedOut, "a silent client is timed out and told (%zu events)", ev.size());
        CHECK(r.server.players().empty(), "no one left on the server");
        // a datagram of a closed connection is dropped
        Client e(kGame, 140, key_of(140), Nonces{31});
        r.add(5, &e); e.connect(kServer); r.run(8);
        CHECK(e.state() == Client::State::Live, "a fifth client logs in");
        e.send_input(r.now + 2, Input{}); std::vector<Datagram> o = e.take_outbox();
        e.leave(); r.run(3);
        const uint64_t dr = r.server.stats().dropped;
        if (!o.empty()) r.server.receive(5, o[0].bytes.data(), o[0].bytes.size(), r.now);
        CHECK(!o.empty() && r.server.stats().dropped == dr + 1, "an INPUTS datagram of a connection that has left is dropped");
        mix_u64(r.server.stats().sent_bytes);
    }

    std::printf("SESSION_HASH %016llx\n", (unsigned long long)g_hash);
    std::printf("session_test: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
