#!/usr/bin/env python3
"""Image comparison for `engine test` (spec 18: "use tolerance/perceptual comparisons rather than pixel-exact cross-GPU expectations"). Stdlib only.

compare(rows_a, rows_b, w, h) -> dict
    mean_abs_channel_diff   mean of |a-b| over all four channels (0..255)
    pixels_over_8_pct       percentage of pixels with any channel differing by more than 8
    max_channel_diff        largest single-channel difference
    min_block_ssim          the structural similarity of the single worst 8x8 block: a change that is small on average but concentrated in one place (an object vanished, an edge moved) shows up
                            here although the mean difference, the pixel percentage and even the mean ssim barely move
    ssim                    mean structural similarity of the luma over 8x8 blocks (1.0 = identical). Unlike the two numbers above it notices that the STRUCTURE changed
                            (an edge moved, a shape vanished) even when the average colour error is small, and it ignores a uniform brightness change that keeps the structure.
    changed_bbox            [x0, y0, x1, y1] of the pixels over 8, or None
write_diff_png(path, rows_a, rows_b, w, h)  a PNG of three panels side by side: this run, the golden, and the difference (|a-b| times 4, clamped, alpha 255)
SSIM constants are the usual (K1 = 0.01, K2 = 0.03, L = 255). Blocks are 8x8, non-overlapping; a size that is not a multiple of 8 leaves the right and bottom edge strips out of the SSIM
(they are still in the other numbers). No threshold lives here: the caller's scenario states the tolerance."""
import struct
import zlib

C1 = (0.01 * 255) ** 2
C2 = (0.03 * 255) ** 2


def _luma(rows, w, h):
    out = []
    for y in range(h):
        r = rows[y]
        out.append([(299 * r[x * 4] + 587 * r[x * 4 + 1] + 114 * r[x * 4 + 2]) / 1000.0 for x in range(w)])
    return out


def ssim_stats(rows_a, rows_b, w, h):
    """(mean ssim, lowest block ssim) over the 8x8 blocks"""
    la, lb = _luma(rows_a, w, h), _luma(rows_b, w, h)
    total, n, lowest = 0.0, 0, 1.0
    for by in range(0, h - 7, 8):
        for bx in range(0, w - 7, 8):
            sa = sb = saa = sbb = sab = 0.0
            for y in range(by, by + 8):
                ra, rb = la[y], lb[y]
                for x in range(bx, bx + 8):
                    a, b = ra[x], rb[x]
                    sa += a; sb += b; saa += a * a; sbb += b * b; sab += a * b
            ma, mb = sa / 64, sb / 64
            va, vb, cov = saa / 64 - ma * ma, sbb / 64 - mb * mb, sab / 64 - ma * mb
            v = ((2 * ma * mb + C1) * (2 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2))
            total += v
            if v < lowest: lowest = v
            n += 1
    return (total / n, lowest) if n else (1.0, 1.0)


def ssim(rows_a, rows_b, w, h):
    return ssim_stats(rows_a, rows_b, w, h)[0]


def compare(rows_a, rows_b, w, h):
    tot = n_over = mx = 0
    x0, y0, x1, y1 = w, h, -1, -1
    for y in range(h):
        a_, b_ = rows_a[y], rows_b[y]
        if a_ == b_:
            continue
        for x in range(w):
            i = x * 4
            d0, d1, d2, d3 = abs(a_[i] - b_[i]), abs(a_[i + 1] - b_[i + 1]), abs(a_[i + 2] - b_[i + 2]), abs(a_[i + 3] - b_[i + 3])
            tot += d0 + d1 + d2 + d3
            m = max(d0, d1, d2, d3)
            if m > mx: mx = m
            if m > 8:
                n_over += 1
                if x < x0: x0 = x
                if x > x1: x1 = x
                if y < y0: y0 = y
                if y > y1: y1 = y
    mean_ssim, worst = ssim_stats(rows_a, rows_b, w, h)
    return {"mean_abs_channel_diff": tot / (w * h * 4), "pixels_over_8_pct": 100.0 * n_over / (w * h), "max_channel_diff": mx,
            "ssim": mean_ssim, "min_block_ssim": worst, "changed_bbox": [x0, y0, x1, y1] if n_over else None}


def _png(rows, w, h):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(t, body): return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


def write_diff_png(path, rows_a, rows_b, w, h):
    out = []
    for y in range(h):
        a_, b_ = rows_a[y], rows_b[y]
        diff = bytearray(w * 4)
        for x in range(w):
            i = x * 4
            diff[i] = min(255, abs(a_[i] - b_[i]) * 4); diff[i + 1] = min(255, abs(a_[i + 1] - b_[i + 1]) * 4); diff[i + 2] = min(255, abs(a_[i + 2] - b_[i + 2]) * 4); diff[i + 3] = 255
        out.append(bytes(a_) + bytes(b_) + bytes(diff))
    with open(path, "wb") as f:
        f.write(_png(out, w * 3, h))
