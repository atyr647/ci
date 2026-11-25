// E10 part 2: the server and client sessions (net/session.cpp) over REAL UDP sockets of the operating system, natively, for the cross-OS check (atyr647/ci workflow celori-net) and for
// network namespaces with netem delay and loss on Linux. The game's simulation is not involved: this measures what the network does to the sessions.
//   udp_session server PORT TICKS CLIENTS          serves TICKS ticks (60 Hz wall clock) on 0.0.0.0:PORT; prints one JSON line of what it measured; exit 0 when every client that joined used all
//                                                  of its inputs and got snapshots
//   udp_session client HOST PORT TICKS ACCOUNT     joins, sends an input every tick (its own deterministic pattern) for TICKS ticks, acknowledges whole snapshots, leaves; prints one JSON line
//   udp_session both TICKS CLIENTS                 a server and CLIENTS clients in one process over 127.0.0.1 (loopback): the quick check
// Every input a client sends is a pattern of (account, tick); the server checks the input it used for each tick against the same pattern, so the check needs no channel besides the network.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#define NOMINMAX          // windows.h's min and max macros break std::max
#include <winsock2.h>
#include <ws2tcpip.h>
using socklen_t = int;
static void sock_init() { WSADATA d; WSAStartup(MAKEWORD(2, 2), &d); }
static void set_nonblocking(SOCKET s) { u_long one = 1; ioctlsocket(s, FIONBIO, &one); }
using Sock = SOCKET;
static const Sock kBad = INVALID_SOCKET;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
static void sock_init() {}
static void set_nonblocking(int s) { fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK); }
using Sock = int;
static const Sock kBad = -1;
#endif

#include "../src/net/session.hpp"

using namespace celori;
using namespace celori::net;

namespace {
constexpr uint64_t kGame = 0x5EED;
Key key_of(uint32_t account) { Key k{}; for (size_t i = 0; i < k.size(); i++) k[i] = uint8_t(account * 13 + i * 7 + 1); return k; }
Nonce fresh_nonce() {
    static uint64_t s = uint64_t(std::chrono::steady_clock::now().time_since_epoch().count()) | 1;
    Nonce n{}; for (auto& b : n) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; b = uint8_t(s); }
    return n;
}
Input pattern(uint32_t account, uint64_t t) {
    Input i; i.x = float(int((t * 7 + account) % 21) - 10) / 10.0f; i.y = float(int((t * 3 + account) % 3) - 1); i.jump = (t + account) % 11 == 0; i.interact = (t + account) % 17 == 0;
    return i;
}
bool same(const Input& a, const Input& b) { return a.x == b.x && a.y == b.y && a.jump == b.jump && a.interact == b.interact; }

struct Udp {
    Sock s = kBad;
    std::map<std::string, Peer> peer_of; std::vector<sockaddr_in> addr_of;
    bool open(uint16_t port) {
        s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s == kBad) return false;
        sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(s, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0) return false;
        set_nonblocking(s);
        return true;
    }
    Peer peer(const sockaddr_in& a) {
        char key[64]; std::snprintf(key, sizeof key, "%u:%u", unsigned(a.sin_addr.s_addr), unsigned(a.sin_port));
        auto it = peer_of.find(key);
        if (it != peer_of.end()) return it->second;
        addr_of.push_back(a);
        return peer_of[key] = Peer(addr_of.size());
    }
    Peer named(const char* host, uint16_t port) { sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(port); inet_pton(AF_INET, host, &a.sin_addr); return peer(a); }
    void send(Peer p, const std::vector<uint8_t>& b) {
        if (p == 0 || p > addr_of.size()) return;
        sendto(s, reinterpret_cast<const char*>(b.data()), int(b.size()), 0, reinterpret_cast<const sockaddr*>(&addr_of[p - 1]), sizeof(sockaddr_in));
    }
    template <class F> void receive(F&& f) {
        uint8_t buf[kMaxDatagram + 1];
        for (int i = 0; i < 4096; i++) {
            sockaddr_in from{}; socklen_t fl = sizeof from;
            const auto n = recvfrom(s, reinterpret_cast<char*>(buf), int(sizeof buf), 0, reinterpret_cast<sockaddr*>(&from), &fl);
            if (n < 0) {
#ifdef _WIN32
                if (WSAGetLastError() == WSAECONNRESET) continue;       // an ICMP error of an earlier send: read on
#endif
                break;
            }
            if (size_t(n) > kMaxDatagram) continue;
            f(peer(from), buf, size_t(n));
        }
    }
};

