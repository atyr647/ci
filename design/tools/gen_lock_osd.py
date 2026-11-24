#!/usr/bin/env python3
# The lock screen and the volume and brightness OSD. One 1440x900 board each.
#
# Lock-*: the session's lock is swaylock (docs/STACK.md S9, option 1: secure through ext-session-lock, prebuilt,
#   nothing drawn by Ribbon), so these boards draw only what swaylock's own config can say, in the palette's tokens
#   (bin/ribbon-lock writes that config from the active palette at every lock):
#     background   the desktop's picture when one is set (wallpaper.conf IMAGE, laid out as FIT says), else §d2
#                  (the pattern is drawn by the shell and is no picture swaylock can load); drawn here as §d2
#     indicator    always shown (indicator-idle-visible), centred: radius 56, ring 6 (53 to 59), no border lines;
#                  inside §bar, ring §pill; a key press lights a sixth of the ring in §accent (backspace §muted);
#                  verifying turns the ring §fg; a wrong password turns ring and word §accent, as the greeter
#                  shows "That password didn't work" (Greet-2-Wrong)
#     text         swaylock's own words ("verifying", "wrong"), Inter 15 (swaylock sets text at weight 400)
#   Lock-1-Idle, Lock-2-Typing, Lock-3-Verifying, Lock-4-Wrong
#
# OSD-*: the volume and brightness keys show a pill over the desktop, centred, 16 above the dock (its foot 62
#   above the screen's), for 1.5 s after the last press: §bar with the bars' ring and shadow, 300 x 44, radius 12.
#   Inside, as the quick panel's slider row (controls.tcl): the shell's line icon 16 (§fg), a 4 px track (§field)
#   filled with §accent to the level, the value 13/600 in tabular figures. Muted: the crossed speaker, the track
#   filled §muted to the level it comes back to, "Muted" in §muted.
#   OSD-1-Volume, OSD-2-Muted, OSD-3-Brightness
# usage: gen_lock_osd.py OUTDIR
import math
import sys
sys.argv = sys.argv[:2]
OUT = sys.argv[1]
import gen_kitui as K                                     # noqa: E402
from gen_kitui import tok, screen, NUM                    # noqa: E402
from gen_notify_r2 import dock                            # noqa: E402

# the shell's own icons (shell/theme.tcl), so the OSD's match the panel's
ICON = {'volume': 'M11 5L6 9H2v6h4l5 4z M15.54 8.46a5 5 0 0 1 0 7.07 M19.07 4.93a10 10 0 0 1 0 14.14',
        'volume-x': 'M11 5L6 9H2v6h4l5 4z M23 9l-6 6 M17 9l6 6',
        'sun': 'M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0 M12 2v2 M12 20v2 M4.93 4.93l1.41 1.41 M17.66 17.66l1.41 1.41 '
               'M2 12h2 M20 12h2 M4.93 19.07l1.41-1.41 M17.66 6.34l1.41-1.41'}

# ---------------------------------------------------------------- the lock (swaylock)
R, T, FS = 56, 6, 15          # indicator-radius, indicator-thickness, font-size
CX, CY = 720, 450             # swaylock centres the indicator on each output


def arc(a0, a1, r, col, w):
    """an arc of the ring from angle a0 to a1 (radians, clockwise from 3 o'clock, as cairo draws)"""
    x0, y0 = CX + r * math.cos(a0), CY + r * math.sin(a0)
    x1, y1 = CX + r * math.cos(a1), CY + r * math.sin(a1)
    big = 1 if (a1 - a0) % (2 * math.pi) > math.pi else 0
    return (f'<path d="M{x0:.2f} {y0:.2f} A{r} {r} 0 {big} 1 {x1:.2f} {y1:.2f}" '
            f'style="fill: none; stroke: {col}; stroke-width: {w}"></path>')


def lock(state):
    ring = {'idle': '§pill', 'typing': '§pill', 'verifying': '§fg', 'wrong': '§accent'}[state]
    text = {'verifying': ('verifying', '§fg'), 'wrong': ('wrong', '§accent')}.get(state)
    svg = (f'<svg aria-hidden="true" width="1440" height="900" viewBox="0 0 1440 900" style="position: absolute; left: 0; top: 0">'
           f'<circle cx="{CX}" cy="{CY}" r="{R - T / 2}" style="fill: §bar"></circle>'
           f'<circle cx="{CX}" cy="{CY}" r="{R}" style="fill: none; stroke: {ring}; stroke-width: {T}"></circle>')
    if state == 'typing':                    # a key press: a sixth of the ring, where swaylock happened to put it
        a = 1.15 * math.pi
        svg += arc(a, a + math.pi / 3, R, '§accent', T)
    svg += '</svg>'
    words = (f'<div style="position: absolute; left: {CX - R}px; top: {CY - 12}px; width: {2 * R}px; height: 24px; display: flex; '
             f'align-items: center; justify-content: center; font-size: {FS}px; font-weight: 400; color: {text[1]}">{text[0]}</div>') if text else ''
    return '<div style="position: absolute; inset: 0; background: §d2"></div>' + svg + words


# ---------------------------------------------------------------- the OSD
OW, OH = 300, 44
OX, OY = 720 - OW // 2, 900 - 62 - OH


def osd(icon, pct, muted=False):
    val = (f'<span style="font-size: 13px; font-weight: 500; color: §muted">Muted</span>' if muted
           else f'<span style="font-size: 13px; font-weight: 600; {NUM}">{pct}%</span>')
    return (f'<div style="position: absolute; left: {OX}px; top: {OY}px; width: {OW}px; height: {OH}px; box-sizing: border-box; padding: 0 16px; '
            f'display: flex; align-items: center; gap: 14px; border-radius: 12px; background: §bar; {K.RING}">'
            f'<svg aria-hidden="true" viewBox="0 0 24 24" width="16" height="16" style="flex-shrink: 0; fill: none; stroke: {"§muted" if muted else "§fg"}; '
            f'stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round"><path d="{ICON[icon]}"></path></svg>'
            f'<span style="flex: 1; height: 4px; border-radius: 2px; background: §field; display: flex">'
            f'<span style="width: {pct}%; height: 4px; border-radius: 2px; background: {"§muted" if muted else "§accent"}"></span></span>'
            f'<span style="min-width: 40px; display: flex; justify-content: flex-end">{val}</span></div>')


def desk(over):
    return K.left_bar() + K.right_bar(0) + dock() + over


BOARDS = [('Lock-1-Idle', 'Lock screen: locked', lock('idle')),
          ('Lock-2-Typing', 'Lock screen: typing the password', lock('typing')),
          ('Lock-3-Verifying', 'Lock screen: checking the password', lock('verifying')),
          ('Lock-4-Wrong', 'Lock screen: wrong password', lock('wrong')),
          ('OSD-1-Volume', 'OSD: volume', desk(osd('volume', 64))),
          ('OSD-2-Muted', 'OSD: muted', desk(osd('volume-x', 64, True))),
          ('OSD-3-Brightness', 'OSD: brightness', desk(osd('sun', 80)))]

if __name__ == '__main__':
    for name, title, inner in BOARDS:
        open(f'{OUT}/{name}.dc.html', 'w').write(tok(screen(title, inner)))
    print('ok')
