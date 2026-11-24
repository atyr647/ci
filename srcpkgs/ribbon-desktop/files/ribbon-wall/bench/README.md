# ribbon-wall/bench: the measurements behind docs/WALLPAPER.md (throwaway)

Small single-purpose programs that produced the numbers in
[docs/WALLPAPER.md](../../../../../docs/WALLPAPER.md). Not part of any package;
delete once the decisions there are made. Build each with `cc -O2` and the
`pkg-config` libraries named in its header.

| File | Measures |
|---|---|
| `genclip.c` | Writes raw 4:2:0 frames of a moving gradient that loops exactly (frame N-1 → 0 continues), with a 16-bit barcode of the frame number top-left. Pipe into `ffmpeg -f rawvideo ...` to make H.264/VP9/AV1 test clips. |
| `analyze.py` | Reads `time index` lines and reports duplicates, skips, the median interval and the interval at each loop point (N-1 → 0). |
| `mpvloop.c` | libmpv with `loop-file=inf` through the software render API (mpvpaper's set-up, without GL), logs each frame mpv hands over. Extra `opt=value` arguments go to mpv. |
| `gstloop.c` | GStreamer `decodebin ! appsink sync=true`: `flush` mode (flushing seek at EOS) vs `segment` mode (non-flushing segment seeks). |
| `avloop.c` | ribbon-wall's design without Wayland: FFmpeg decode thread a few frames ahead, 60 Hz presenter on a continuous content clock; `seek`, `reopen` and `mem` loop modes; CPU and RSS. |
| `xtest.c` | XWayland probes: a 32-bit ARGB X window (alpha 0 / 50 % / opaque), a Shape-holed 24-bit window, and reading back a window's pixels. |
| `tk-argb.tcl` | Tk 8.6 on a 32-bit visual: what alpha it writes (needs `xtest`). |
| `tk-live-strip.tcl` | Cost in wish of refreshing a bar's wallpaper strip every video frame (PPM read + pill overlay + redisplay). |
| `wall-rows-naive.tcl` | The shell's per-pixel `wall::rows` at 1080p/4K/8K (strip, extrapolated to a full screen). |
| `clook.c` | The same gradient + anti-aliased stripes per pixel in C with a zlib PNG: the C baseline for `../look.tcl`. |

The end-to-end loop test is ribbon-wall itself: `RIBBON_WALL_STATS=log
RIBBON_WALL_NO_HW=1 ribbon-wall "video CLIP"` under a headless labwc
(`WLR_BACKENDS=headless WLR_RENDERER=pixman`), then `analyze.py FPS N < log`.
