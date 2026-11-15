#!/usr/bin/env python3
# viewer-crop-check.py - the fixtures and the read-back checks of tests/viewer-crop.tcl
# (apps/viewer/crop.tcl writes the file; PIL reads the pixels back).
#   viewer-crop-check.py make DIR
#       quad.png  200 x 120, four colour quarters and a red dot at (130, 40), lossless
#       quad.jpg  240 x 160, the same quarters, Make FUJIFILM, EXIF Orientation 6 (stored
#                 sideways: displayed 160 x 240)
#   viewer-crop-check.py expect SRC OUT TURNS FLIP X0 Y0 X1 Y1 TOL
#       OUT must be SRC's displayed picture, turned TURNS quarter turns clockwise,
#       flipped if FLIP, and cropped to the fractions X0..X1, Y0..Y1 (ffmpeg's even
#       sizes and offsets). Prints "ok ..." or "FAIL ...": the mean difference per
#       channel must be at most TOL.
#   viewer-crop-check.py exif OUT MAKE
#       OUT keeps MAKE in its EXIF and its Orientation is 1 (or absent).
#   viewer-crop-check.py dot OUT X Y
#       the red dot's centre is within 3 px of X, Y (a Straighten turn).
#   viewer-crop-check.py noblack OUT W H
#       OUT is W x H and no pixel on its edges is near black (Straighten's auto-crop leaves
#       no corner of the background; the fixtures have no black).
#   viewer-crop-check.py tiff DIR
#       quad.tif, quad.png as a TIFF.
#   viewer-crop-check.py pages DIR
#       pages.tif, a TIFF of two pages (quad.png, then it flipped); prints nothing.
#   viewer-crop-check.py npages FILE
#       how many pages FILE has.
import os
import sys

from PIL import Image, ImageOps


def make(d):
    os.makedirs(d, exist_ok=True)
    im = Image.new('RGB', (200, 120), (0, 0, 0))
    px = im.load()
    for x in range(200):
        for y in range(120):
            px[x, y] = ((120, 60, 160) if x < 100 and y < 60 else (30, 200, 30) if x >= 100 and y < 60
                        else (30, 30, 220) if x < 100 else (240, 240, 240))
    for x in range(124, 137):
        for y in range(34, 47):
            px[x, y] = (255, 0, 0)
    im.save(os.path.join(d, 'quad.png'))
    j = im.resize((240, 160), Image.NEAREST)
    ex = j.getexif()
    ex[0x010F] = 'FUJIFILM'
    ex[0x0112] = 6
    j.save(os.path.join(d, 'quad.jpg'), exif=ex.tobytes(), quality=95)


def displayed(path):
    return ImageOps.exif_transpose(Image.open(path)).convert('RGB')


def expect(src, out, turns, flip, x0, y0, x1, y1, tol):
    im = displayed(src)
    for _ in range(int(turns)):
        im = im.transpose(Image.Transpose.ROTATE_270)     # 90 degrees clockwise
    if flip == '1':
        im = im.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    W, H = im.size
    x0, y0, x1, y1 = float(x0), float(y0), float(x1), float(y1)
    cw = 2 * int(W * (x1 - x0) / 2)
    ch = 2 * int(H * (y1 - y0) / 2)
    cx = 2 * int(W * x0 / 2)
    cy = 2 * int(H * y0 / 2)
    want = im.crop((cx, cy, cx + cw, cy + ch))
    got = Image.open(out).convert('RGB')
    if got.size != want.size:
        return f'FAIL {os.path.basename(out)}: size {got.size}, want {want.size}'
    from PIL import ImageChops, ImageStat
    mean = max(ImageStat.Stat(ImageChops.difference(got, want)).mean)
    if mean <= float(tol):
        return f'ok {os.path.basename(out)}: {got.size[0]} x {got.size[1]}, mean difference {mean:.2f}'
    return f'FAIL {os.path.basename(out)}: mean difference {mean:.2f} > {tol}'


def exif(out, make):
    im = Image.open(out)
    ex = im.getexif()
    o = ex.get(0x0112, 1)
    ok = ex.get(0x010F) == make and o == 1
    return (f'ok {os.path.basename(out)}: Make {make}, orientation {o}' if ok
            else f'FAIL {os.path.basename(out)}: Make {ex.get(0x010F)!r}, orientation {o}')


def dot(out, x, y):
    im = Image.open(out).convert('RGB')
    pts = [(px, py) for py in range(im.size[1]) for px in range(im.size[0])
           if (lambda p: p[0] > 150 and p[1] < 100 and p[2] < 100)(im.getpixel((px, py)))]
    if not pts:
        return 'FAIL no red dot'
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    if abs(cx - float(x)) <= 3 and abs(cy - float(y)) <= 3:
        return f'ok red dot at ({cx:.1f}, {cy:.1f}), turned to about ({x}, {y})'
    return f'FAIL red dot at ({cx:.1f}, {cy:.1f}), want about ({x}, {y})'


def noblack(out, w, h):
    im = Image.open(out).convert('RGB')
    W, H = im.size
    if (W, H) != (int(w), int(h)):
        return f'FAIL {os.path.basename(out)}: size {W} x {H}, want {w} x {h}'
    edge = [(x, y) for x in range(W) for y in (0, H - 1)] + [(x, y) for y in range(H) for x in (0, W - 1)]
    dark = [p for p in edge if max(im.getpixel(p)) < 40]
    if dark:
        return f'FAIL {os.path.basename(out)}: {len(dark)} near-black edge pixels, the first at {dark[0]}'
    return f'ok {os.path.basename(out)}: {W} x {H}, no black on its edges'


if __name__ == '__main__':
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == 'make':
        make(args[0])
    elif cmd == 'expect':
        print(expect(*args[:2], *args[2:8], args[8]))
    elif cmd == 'exif':
        print(exif(*args))
    elif cmd == 'dot':
        print(dot(*args))
    elif cmd == 'noblack':
        print(noblack(*args))
    elif cmd == 'tiff':
        Image.open(os.path.join(args[0], 'quad.png')).save(os.path.join(args[0], 'quad.tif'))
    elif cmd == 'pages':
        im = Image.open(os.path.join(args[0], 'quad.png')).convert('RGB')
        im.save(os.path.join(args[0], 'pages.tif'), save_all=True,
                append_images=[im.transpose(Image.Transpose.FLIP_LEFT_RIGHT)])
    elif cmd == 'npages':
        print(getattr(Image.open(args[0]), 'n_frames', 1))
    else:
        sys.exit(f'unknown: {cmd}')
