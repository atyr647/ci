// E10 part 2: the server's and the client's side of a connection, as state machines over datagrams (decisions/e10-networking-2026-11-25.md section 6). No sockets and no clock: the owner hands
// in each datagram with the peer it came from and the current tick, and sends what the outbox holds. The same code runs over the simulated network (net/netsim.hpp, the tests) and over UDP
// through the host (celori:net).
//
// Server: HELLO -> CHALLENGE (a pending connection, at most kMaxPending) -> AUTH checked against the account's key -> WELCOME (a player number) -> live. A live connection sends INPUTS (its last
// ticks, repeated) and receives SNAPSHOTs; it ends with LEAVE, or after `timeout_ticks` without a valid datagram. Everything that is not right is dropped, counted, and (for a login that fails)
// answered with REFUSED.
// Client: connect() sends HELLO; CHALLENGE -> AUTH; WELCOME -> live (the player number, the server's tick). It sends its inputs every tick (the last kInputsPerMessage, so a lost datagram costs
// nothing) with the newest snapshot it has whole, and reassembles SNAPSHOT fragments (up to four snapshots at once, so fragments that overtake one another still complete; a snapshot older
// than the newest whole one is dropped).
#pragma once
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "protocol.hpp"

namespace celori::net {

// 64 messages of one connection: a sequence number seen before, or more than 63 behind the highest, is refused (a replayed or hopelessly late datagram).
struct ReplayWindow { uint32_t highest = 0; uint64_t bits = 0; bool accept(uint32_t seq); };

using Peer = uint64_t;            // the transport's handle for an address (an index into its table of addresses; 0 is never a peer)
struct Datagram { Peer peer = 0; std::vector<uint8_t> bytes; };

constexpr uint32_t kMaxPending = 64;              // policy: logins in progress at once (more HELLOs are dropped until one finishes or times out)
constexpr uint32_t kInputsPerMessage = 8;         // a client repeats its last 8 ticks of input in each message
constexpr uint32_t kLeaveCopies = kInputsPerMessage;   // a LEAVE (leave, kick, time-out notice) goes out in this many datagrams: a lost one would leave a player in the game
                                                       // until the time-out (found on the CI netem run, 2026-11-25); the same redundancy inputs have
constexpr uint32_t kInputBuffer = 64;             // the server keeps a player's inputs at most 64 ticks ahead of its tick (a client further ahead is wrong: dropped)

struct ServerConfig {
    uint64_t game = 0;                            // the hash of the game build; a HELLO with another is refused (Refusal::Game)
    uint16_t tick_hz = 60;
    uint32_t max_players = 16;                    // live connections at most
    uint32_t timeout_ticks = 600;                 // a live connection silent this long is dropped (10 s at 60 Hz)
    uint32_t login_timeout_ticks = 300;           // a pending login this old is forgotten
    int32_t first_player = 1;                     // player numbers are given from here up (0 is the host's own player in a game that also plays on the server)
    std::function<std::optional<Key>(uint32_t account)> key_of;     // the account's key, or nothing (Refusal::Account)
    std::function<Nonce()> nonce;                 // fresh server nonces (the host's random source; tests give a seeded one)
};

// inputs_repeated: ticks a player's input had not arrived for (the last one was used); inputs_late: of those, inputs that arrived afterwards (too late to be used); inputs_past: every copy of an
// input for a tick already simulated (a client repeats each input in several messages, so most copies are expected to be past); inputs_early: inputs too far ahead (dropped)
struct ServerStats { uint64_t received = 0, dropped = 0, refused = 0, logins = 0, leaves = 0, timeouts = 0, inputs_late = 0, inputs_past = 0, inputs_repeated = 0, inputs_early = 0, sent = 0, sent_bytes = 0; };

class Server {
public:
    explicit Server(ServerConfig config) : cfg_(std::move(config)) {}
    // A datagram from `from` at server tick `now`.
    void receive(Peer from, const uint8_t* data, size_t size, uint64_t now);
    // Ends logins and connections that are too old. Call once per tick.
    void tick(uint64_t now);
    // The inputs of every live player for tick `t` (sorted by player): the input it sent for t, or (late or lost) the last one used for it. Call once per tick, in tick order.
    std::vector<PlayerInput> inputs_for(uint64_t t);
    // Sends a snapshot of tick `t` to a player (split into fragments). `baseline` is the tick the bytes are a delta against (0: a full state).
    bool send_snapshot(int32_t player, uint64_t t, uint64_t baseline, const std::vector<uint8_t>& bytes);
    // Drops a player (Refusal::Kicked), telling it.
    void kick(int32_t player, const std::string& why);

    struct Event { enum Kind { Joined, Left } kind; int32_t player; uint32_t account; Refusal reason = Refusal::Left; };
    std::vector<Event> take_events() { std::vector<Event> e; e.swap(events_); return e; }
    std::vector<Datagram> take_outbox() { std::vector<Datagram> o; o.swap(outbox_); return o; }

