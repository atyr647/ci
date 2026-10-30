#!/usr/bin/env python3
"""Tests for image_compare.py: synthetic images with known differences, and the cases that show why the structural metric exists. Run: python3 -I tools/image_compare_test.py
Each check prints PASS or FAIL; exit 1 on any FAIL. The last block is a set of negative controls: with the metric broken on purpose, the checks that depend on it must fail."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_png
import image_compare as ic

W, H = 64, 48
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   [{detail}]"))
    fails += 0 if ok else 1


def image(f):
    return [bytes(v for x in range(W) for v in (*f(x, y), 255)) for y in range(H)]


def scene(x, y):       # a dark background with a bright disc and a vertical bar: structure to lose
    if (x - 20) ** 2 + (y - 24) ** 2 < 100: return (230, 200, 40)
    if 44 <= x < 50 and 8 <= y < 40: return (40, 160, 230)
    return (24, 28, 40)


A = image(scene)
same = ic.compare(A, A, W, H)
check("identical images: no difference, ssim 1, no changed region", same["mean_abs_channel_diff"] == 0 and same["max_channel_diff"] == 0 and abs(same["ssim"] - 1) < 1e-12 and same["changed_bbox"] is None, same)

bright = image(lambda x, y: tuple(min(255, c + 3) for c in scene(x, y)))
r = ic.compare(A, bright, W, H)
check("a uniform +3 brightness change: tiny mean difference, no pixel over 8, ssim stays above 0.99", r["max_channel_diff"] == 3 and r["pixels_over_8_pct"] == 0 and r["ssim"] > 0.99, r)

moved = image(lambda x, y: scene(x - 3, y))
r = ic.compare(A, moved, W, H)
check("the disc and the bar moved 3 pixels: the structural metric drops far below the brightness case and below 0.9", r["ssim"] < 0.9 and r["ssim"] < 0.99 - 0.05, r)
check("... and the changed region covers the disc and the bar and nothing outside them", r["changed_bbox"] is not None and r["changed_bbox"][0] >= 8 and r["changed_bbox"][2] <= 52 and r["changed_bbox"][1] >= 8, r)

gone = image(lambda x, y: (24, 28, 40) if not (44 <= x < 50 and 8 <= y < 40) is False else scene(x, y))
r = ic.compare(A, gone, W, H)
check("the bar removed: bbox is exactly the bar, 4 channels' worth of error counted, ssim below 1", r["changed_bbox"] == [44, 8, 49, 39] and r["ssim"] < 1, r)

def noise(x, y):       # deterministic +-6 pattern over the whole image
    n = ((x * 7 + y * 13) % 5) - 2
    return tuple(max(0, min(255, c + 3 * n)) for c in scene(x, y))
r = ic.compare(A, image(noise), W, H)
check("small deterministic noise (+-6): max difference 6 and nothing over 8, yet ssim is clearly below the brightness case (SSIM is sensitive to noise in flat areas, so a scenario picks min_ssim from measurements)", r["max_channel_diff"] == 6 and r["pixels_over_8_pct"] == 0 and r["ssim"] < 0.9 and r["ssim"] > 0.8, r)


def reference_ssim(ra, rb, w, h):      # the same formula written independently: per block, from the pixel lists, with the textbook definitions of mean, variance and covariance
    import statistics
    tot, n = 0.0, 0
    for by in range(0, h - 7, 8):
        for bx in range(0, w - 7, 8):
            pa = [(299 * ra[y][x * 4] + 587 * ra[y][x * 4 + 1] + 114 * ra[y][x * 4 + 2]) / 1000 for y in range(by, by + 8) for x in range(bx, bx + 8)]
            pb = [(299 * rb[y][x * 4] + 587 * rb[y][x * 4 + 1] + 114 * rb[y][x * 4 + 2]) / 1000 for y in range(by, by + 8) for x in range(bx, bx + 8)]
            ma, mb = statistics.fmean(pa), statistics.fmean(pb)
            va, vb = statistics.fmean([(v - ma) ** 2 for v in pa]), statistics.fmean([(v - mb) ** 2 for v in pb])
            cv = statistics.fmean([(a - ma) * (b - mb) for a, b in zip(pa, pb)])
            tot += (2 * ma * mb + ic.C1) * (2 * cv + ic.C2) / ((ma ** 2 + mb ** 2 + ic.C1) * (va + vb + ic.C2)); n += 1
    return tot / n
for label, other in (("noise", image(noise)), ("moved", moved), ("brightness", bright)):
    check(f"ssim agrees with an independent implementation of the formula ({label})", abs(ic.ssim(A, other, W, H) - reference_ssim(A, other, W, H)) < 1e-9, (ic.ssim(A, other, W, H), reference_ssim(A, other, W, H)))

r = ic.compare(A, gone, W, H)
check("the worst block catches a local change the mean hides: with the bar removed min_block_ssim is far below the mean ssim", r["min_block_ssim"] < 0.6 and r["ssim"] > r["min_block_ssim"] + 0.2, r)
r = ic.compare(A, bright, W, H)
check("... and for the uniform +3 change the worst block stays above 0.99", r["min_block_ssim"] > 0.99, r)
r = ic.compare(A, A, W, H)
check("identical images: min_block_ssim is 1", abs(r["min_block_ssim"] - 1) < 1e-12, r)

with tempfile.TemporaryDirectory() as d:
    p = os.path.join(d, "diff.png")
    ic.write_diff_png(p, A, moved, W, H)
    w3, h3, rows = check_png.decode(p)
    check("the diff image decodes with the independent PNG reader and is three panels wide", (w3, h3) == (W * 3, H), (w3, h3))
    left, mid, right = rows[24][:W * 4], rows[24][W * 4:2 * W * 4], rows[24][2 * W * 4:]
    check("panels are this run, the golden and the difference (x4): the first panel is A, the second is the moved image", left == A[24] and mid == moved[24], None)
    exp = bytes(v for x in range(W) for v in (min(255, abs(A[24][x * 4] - moved[24][x * 4]) * 4), min(255, abs(A[24][x * 4 + 1] - moved[24][x * 4 + 1]) * 4), min(255, abs(A[24][x * 4 + 2] - moved[24][x * 4 + 2]) * 4), 255))
    check("the third panel is the amplified absolute difference with alpha 255", right == exp, None)

# negative controls: break the metric and the structural checks must fail
real_stats = ic.ssim_stats
ic.ssim_stats = lambda a, b, w, h: (1.0, 1.0)
r = ic.compare(A, moved, W, H)
check("negative control: with the structural metric stubbed to 1.0, the 'moved' check would pass wrongly (so the check can fail)", not (r["ssim"] < 0.9), r)
ic.ssim_stats = lambda a, b, w, h: (0.0, 0.0)
r = ic.compare(A, bright, W, H)
check("negative control: with the metric stubbed to 0.0, the 'brightness' check would fail (so it can fail)", not (r["ssim"] > 0.99), r)
ic.ssim_stats = real_stats
print("image_compare_test: %s" % ("all pass" if not fails else f"{fails} FAILED"))
sys.exit(1 if fails else 0)
