/* Integer kernels shared by the stress guest (compiled to wasm) and the stress host (compiled natively by Cosmopolitan): the host computes the expected values natively. */
#ifndef WN_KERNELS_H
#define WN_KERNELS_H
#include <stdint.h>

/* 24 live 64-bit values per iteration: more than the caller-saved registers of x86-64 and arm64, so the code generator has to use callee-saved registers (x19-x28 on arm64). */
#define S(p, q, r, k, m) p = (p + ((q ^ (r >> k)) * m)) ^ (p << 7)
static inline uint64_t wn_compute(uint32_t seed, uint32_t iters) {
    uint64_t a = seed + 1ull, b = a * 0x9E3779B97F4A7C15ull, c = b ^ (b >> 29), d = c * 3 + 7, e = d ^ 0xdeadbeefull, f = e + c, g = f * 5, h = g ^ a, i = h + 11, j = i * 13, k = j ^ b, l = k + d;
    uint64_t m = l * 17, n = m ^ c, o = n + e, p = o * 19, q = p ^ f, r = q + g, s = r * 23, t = s ^ h, u = t + i, v = u * 29, w = v ^ j, x = w + k;
    for (uint32_t it = 0; it < iters; it++) {
        S(a, x, b, 3, 0x9E3779B1ull); S(b, a, c, 5, 0x85EBCA6Bull); S(c, b, d, 7, 0xC2B2AE35ull); S(d, c, e, 11, 0x27D4EB2Full);
        S(e, d, f, 13, 0x165667B1ull); S(f, e, g, 17, 0xD3A2646Cull); S(g, f, h, 19, 0xFD7046C5ull); S(h, g, i, 23, 0xB55A4F09ull);
        S(i, h, j, 29, 0x9E3779B1ull); S(j, i, k, 31, 0x85EBCA6Bull); S(k, j, l, 37, 0xC2B2AE35ull); S(l, k, m, 41, 0x27D4EB2Full);
        S(m, l, n, 43, 0x165667B1ull); S(n, m, o, 47, 0xD3A2646Cull); S(o, n, p, 53, 0xFD7046C5ull); S(p, o, q, 59, 0xB55A4F09ull);
        S(q, p, r, 3, 0x9E3779B1ull); S(r, q, s, 5, 0x85EBCA6Bull); S(s, r, t, 7, 0xC2B2AE35ull); S(t, s, u, 11, 0x27D4EB2Full);
        S(u, t, v, 13, 0x165667B1ull); S(v, u, w, 17, 0xD3A2646Cull); S(w, v, x, 19, 0xFD7046C5ull); S(x, w, a, 23, 0xB55A4F09ull);
    }
    return a ^ b ^ c ^ d ^ e ^ f ^ g ^ h ^ i ^ j ^ k ^ l ^ m ^ n ^ o ^ p ^ q ^ r ^ s ^ t ^ u ^ v ^ w ^ x;
}
#undef S
static inline uint32_t wn_mix(uint32_t a, uint32_t b) { return (a * 31u + b) ^ (a >> 3); }
#endif
