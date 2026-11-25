// E10 part 2: the wire format between a Celori server and its clients (decisions/e10-networking-2026-11-25.md section 6). One message per UDP datagram, at most kMaxDatagram bytes, little-endian:
//
//   magic u32 'CLRN' | version u16 | type u8 | connection u32 | sequence u32 | body ... | mac[16] (only on the types after the login, below)
//
// The login is a challenge-response under the player's key, which never crosses the network: HELLO (game build, account, client nonce) -> CHALLENGE (server nonce; the connection number in the
// header) -> AUTH (a MAC of both nonces and the connection under the player's key) -> WELCOME (the player number, the server's tick; MAC'd with the session key, so the client knows the server has
// the key too). From WELCOME on every message carries a 16-byte keyed-BLAKE2b MAC under the session key (derived from the player's key and both nonces): a datagram from anyone else is dropped.
// decode() checks everything before anything is used: the size, the magic, the version, the type, the exact length of the body, every count against its limit, every input value finite and in
// range, and (for the authenticated types) the MAC. It never reads past the datagram and allocates at most the datagram's size.
#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <vector>

#include "../gameplay/input.hpp"

namespace celori::net {

constexpr uint32_t kMagic = 0x4e524c43u;          // "CLRN" read as little-endian bytes C L R N
constexpr uint16_t kProtocolVersion = 1;
constexpr size_t kMaxDatagram = 1200;             // policy: below every common path MTU (IPv6's minimum is 1280), so a datagram is never fragmented by IP
constexpr size_t kHeaderSize = 4 + 2 + 1 + 4 + 4;
constexpr size_t kMacSize = 16;
constexpr size_t kNonceSize = 16;
constexpr size_t kKeySize = 32;
constexpr uint32_t kMaxInputsPerMessage = 16;     // policy: a client repeats its last ticks' inputs so a lost datagram costs nothing
constexpr size_t kSnapshotFields = 8 + 4 + 8 + 8 + 2 + 2 + 2;                                    // tick, snapshot, baseline, input tick, fragment, fragments, length
constexpr size_t kMaxFragment = kMaxDatagram - kHeaderSize - kMacSize - kSnapshotFields;            // the bytes of a snapshot one datagram carries
constexpr uint16_t kMaxFragments = 1024;          // policy: a snapshot of at most ~1.1 MB
constexpr size_t kMaxReason = 200;
constexpr int32_t kMaxPlayerNumbers = 4096;       // = kMaxPlayers of scene/components.hpp (asserted where both are seen: runtime/simulation.cpp); kept here so the network code needs no scene headers

enum class Type : uint8_t { Hello = 1, Challenge = 2, Auth = 3, Welcome = 4, Refused = 5, Inputs = 6, Snapshot = 7, Leave = 8, Ping = 9, Pong = 10 };
enum class Refusal : uint8_t { Version = 1, Game = 2, Account = 3, Auth = 4, Full = 5, Protocol = 6, TimedOut = 7, Left = 8, Kicked = 9 };
const char* refusal_name(Refusal r);
bool authenticated(Type t);       // the types that carry a session MAC (WELCOME and everything after the login)

using Key = std::array<uint8_t, kKeySize>;
using Nonce = std::array<uint8_t, kNonceSize>;
using Mac = std::array<uint8_t, kMacSize>;

struct Message {
    Type type = Type::Ping;
    uint32_t connection = 0, sequence = 0;
    // HELLO
    uint64_t game = 0;            // a hash of the game build and its data: a client of another build is refused
    uint32_t account = 0;         // whose key the server looks up
    Nonce client_nonce{};
    // CHALLENGE
    Nonce server_nonce{};
    // AUTH
    Mac proof{};
    // WELCOME
    int32_t player = 0;
    uint64_t tick = 0;            // WELCOME: the server's tick; INPUTS: the tick of the first input; SNAPSHOT: the tick of the state
    uint16_t tick_hz = 60;
    // REFUSED, LEAVE
    Refusal reason = Refusal::Protocol;
    std::string text;
    // INPUTS
    uint64_t ack = 0;             // the newest snapshot tick the client has whole
    std::vector<Input> inputs;    // inputs[i] is the client's input for tick (tick + i)
    // SNAPSHOT (one fragment)
    uint32_t snapshot = 0;        // the snapshot's number on this connection
    uint64_t baseline = 0;        // the snapshot tick the delta is against (0: none, a full state)
    uint64_t input_tick = 0;      // the newest tick of this client's input the server has used
    uint16_t fragment = 0, fragments = 1;
    std::vector<uint8_t> bytes;
    // PING, PONG
    uint64_t stamp = 0;
};

// The MACs and keys of the login (keyed BLAKE2b, Monocypher). proof = MAC(player key, "celori-auth" | client nonce | server nonce | connection); the session key = BLAKE2b-256 keyed with the
// player's key over "celori-session" | client nonce | server nonce | connection.
Mac login_proof(const Key& player_key, const Nonce& client, const Nonce& server, uint32_t connection);
Key session_key(const Key& player_key, const Nonce& client, const Nonce& server, uint32_t connection);
bool mac_equal(const Mac& a, const Mac& b);       // constant time

// Encodes a message (with the session MAC when the type is authenticated; `session` must then be given). Returns false (nothing written) if the message breaks a limit (too many inputs, a fragment
// too large, a reason too long, an input value out of range).
bool encode(const Message& m, const Key* session, std::vector<uint8_t>* out, std::string* error = nullptr);
// Decodes one datagram. An authenticated type is accepted only with a session key whose MAC matches; false + a reason for anything else (the reason is for logs, never sent back as is).
bool decode(const uint8_t* data, size_t size, const Key* session, Message* out, std::string* error);
// The type and connection of a datagram whose header is well formed, before its MAC can be checked (a server looks up the connection's session key with it). false for anything that is not a Celori
// datagram of this version.
bool peek(const uint8_t* data, size_t size, Type* type, uint32_t* connection);

}  // namespace celori::net
