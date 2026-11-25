// The input of one fixed tick. x: -1 left .. +1 right, y: -1 back .. +1 forward (relative to the camera), look: -1 .. +1 turns the camera (+ right), look_y: -1 .. +1 pitches a first-person camera (+ up),
// run, jump, interact, attack, alt and menu are buttons (jump and interact act on the key going down, not on holding it; attack, alt and menu are for the game's scripts).
// Scenarios and the (future) platform layer both produce exactly this; the simulation never sees a key or a mouse (spec 18: deterministic input).
#pragma once
#include <cstdint>
#include <vector>
namespace celori {
struct Input { float x = 0, y = 0, look = 0, look_y = 0; bool run = false, jump = false, interact = false, attack = false, alt = false, menu = false; };
// E10: the input of one player other than player 0 for one tick. Lists of these are sorted by player, each player once, players 1 .. kMaxPlayers-1; a player without an entry has the neutral input.
struct PlayerInput { int32_t player = 0; Input in; };
// The input of player p (p >= 1) in a sorted list, or the neutral input.
inline const Input& input_of(const std::vector<PlayerInput>& list, int32_t p) {
    static const Input neutral{};
    size_t lo = 0, hi = list.size();
    while (lo < hi) { const size_t mid = (lo + hi) / 2; if (list[mid].player < p) lo = mid + 1; else hi = mid; }
    return (lo < list.size() && list[lo].player == p) ? list[lo].in : neutral;
}
}
