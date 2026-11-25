// E10 part 2: a simulated network for tests: datagrams between numbered endpoints, delivered after a seeded latency with jitter, some lost, some duplicated, some overtaking others.
// It is a simulation of the effects a real network has on datagrams, not of a real network (no bandwidth limits, no congestion, no path MTU); the gate's real-network checks use UDP
// (decisions/e10-networking-2026-11-25.md section 4). Deterministic: the same seed and the same traffic give the same deliveries on every target.
#pragma once
#include <algorithm>
#include <cstdint>
#include <vector>

#include "session.hpp"

namespace celori::net {

struct NetSimConfig {
    uint32_t latency_ticks = 3;          // one way
    uint32_t jitter_ticks = 0;           // + 0..jitter each datagram (so datagrams overtake one another)
    uint32_t loss_per_mille = 0;
    uint32_t duplicate_per_mille = 0;
    uint64_t seed = 1;
};

class NetSim {
public:
    explicit NetSim(NetSimConfig c) : cfg_(c), rng_(c.seed ? c.seed : 1) {}
    // A datagram from endpoint `from` to `to` (endpoints are Peer numbers; the receiver sees `from` as the peer it came from).
    void send(Peer from, Peer to, std::vector<uint8_t> bytes, uint64_t now) {
        sent_++;
        if (roll() < cfg_.loss_per_mille) { lost_++; return; }
        const int copies = roll() < cfg_.duplicate_per_mille ? 2 : 1;
        for (int c = 0; c < copies; c++) {
            const uint64_t at = now + cfg_.latency_ticks + (cfg_.jitter_ticks ? next() % (cfg_.jitter_ticks + 1) : 0);
            q_.push_back({at, order_++, from, to, bytes});
        }
        if (copies == 2) duplicated_++;
    }
    // The datagrams due at `now` for endpoint `to`, in arrival order (by due tick, then by when they were sent).
    std::vector<std::pair<Peer, std::vector<uint8_t>>> receive(Peer to, uint64_t now) {
        std::vector<Item> due;
        for (auto it = q_.begin(); it != q_.end();) { if (it->to == to && it->at <= now) { due.push_back(std::move(*it)); it = q_.erase(it); } else ++it; }
        std::sort(due.begin(), due.end(), [](const Item& a, const Item& b) { return a.at != b.at ? a.at < b.at : a.order < b.order; });
        std::vector<std::pair<Peer, std::vector<uint8_t>>> out;
        for (Item& i : due) { out.push_back({i.from, std::move(i.bytes)}); delivered_++; }
        return out;
    }
    void set(NetSimConfig c) { cfg_.latency_ticks = c.latency_ticks; cfg_.jitter_ticks = c.jitter_ticks; cfg_.loss_per_mille = c.loss_per_mille; cfg_.duplicate_per_mille = c.duplicate_per_mille; }
    uint64_t sent() const { return sent_; }
    uint64_t lost() const { return lost_; }
    uint64_t duplicated() const { return duplicated_; }
    uint64_t delivered() const { return delivered_; }

private:
    struct Item { uint64_t at, order; Peer from, to; std::vector<uint8_t> bytes; };
    uint64_t next() { rng_ ^= rng_ << 13; rng_ ^= rng_ >> 7; rng_ ^= rng_ << 17; return rng_; }
    uint32_t roll() { return uint32_t(next() % 1000); }
    NetSimConfig cfg_;
    uint64_t rng_;
    std::vector<Item> q_;
    uint64_t order_ = 0, sent_ = 0, lost_ = 0, duplicated_ = 0, delivered_ = 0;
};

}  // namespace celori::net