struct Pacer {
    std::chrono::steady_clock::time_point next = std::chrono::steady_clock::now();
    void wait() { next += std::chrono::microseconds(16667); std::this_thread::sleep_until(next); }
};

struct ServerRun {
    Udp udp; std::optional<Server> server; uint64_t tick = 1;
    std::map<int32_t, uint32_t> account_of; std::map<int32_t, uint64_t> exact, compared, first_input; std::map<int32_t, std::vector<uint64_t>> wrong;
    bool start(uint16_t port, uint32_t clients) {
        ServerConfig c; c.game = kGame; c.max_players = clients; c.timeout_ticks = 600;
        c.key_of = [](uint32_t a) -> std::optional<Key> { return key_of(a); };
        c.nonce = fresh_nonce;
        server.emplace(std::move(c));
        return udp.open(port);
    }
    void step() {
        udp.receive([&](Peer p, const uint8_t* d, size_t n) { server->receive(p, d, n, tick); });
        server->tick(tick);
        for (const auto& e : server->take_events()) if (e.kind == Server::Event::Joined) account_of[e.player] = e.account;
        for (const PlayerInput& pi : server->inputs_for(tick)) {
            const auto& l = server->players().at(pi.player);
            if (l.newest_input == 0) continue;                         // nothing received yet
            if (!first_input.count(pi.player)) first_input[pi.player] = l.newest_input;
            if (tick < first_input[pi.player] + 2) continue;           // the client's first ticks may precede its first datagram
            compared[pi.player]++;
            if (same(pi.in, pattern(account_of[pi.player], tick))) exact[pi.player]++;
            else if (wrong[pi.player].size() < 12) wrong[pi.player].push_back(tick - first_input[pi.player]);
        }
        if (tick % 3 == 0)
            for (const auto& [p, l] : server->players()) {
                std::vector<uint8_t> bytes(kMaxFragment * 2 + 300);
                for (size_t k = 0; k < bytes.size(); k++) bytes[k] = uint8_t(k + tick);
                server->send_snapshot(p, tick, l.acked, bytes);
            }
        for (const Datagram& d : server->take_outbox()) udp.send(d.peer, d.bytes);
        tick++;
    }
};

struct ClientRun {
    Udp udp; std::optional<Client> client; Peer server_peer = 0; uint32_t account = 0; uint64_t tick = 0, est = 0, snapshots = 0, bad_snapshots = 0, sent = 0;
    bool start(const char* host, uint16_t port, uint32_t acc) {
        account = acc;
        client.emplace(kGame, acc, key_of(acc), fresh_nonce);
        if (!udp.open(0)) return false;
        server_peer = udp.named(host, port);
        client->connect(server_peer);
        return true;
    }
    // One tick of the client. `server_tick` is the server's tick when the caller knows it (the in-process run), else 0: the client then counts from the server's tick in WELCOME.
    void step(uint64_t server_tick) {
        udp.receive([&](Peer p, const uint8_t* d, size_t n) { client->receive(p, d, n); });
        if (client->state() == Client::State::Live) {
            est = server_tick ? server_tick : (est ? est + 1 : client->server_tick_at_welcome());
            tick = std::max(tick + 1, est + 12);                           // a lead of 12 ticks (200 ms) over the server; never back, never a gap
            client->send_input(tick, pattern(account, tick)); sent++;
            while (auto s = client->take_snapshot()) {
                snapshots++;
                bool ok = true;
                for (size_t k = 0; k < s->bytes.size(); k++) if (s->bytes[k] != uint8_t(k + s->tick)) { ok = false; break; }
                if (!ok) bad_snapshots++;
                client->acknowledge(s->tick);
            }
        }
        for (const Datagram& d : client->take_outbox()) udp.send(d.peer, d.bytes);
    }
};
}  // namespace

