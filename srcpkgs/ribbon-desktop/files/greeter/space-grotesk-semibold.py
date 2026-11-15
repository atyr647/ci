#!/usr/bin/env python3
"""space-grotesk-semibold.py VARIABLE.ttf OUT.ttf

Space Grotesk's variable font names only Light, Regular, Medium and Bold
instances, so fontconfig (and Tk) can't pick weight 600, which the login
clock and avatars use. This writes the 600 instance as a static font,
family "Space Grotesk SemiBold" (typographic family Space Grotesk), the
same outlines a browser draws for font-weight: 600. Run at package build
time (python3-fonttools).
"""
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

font = instancer.instantiateVariableFont(TTFont(sys.argv[1]), {"wght": 600})
names = {1: "Space Grotesk SemiBold", 2: "Regular", 3: "SpaceGrotesk-SemiBold",
         4: "Space Grotesk SemiBold", 6: "SpaceGrotesk-SemiBold",
         16: "Space Grotesk", 17: "SemiBold"}
table = font["name"]
for nid in (1, 2, 3, 4, 6, 16, 17, 25):
    table.removeNames(nameID=nid)
for nid, s in names.items():
    table.setName(s, nid, 3, 1, 0x409)
    table.setName(s, nid, 1, 0, 0)
font["OS/2"].usWeightClass = 600
font.save(sys.argv[2])
