# ribbon-wall

Ribbon's desktop background: a wlr-layer-shell background surface on every
output showing a procedural design (drawn for the output's exact size), a
picture (fill, fit, centre, tile), a slideshow with crossfades, a plain
colour, or a muted video that loops without a hitch. It replaced swaybg.
The design, the control commands (previews for the Appearance app), the
measurements and the open decisions are in
[docs/WALLPAPER.md](../../../../docs/WALLPAPER.md).

## Files

| File | What |
|---|---|
| `main.c` | Wayland (outputs, hotplug, fractional scale, the window list for the pause rules), content and crossfades, the embedded Tcl interpreter and its `rw::` commands |
| `video.c` | decoding (VA-API, NVDEC, software), the reader thread (whole clip resident, or a resident head and streaming), the content clock |
| `gl.c`, `shm.c` | the renderers: EGL + GLES2 (dmabuf import of VA-API frames), and wl_shm + swscale |
| `rw.h` | what they share |
| `wall.tcl` | the policy, run inside ribbon-wall: wallpaper.conf, previews, the slideshow timer, pause rules, designs, the control commands |
| `look.tcl`, `looks/` | the procedural designs: the renderer and its data files (`*.look`, `*.glyphs`) |
| `glyphs.py` | font outlines to `*.glyphs` (build or maintainer time, fontTools) |
| `bench/` | throwaway measurement programs behind docs/WALLPAPER.md |

## Building and trying it

```sh
make O=/tmp/rw                       # wayland, wayland-egl, EGL, GLESv2, FFmpeg, Tcl 8.6 (+ libva)
RIBBON_WALL_LIB=$PWD /tmp/rw/ribbon-wall &          # shows ~/.config/ribbon/wallpaper.conf
echo 'preview video /path/clip.mp4' > "$XDG_RUNTIME_DIR/ribbon-wall"
echo 'preview end' > "$XDG_RUNTIME_DIR/ribbon-wall"
/tmp/rw/ribbon-wall --probe clip.mp4                 # the length rule (exit 0 / 1)
sh ../../../../tests/test-ribbon-wall.sh             # the tests (headless labwc)
```

Environment: `RIBBON_WALL_LIB` (where `wall.tcl` and `look.tcl` are),
`RIBBON_WALL_LOOKS`, `RIBBON_WALL_PALETTE`, `RIBBON_WALL_RENDERER=gl|shm`,
`RIBBON_WALL_HW=auto|vaapi|cuda|none`, `RIBBON_WALL_MAX_SECONDS`,
`RIBBON_WALL_RESIDENT_MB`, `RIBBON_WALL_PREPARE=0`, `RIBBON_WALL_STATS=FILE`
(presentation times and the test clips' frame barcodes), and for tests
`RIBBON_WALL_MIN_INTERVAL`, `RIBBON_WALL_POWER`, `RIBBON_WALL_DEBUG`.