int main(int argc, char** argv) {
    sock_init();
    const std::string mode = argc > 1 ? argv[1] : "";
    if (mode == "server" && argc == 5) {
        ServerRun s; if (!s.start(uint16_t(std::atoi(argv[2])), uint32_t(std::atoi(argv[4])))) { std::printf("{\"ok\":false,\"error\":\"cannot bind\"}\n"); return 2; }
        const uint64_t ticks = uint64_t(std::atoll(argv[3]));
        Pacer pace;
        for (uint64_t i = 0; i < ticks; i++) { s.step(); pace.wait(); }
        bool ok = !s.compared.empty();
        std::string per;
        for (const auto& [p, n] : s.compared) {
            std::string w; for (uint64_t t : s.wrong[p]) w += (w.empty() ? "" : ",") + std::to_string(t);
            per += (per.empty() ? "" : ",") + std::string("{\"player\":") + std::to_string(p) + ",\"compared\":" + std::to_string(n) + ",\"exact\":" + std::to_string(s.exact[p]) + ",\"wrong_at\":[" + w + "]}";
            if (s.exact[p] != n || n < ticks / 2) ok = false;
        }
        const ServerStats& st = s.server->stats();
        std::printf("{\"ok\":%s,\"role\":\"server\",\"players\":[%s],\"logins\":%llu,\"received\":%llu,\"dropped\":%llu,\"inputs_repeated\":%llu,\"inputs_late\":%llu,\"inputs_past\":%llu,\"sent\":%llu}\n", ok ? "true" : "false", per.c_str(),
                    (unsigned long long)st.logins, (unsigned long long)st.received, (unsigned long long)st.dropped, (unsigned long long)st.inputs_repeated, (unsigned long long)st.inputs_late, (unsigned long long)st.inputs_past, (unsigned long long)st.sent);
        return ok ? 0 : 1;
    }
    if (mode == "client" && argc == 6) {
        ClientRun c; if (!c.start(argv[2], uint16_t(std::atoi(argv[3])), uint32_t(std::atoi(argv[5])))) { std::printf("{\"ok\":false,\"error\":\"cannot open\"}\n"); return 2; }
        const uint64_t ticks = uint64_t(std::atoll(argv[4]));
        Pacer pace;
        for (uint64_t i = 0; i < ticks; i++) {
            c.step(0);
            if (i % 60 == 59 && c.client->state() != Client::State::Live) c.client->connect(c.server_peer);       // a lost login: try again every second
            pace.wait();
        }
        const bool live = c.client->state() == Client::State::Live;
        c.client->leave(); for (const Datagram& d : c.client->take_outbox()) c.udp.send(d.peer, d.bytes);
        const bool ok = live && c.snapshots > 0 && c.bad_snapshots == 0;
        std::printf("{\"ok\":%s,\"role\":\"client\",\"account\":%u,\"player\":%d,\"sent\":%llu,\"snapshots\":%llu,\"bad_snapshots\":%llu,\"fragments\":%llu,\"fragments_dropped\":%llu}\n", ok ? "true" : "false", c.account, c.client->player(),
                    (unsigned long long)c.sent, (unsigned long long)c.snapshots, (unsigned long long)c.bad_snapshots, (unsigned long long)c.client->stats().fragments, (unsigned long long)c.client->stats().fragments_dropped);
        return ok ? 0 : 1;
    }
    if (mode == "both" && argc == 4) {
        const uint64_t ticks = uint64_t(std::atoll(argv[2])); const uint32_t n = uint32_t(std::atoi(argv[3]));
        ServerRun s; if (!s.start(0, n)) { std::printf("{\"ok\":false,\"error\":\"cannot bind\"}\n"); return 2; }
        sockaddr_in a{}; socklen_t al = sizeof a; getsockname(s.udp.s, reinterpret_cast<sockaddr*>(&a), &al);
        std::vector<ClientRun> cs(n);
        for (uint32_t i = 0; i < n; i++) cs[i].start("127.0.0.1", ntohs(a.sin_port), 100 + i);
        Pacer pace;
        for (uint64_t t = 0; t < ticks; t++) { s.step(); for (ClientRun& c : cs) c.step(s.tick); pace.wait(); }
        bool ok = s.compared.size() == n;
        for (const auto& [p, cnt] : s.compared) if (s.exact[p] != cnt || cnt < ticks / 2) ok = false;
        for (const ClientRun& c : cs) if (c.snapshots == 0 || c.bad_snapshots) ok = false;
        std::printf("{\"ok\":%s,\"role\":\"both\",\"clients\":%u,\"server_logins\":%llu,\"inputs_repeated\":%llu", ok ? "true" : "false", n, (unsigned long long)s.server->stats().logins, (unsigned long long)s.server->stats().inputs_repeated);
        for (const auto& [p, cnt] : s.compared) std::printf(",\"p%d\":[%llu,%llu]", p, (unsigned long long)s.exact[p], (unsigned long long)cnt);
        for (const ClientRun& c : cs) std::printf(",\"c%u_snapshots\":%llu", c.account, (unsigned long long)c.snapshots);
        std::printf("}\n");
        return ok ? 0 : 1;
    }
    std::printf("usage: udp_session server PORT TICKS CLIENTS | client HOST PORT TICKS ACCOUNT | both TICKS CLIENTS\n");
    return 2;
}
