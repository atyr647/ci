#!/usr/bin/env python3
# make-exif.py DIR - the EXIF fixtures for the Inspector and the Image Viewer (tests/inspector-facts.tcl,
# the Photo section of the scenes). Three JPEGs, 40 x 30 pixels, in DIR:
#   mm.jpg    big-endian TIFF (MM), written by PIL: Fujifilm X-T5, f/5.6, 1/250 s, ISO 125, 23 mm,
#             a 2026 date, GPS 64 deg 4' 41.08" N, 16 deg 13' 51.6" W, lens XF16-55mm F2.8
#   ii.jpg    little-endian TIFF (II), built here by hand: f/4, 0.4 s, ISO 800, 16.5 mm, GPS
#             51 deg 30' 0" S, 0 deg 7' 40.8" E, no lens
#   bare.jpg  no EXIF at all
# Rationals are RATIONAL (type 5), as cameras write them; PIL's own tuples would be SHORT pairs.
import struct
import sys
from PIL import Image
from PIL.TiffImagePlugin import IFDRational

out = sys.argv[1]


def mm_photo():
    im = Image.new('RGB', (40, 30), (120, 80, 40))
    exif = im.getexif()
    exif[0x010f] = 'FUJIFILM'
    exif[0x0110] = 'X-T5'
    # the Exif IFD set as a dict of its own: Pillow before 11 (ubuntu-24.04 has 10.2) hands get_ifd()
    # of a tag the image lacks back as a loose dict that is never saved, so the camera's settings and
    # the date would be lost
    exif[0x8769] = {0x829a: IFDRational(1, 250), 0x829d: IFDRational(56, 10), 0x8827: 125,
                    0x920a: IFDRational(23, 1), 0x9003: '2026:08:14 21:43:00', 0xa434: 'XF16-55mm F2.8'}
    exif[0x8825] = {1: 'N', 2: (IFDRational(64, 1), IFDRational(4, 1), IFDRational(4108, 100)),
                    3: 'W', 4: (IFDRational(16, 1), IFDRational(13, 1), IFDRational(516, 10))}
    im.save(out + '/mm.jpg', 'JPEG', exif=exif)


def layout(entries, at):
    """one little-endian IFD placed at offset AT, its out-of-line values after it;
    entries are {tag: (type, count, value-bytes)}"""
    raw = struct.pack('<H', len(entries))
    extra = b''
    data_at = at + 2 + 12 * len(entries) + 4
    for tag, (typ, count, val) in sorted(entries.items()):
        if len(val) <= 4:
            field = val + b'\0' * (4 - len(val))
        else:
            field = struct.pack('<I', data_at + len(extra))
            extra += val
        raw += struct.pack('<HHI', tag, typ, count) + field
    return raw + struct.pack('<I', 0) + extra


def tiff_le(ifd0, exif_ifd, gps_ifd):
    """A little-endian TIFF: IFD0 at offset 8, then the Exif IFD and the GPS IFD (IFD0 points at
    them). Returns the bytes after 'Exif\\0\\0'."""
    ptr = (4, 1, b'\0\0\0\0')
    ifd0 = dict(ifd0)
    ifd0[0x8769] = ptr
    ifd0[0x8825] = ptr
    exif_at = 8 + len(layout(ifd0, 8))          # IFD0 with its values, placeholders keep its size
    exif_bytes = layout(exif_ifd, exif_at)
    gps_at = exif_at + len(exif_bytes)
    ifd0[0x8769] = (4, 1, struct.pack('<I', exif_at))
    ifd0[0x8825] = (4, 1, struct.pack('<I', gps_at))
    return b'II*\0' + struct.pack('<I', 8) + layout(ifd0, 8) + exif_bytes + layout(gps_ifd, gps_at)


def rat(*pairs):
    return b''.join(struct.pack('<II', n, d) for n, d in pairs)


def ii_photo():
    ifd0 = {0x010f: (2, 9, b'FUJIFILM\0'), 0x0110: (2, 6, b'X-T20\0')}
    exif = {
        0x829a: (5, 1, rat((2, 5))),          # 0.4 s
        0x829d: (5, 1, rat((4, 1))),          # f/4
        0x8827: (3, 1, struct.pack('<H', 800) + b'\0\0'),
        0x920a: (5, 1, rat((33, 2))),         # 16.5 mm
        0x9003: (2, 20, b'2026:08:14 21:43:00\0'),
    }
    gps = {
        0x0001: (2, 2, b'S\0'),
        0x0002: (5, 3, rat((51, 1), (30, 1), (0, 1))),
        0x0003: (2, 2, b'E\0'),
        0x0004: (5, 3, rat((0, 1), (7, 1), (408, 10))),
    }
    tiff = tiff_le(ifd0, exif, gps)
    im = Image.new('RGB', (40, 30), (40, 80, 120))
    im.save(out + '/ii.jpg', 'JPEG', exif=b'Exif\0\0' + tiff)


def bare_photo():
    Image.new('RGB', (40, 30), (40, 40, 40)).save(out + '/bare.jpg', 'JPEG')


mm_photo()
ii_photo()
bare_photo()
