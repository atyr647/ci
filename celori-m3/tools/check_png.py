#!/usr/bin/env python3
"""Independent verifier for the G0A triangle frame. Stdlib only; run with `python3 -I` (isolated mode).

Decodes the PNG itself (not via the guest's encoder), then asserts the frame is the expected triangle:
  * size/format, not blank, exactly two dominant colours
  * clear colour at the corners and outside the triangle, orange inside it
  * the orange-pixel count matches the analytic triangle area within a tolerance
Tolerance, not equality: spec §18 forbids pixel-exact cross-GPU expectations.
Exit 0 = pass, 1 = fail, 2 = usage/decoding error. Prints one JSON line.
"""
import json
import struct
import sys
import zlib

W, H = 200, 150
CLEAR = (13, 26, 77)      # (0.05, 0.10, 0.30) * 255, rounded
ORANGE = (255, 128, 26)   # (1.0, 0.5, 0.1) * 255, rounded
CH_TOL = 3                # per-channel tolerance (rounding / driver differences)
# NDC (0,.7) (-.7,-.7) (.7,-.7) -> pixels: apex (100, 22.5), base y=127.5, x in [30,170]
EXPECTED_AREA = 0.5 * 140 * 105
AREA_TOL = 0.03


def decode(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        (n,) = struct.unpack(">I", data[pos:pos + 4])
        typ, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        (crc,) = struct.unpack(">I", data[pos + 8 + n:pos + 12 + n])
        if zlib.crc32(typ + body) & 0xFFFFFFFF != crc:
            raise ValueError(f"bad CRC in {typ!r}")
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        pos += 12 + n
    w, h, depth, ctype, _, _, interlace = ihdr
    if (depth, ctype, interlace) != (8, 6, 0):
        raise ValueError(f"unsupported PNG layout depth={depth} colortype={ctype} interlace={interlace}")
    raw = zlib.decompress(idat)
    stride = w * 4
    if len(raw) != h * (stride + 1):
        raise ValueError("unexpected decompressed size")
    rows, prev = [], bytes(stride)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):  # PNG filters (the guest writes filter 0, but be correct for any PNG)
            a = line[i - 4] if i >= 4 else 0
            b = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(bytes(line))
        prev = bytes(line)
    return w, h, rows


def near(px, ref, tol=CH_TOL):
    return all(abs(px[i] - ref[i]) <= tol for i in range(3))


def main():
    if len(sys.argv) != 2:
        print("usage: check_png.py <frame.png>", file=sys.stderr)
        return 2
    try:
        w, h, rows = decode(sys.argv[1])
    except Exception as e:  # noqa: BLE001 - report any decode problem as a usage/decode error
        print(json.dumps({"pass": False, "error": f"decode: {e}"}))
        return 2

    def at(x, y):
        return tuple(rows[y][x * 4:x * 4 + 4])

    checks = {}
    checks["size"] = (w, h) == (W, H)
    checks["alpha_opaque_everywhere"] = all(rows[y][x * 4 + 3] == 255 for y in range(h) for x in range(w)) if checks["size"] else False
    if not checks["size"]:
        print(json.dumps({"pass": False, "checks": checks, "got": [w, h]}))
        return 1

    checks["corners_are_clear_colour"] = all(near(at(x, y), CLEAR) for x, y in [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1)])
    checks["outside_triangle_is_clear"] = all(near(at(x, y), CLEAR) for x, y in [(10, 10), (190, 140), (100, 10), (20, 120), (180, 120)])
    checks["inside_triangle_is_orange"] = all(near(at(x, y), ORANGE) for x, y in [(100, 80), (100, 110), (70, 120), (130, 120), (100, 40)])

    orange = clear = other = 0
    for y in range(h):
        for x in range(w):
            p = at(x, y)
            if near(p, ORANGE): orange += 1
            elif near(p, CLEAR): clear += 1
            else: other += 1  # anti-aliased edge pixels
    area_err = abs(orange + other / 2 - EXPECTED_AREA) / EXPECTED_AREA
    checks["triangle_area_within_tolerance"] = area_err <= AREA_TOL
    checks["not_blank"] = orange > 1000 and clear > 1000
    checks["edge_pixels_are_few"] = other < 0.02 * w * h

    ok = all(checks.values())
    print(json.dumps({
        "pass": ok, "checks": checks, "orange_px": orange, "clear_px": clear, "edge_px": other,
        "expected_area_px": EXPECTED_AREA, "area_error": round(area_err, 4),
    }))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
