#include "session.hpp"

#include <algorithm>

namespace celori::net {

// A 64-message sliding window over the sequence numbers of one connection's authenticated datagrams: a datagram seen before, or older than the window, is a replay (or hopelessly late) and is
// dropped. The MAC stops forgery; this stops an attacker who captured a valid datagram from sending it again (a LEAVE, say).
bool ReplayWindow::accept(uint32_t seq) {
    if (seq == 0) return false;
    if (seq > highest) {
        const uint32_t shift = seq - highest;
        bits = shift >= 64 ? 0 : bits << shift;
        bits |= 1;
        highest = seq;
        return true;
    }
    const uint32_t back = highest - seq;
    if (back >= 64) return false;
    const uint64_t bit = uint64_t(1) << back;
    if (bits & bit) return false;
    bits |= bit;
    return true;
}

// ================================================================================================ server
void Server::send(Peer to, const Message& m, const Key* session) {
    std::vector<uint8_t> b;
    if (!encode(m, session, &b)) return;
    stats_.sent++; stats_.sent_bytes += b.size();
    outbox_.push_back({to, std::move(b)});
}

void Server::refuse(Peer to, uint32_t connection, Refusal why, const std::string& text) {
    Message r; r.type = Type::Refused; r.connection = connection; r.reason = why; r.text = text.substr(0, kMaxReason);
    stats_.refused++;
    send(to, r, nullptr);
}

void Server::drop(int32_t player, Refusal why, bool tell) {
    auto it = live_.find(player);
    if (it == live_.end()) return;
    if (tell) { Message l; l.type = Type::Leave; l.connection = it->second.connection; l.sequence = ++it->second.sequence; l.reason = why; send(it->second.peer, l, &it->second.session); }
    by_connection_.erase(it->second.connection);
    events_.push_back({Event::Left, player, it->second.account, why});
    if (why == Refusal::TimedOut) stats_.timeouts++; else stats_.leaves++;
    live_.erase(it);
}

void Server::receive(Peer from, const uint8_t* data, size_t size, uint64_t now) {
    stats_.received++;
    Type type; uint32_t conn;
    if (from == 0 || !peek(data, size, &type, &conn)) { stats_.dropped++; return; }
    Message m; std::string err;
    switch (type) {
        case Type::Hello: {
            if (pending_.size() >= kMaxPending || !decode(data, size, nullptr, &m, &err)) { stats_.dropped++; return; }
            if (m.game != cfg_.game) { refuse(from, 0, Refusal::Game, "another build of the game"); return; }
            const std::optional<Key> key = cfg_.key_of ? cfg_.key_of(m.account) : std::nullopt;
            if (!key) { refuse(from, 0, Refusal::Account, "unknown account"); return; }
            for (const auto& [p, l] : live_) if (l.account == m.account) { refuse(from, 0, Refusal::Account, "this account is already playing"); return; }
            if (live_.size() >= cfg_.max_players) { refuse(from, 0, Refusal::Full, "the server is full"); return; }
            Pending p; p.peer = from; p.account = m.account; p.client = m.client_nonce; p.server = cfg_.nonce ? cfg_.nonce() : Nonce{}; p.key = *key; p.since = now;
            do { p.connection = next_connection_++; } while (p.connection == 0 || pending_.count(p.connection) || by_connection_.count(p.connection));
            pending_[p.connection] = p;
            Message c; c.type = Type::Challenge; c.connection = p.connection; c.server_nonce = p.server;
            send(from, c, nullptr);
            return;
        }
        case Type::Auth: {
            auto it = pending_.find(conn);
            if (it == pending_.end() || it->second.peer != from || !decode(data, size, nullptr, &m, &err)) { stats_.dropped++; return; }
            Pending p = it->second;
            pending_.erase(it);
            if (!mac_equal(m.proof, login_proof(p.key, p.client, p.server, p.connection))) { refuse(from, p.connection, Refusal::Auth, "the proof does not match the account's key"); return; }
            if (live_.size() >= cfg_.max_players) { refuse(from, p.connection, Refusal::Full, "the server is full"); return; }
            int32_t player = cfg_.first_player;
            while (live_.count(player)) player++;
            if (player >= kMaxPlayerNumbers) { refuse(from, p.connection, Refusal::Full, "no player number left"); return; }
            Live l; l.peer = from; l.connection = p.connection; l.account = p.account; l.player = player; l.session = session_key(p.key, p.client, p.server, p.connection);
            l.last_heard = now; l.used_through = now; l.newest_input = 0;
            live_[player] = l; by_connection_[p.connection] = player;
            Message w; w.type = Type::Welcome; w.connection = p.connection; w.sequence = ++live_[player].sequence; w.player = player; w.tick = now; w.tick_hz = cfg_.tick_hz;
            send(from, w, &live_[player].session);
            events_.push_back({Event::Joined, player, p.account});
            stats_.logins++;
            return;
        }
        case Type::Inputs: case Type::Leave: case Type::Ping: {
            auto bc = by_connection_.find(conn);
            if (bc == by_connection_.end()) { stats_.dropped++; return; }
            Live& l = live_[bc->second];
            if (l.peer != from || !decode(data, size, &l.session, &m, &err) || !l.replay.accept(m.sequence)) { stats_.dropped++; return; }
            l.last_heard = now;
            if (m.type == Type::Leave) { drop(l.player, Refusal::Left, false); return; }
            if (m.type == Type::Ping) { Message p; p.type = Type::Pong; p.connection = l.connection; p.sequence = ++l.sequence; p.stamp = m.stamp; send(from, p, &l.session); return; }
            if (m.ack > l.acked && m.ack <= l.newest_sent) l.acked = m.ack;          // an ack of a snapshot never sent is ignored
            for (size_t i = 0; i < m.inputs.size(); i++) {
                const uint64_t t = m.tick + i;
                if (t <= l.used_through) { if (!l.buffer.count(t)) stats_.inputs_late++; continue; }        // that tick is simulated already
                if (t > now + kInputBuffer) { stats_.inputs_early++; continue; }
                l.buffer.emplace(t, m.inputs[i]);
                if (t > l.newest_input) l.newest_input = t;
            }
            return;
        }
        default: stats_.dropped++; return;         // CHALLENGE, WELCOME, REFUSED, SNAPSHOT, PONG are the server's own types
    }
}

void Server::tick(uint64_t now) {
    for (auto it = pending_.begin(); it != pending_.end();) {
        if (now - it->second.since > cfg_.login_timeout_ticks) it = pending_.erase(it); else ++it;
    }
    std::vector<int32_t> silent;
    for (const auto& [p, l] : live_) if (now > l.last_heard && now - l.last_heard > cfg_.timeout_ticks) silent.push_back(p);
    for (int32_t p : silent) drop(p, Refusal::TimedOut, true);
}

std::vector<PlayerInput> Server::inputs_for(uint64_t t) {
    std::vector<PlayerInput> out;
    out.reserve(live_.size());
    for (auto& [p, l] : live_) {
        auto it = l.buffer.find(t);
        if (it != l.buffer.end()) l.last_used = it->second;
        else stats_.inputs_repeated++;
        l.buffer.erase(l.buffer.begin(), l.buffer.upper_bound(t));
        if (t > l.used_through) l.used_through = t;
        PlayerInput pi; pi.player = p; pi.in = l.last_used;
        out.push_back(pi);
    }
    return out;            // a std::map iterates in player order: sorted
}

bool Server::send_snapshot(int32_t player, uint64_t t, uint64_t baseline, const std::vector<uint8_t>& bytes) {
    auto it = live_.find(player);
    if (it == live_.end()) return false;
    Live& l = it->second;
    const size_t n = std::max<size_t>(1, (bytes.size() + kMaxFragment - 1) / kMaxFragment);
    if (n > kMaxFragments) return false;
    const uint32_t id = ++l.snapshots;
    for (size_t f = 0; f < n; f++) {
        Message m; m.type = Type::Snapshot; m.connection = l.connection; m.sequence = ++l.sequence; m.tick = t; m.snapshot = id; m.baseline = baseline; m.input_tick = l.used_through;
        m.fragment = uint16_t(f); m.fragments = uint16_t(n);
        const size_t a = f * kMaxFragment, b = std::min(bytes.size(), a + kMaxFragment);
        m.bytes.assign(bytes.begin() + long(a), bytes.begin() + long(b));
        send(l.peer, m, &l.session);
    }
    if (t > l.newest_sent) l.newest_sent = t;
    return true;
}

void Server::kick(int32_t player, const std::string& why) {
    auto it = live_.find(player);
    if (it == live_.end()) return;
    Message l; l.type = Type::Leave; l.connection = it->second.connection; l.sequence = ++it->second.sequence; l.reason = Refusal::Kicked; l.text = why.substr(0, kMaxReason);
    send(it->second.peer, l, &it->second.session);
    drop(player, Refusal::Kicked, false);
}

// ================================================================================================ client
void Client::send(const Message& m, bool authed) {
    std::vector<uint8_t> b;
    if (!encode(m, authed ? &session_ : nullptr, &b)) return;
    stats_.sent++; stats_.sent_bytes += b.size();
    outbox_.push_back({server_, std::move(b)});
}

void Client::connect(Peer server) {
    server_ = server; state_ = State::Hello; player_ = -1; connection_ = 0; sequence_ = 0; recent_.clear(); ack_ = 0; newest_whole_ = 0; assembling_.clear(); ready_.reset(); replay_ = ReplayWindow{};
    client_nonce_ = nonce_ ? nonce_() : Nonce{};
    Message h; h.type = Type::Hello; h.game = game_; h.account = account_; h.client_nonce = client_nonce_;
    send(h, false);
}

void Client::receive(Peer from, const uint8_t* data, size_t size) {
    stats_.received++;
    Type type; uint32_t conn;
    if (from != server_ || !peek(data, size, &type, &conn)) { stats_.dropped++; return; }
    Message m; std::string err;
    switch (type) {
        case Type::Challenge: {
            if (state_ != State::Hello || !decode(data, size, nullptr, &m, &err) || m.connection == 0) { stats_.dropped++; return; }
            connection_ = m.connection;
            session_ = session_key(key_, client_nonce_, m.server_nonce, connection_);
            Message a; a.type = Type::Auth; a.connection = connection_; a.proof = login_proof(key_, client_nonce_, m.server_nonce, connection_);
            send(a, false);
            state_ = State::Authenticating;
            return;
        }
        case Type::Refused: {
            // unauthenticated, so honoured only during the login, and only for this login's connection (or a refusal of the HELLO itself)
            if ((state_ != State::Hello && state_ != State::Authenticating) || !decode(data, size, nullptr, &m, &err) || (m.connection != 0 && m.connection != connection_)) { stats_.dropped++; return; }
            refusal_ = m.reason; refusal_text_ = m.text; state_ = State::Refused;
            return;
        }
        case Type::Welcome: {
            if (state_ != State::Authenticating || conn != connection_ || !decode(data, size, &session_, &m, &err) || !replay_.accept(m.sequence)) { stats_.dropped++; return; }
            if (m.player < 0 || m.player >= kMaxPlayerNumbers) { stats_.dropped++; return; }
            player_ = m.player; welcome_tick_ = m.tick; tick_hz_ = m.tick_hz; state_ = State::Live;
            return;
        }
        case Type::Snapshot: {
            if (state_ != State::Live || conn != connection_ || !decode(data, size, &session_, &m, &err) || !replay_.accept(m.sequence)) { stats_.dropped++; return; }
            stats_.fragments++;
            if (m.tick <= newest_whole_) { stats_.fragments_dropped++; return; }          // older than what the client has whole
            auto it = assembling_.find(m.snapshot);
            if (it == assembling_.end()) {
                if (assembling_.size() >= kAssemblies) {                                   // give up the oldest for this newer one (or drop this one if it is the oldest)
                    auto oldest = assembling_.begin();
                    if (oldest->first > m.snapshot) { stats_.fragments_dropped++; return; }
                    stats_.fragments_dropped += oldest->second.have;
                    assembling_.erase(oldest);
                }
                Assembly a; a.tick = m.tick; a.baseline = m.baseline; a.input_tick = m.input_tick; a.count = m.fragments; a.parts.assign(m.fragments, {}); a.got.assign(m.fragments, false);
                it = assembling_.emplace(m.snapshot, std::move(a)).first;
            }
            Assembly& a = it->second;
            if (m.tick != a.tick || m.fragments != a.count || m.baseline != a.baseline || a.got[m.fragment]) { stats_.fragments_dropped++; return; }     // a duplicate, or one that does not fit its snapshot
            a.bytes += m.bytes.size();
            a.parts[m.fragment] = std::move(m.bytes); a.got[m.fragment] = true; a.have++;
            if (a.have == a.count) {
                Snapshot s; s.tick = a.tick; s.baseline = a.baseline; s.input_tick = a.input_tick;
                s.bytes.reserve(a.bytes);
                for (const auto& part : a.parts) s.bytes.insert(s.bytes.end(), part.begin(), part.end());
                ready_ = std::move(s); newest_whole_ = a.tick; stats_.snapshots++;
                for (auto j = assembling_.begin(); j != assembling_.end();) {             // everything not newer than this one is of no use now
                    if (j->second.tick <= newest_whole_) { if (j->second.have != j->second.count) stats_.fragments_dropped += j->second.have; j = assembling_.erase(j); } else ++j;
                }
            }
            return;
        }
        case Type::Leave: {
            if (state_ != State::Live || conn != connection_ || !decode(data, size, &session_, &m, &err) || !replay_.accept(m.sequence)) { stats_.dropped++; return; }
            refusal_ = m.reason; refusal_text_ = m.text; state_ = State::Closed;
            return;
        }
        case Type::Pong: {
            if (state_ != State::Live || conn != connection_ || !decode(data, size, &session_, &m, &err) || !replay_.accept(m.sequence)) { stats_.dropped++; return; }
            return;
        }
        default: stats_.dropped++; return;
    }
}

void Client::send_input(uint64_t t, const Input& in) {
    if (state_ != State::Live) return;
    if (!recent_.empty() && recent_.back().first + 1 != t) recent_.clear();       // only consecutive ticks travel together
    recent_.push_back({t, in});
    while (recent_.size() > kInputsPerMessage) recent_.pop_front();
    Message m; m.type = Type::Inputs; m.connection = connection_; m.sequence = ++sequence_; m.ack = ack_; m.tick = recent_.front().first;
    for (const auto& r : recent_) m.inputs.push_back(r.second);
    send(m, true);
}

void Client::leave() {
    if (state_ != State::Live) { state_ = State::Closed; return; }
    Message l; l.type = Type::Leave; l.connection = connection_; l.sequence = ++sequence_; l.reason = Refusal::Left;
    send(l, true);
    state_ = State::Closed;
}

}  // namespace celori::net