    // What the server knows of a live player: the newest snapshot tick it has acknowledged (the baseline of the next delta), the newest input tick received, its account.
    struct Live { Peer peer = 0; uint32_t connection = 0; uint32_t account = 0; int32_t player = 0; Key session{}; uint64_t last_heard = 0; uint64_t acked = 0;
                  uint64_t newest_input = 0; uint64_t used_through = 0; uint64_t newest_sent = 0; uint32_t sequence = 0; uint32_t snapshots = 0; Input last_used; std::map<uint64_t, Input> buffer;
                  ReplayWindow replay; std::deque<uint64_t> repeated; };      // repeated: the last ticks (at most kInputBuffer) whose input was missing when simulated
    const std::map<int32_t, Live>& players() const { return live_; }
    const ServerStats& stats() const { return stats_; }

private:
    struct Pending { Peer peer; uint32_t connection; uint32_t account; Nonce client, server; Key key; uint64_t since; };
    void send(Peer to, const Message& m, const Key* session);
    void refuse(Peer to, uint32_t connection, Refusal why, const std::string& text);
    void drop(int32_t player, Refusal why, bool tell);
    ServerConfig cfg_;
    std::map<uint32_t, Pending> pending_;          // by connection number
    std::map<int32_t, Live> live_;                 // by player number
    std::map<uint32_t, int32_t> by_connection_;    // live connection number -> player
    uint32_t next_connection_ = 1;
    std::vector<Event> events_;
    std::vector<Datagram> outbox_;
    ServerStats stats_;
};

struct ClientStats { uint64_t received = 0, dropped = 0, sent = 0, sent_bytes = 0, snapshots = 0, fragments = 0, fragments_dropped = 0; };

class Client {
public:
    enum class State { Idle, Hello, Authenticating, Live, Refused, Closed };
    Client(uint64_t game, uint32_t account, Key key, std::function<Nonce()> nonce) : game_(game), account_(account), key_(key), nonce_(std::move(nonce)) {}
    void connect(Peer server);
    void receive(Peer from, const uint8_t* data, size_t size);
    // This tick's input for tick `t` (the client's own tick, ahead of the server's): kept and sent with the ones before it.
    void send_input(uint64_t t, const Input& in);
    void leave();
    State state() const { return state_; }
    int32_t player() const { return player_; }
    uint64_t server_tick_at_welcome() const { return welcome_tick_; }
    uint16_t tick_hz() const { return tick_hz_; }
    Refusal refusal() const { return refusal_; }
    const std::string& refusal_text() const { return refusal_text_; }
    // A snapshot that arrived whole since the last call (the newest only), or nothing.
    struct Snapshot { uint64_t tick = 0, baseline = 0, input_tick = 0; std::vector<uint8_t> bytes; };
    std::optional<Snapshot> take_snapshot() { std::optional<Snapshot> s; s.swap(ready_); return s; }
    // The newest snapshot tick the client has applied: sent back as the ack, the server's next baseline.
    void acknowledge(uint64_t tick) { if (tick > ack_) ack_ = tick; }
    std::vector<Datagram> take_outbox() { std::vector<Datagram> o; o.swap(outbox_); return o; }
    const ClientStats& stats() const { return stats_; }

private:
    void send(const Message& m, bool authed);
    uint64_t game_; uint32_t account_; Key key_; std::function<Nonce()> nonce_;
    State state_ = State::Idle;
    Peer server_ = 0; uint32_t connection_ = 0; uint32_t sequence_ = 0;
    Nonce client_nonce_{}; Key session_{};
    int32_t player_ = -1; uint64_t welcome_tick_ = 0; uint16_t tick_hz_ = 60;
    Refusal refusal_ = Refusal::Protocol; std::string refusal_text_;
    std::deque<std::pair<uint64_t, Input>> recent_;      // the last kInputsPerMessage ticks' inputs, oldest first
    uint64_t ack_ = 0;
    // the snapshot being reassembled
    // snapshots being reassembled, by number: at most kAssemblies at once (the oldest is given up for a newer one); a whole one newer than the newest whole so far is handed out
    struct Assembly { uint64_t tick = 0, baseline = 0, input_tick = 0; uint16_t count = 0, have = 0; std::vector<std::vector<uint8_t>> parts; std::vector<bool> got; size_t bytes = 0; };
    static constexpr size_t kAssemblies = 4;
    std::map<uint32_t, Assembly> assembling_;
    ReplayWindow replay_;
    uint64_t newest_whole_ = 0;
    std::optional<Snapshot> ready_;
    std::vector<Datagram> outbox_;
    ClientStats stats_;
};

}  // namespace celori::net
