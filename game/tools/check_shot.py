#!/usr/bin/env python3
"""Checks a screenshot of the window test against the pattern it presents (window_test.cpp): pixel (x,y) = (x, y, (x^y)&255) with a red 40x40 box at (100,60).
usage: check_shot.py shot.png [left top]   (the window's top-left corner in the screenshot, default 0 0). Prints SHOT mismatches/total and exits 1 when any pixel differs."""
import subprocess, sys
png = sys.argv[1]; left = int(sys.argv[2]) if len(sys.argv) > 2 else 0; top = int(sys.argv[3]) if len(sys.argv) > 3 else 0
raw = subprocess.run(['convert', png, '-crop', f'256x256+{left}+{top}', '+repage', '-depth', '8', 'rgb:-'], capture_output=True).stdout
if len(raw) != 256 * 256 * 3: print('SHOT cannot read a 256x256 region'); sys.exit(1)
bad = 0
for y in range(256):
    for x in range(256):
        i = (y * 256 + x) * 3; exp = (255, 0, 0) if 100 <= x < 140 and 60 <= y < 100 else (x, y, (x ^ y) & 255)
        if tuple(raw[i:i + 3]) != exp: bad += 1
print(f'SHOT {bad} of 65536 pixels differ from the presented frame'); sys.exit(1 if bad else 0)
