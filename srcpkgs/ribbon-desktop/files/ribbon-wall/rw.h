/* rw.h - ribbon-wall's C core, shared between its files.
 *
 * ribbon-wall is a small C engine (Wayland surfaces, decoding, compositing)
 * with the policy in Tcl (wall.tcl, run by an embedded interpreter). See
 * main.c for the layout and docs/WALLPAPER.md for the design.
 *
 * Copyright 2026 Ribbon OS contributors, MIT licence. */
#ifndef RW_H
#define RW_H
#define _GNU_SOURCE
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <tcl.h>
#include <wayland-client.h>
#include <libavutil/frame.h>

enum fit { FIT_FILL, FIT_FIT, FIT_STRETCH, FIT_CENTRE, FIT_TILE };

/* What is shown. COLOUR, PICTURE and VIDEO are the same on every output;
 * PEROUT gives each output its own picture (the procedural designs, drawn
 * by Tcl for each output's exact size). */
enum mode { M_COLOUR, M_PICTURE, M_VIDEO, M_PEROUT };

/* Pixels are 32-bit 0xAARRGGBB words (B, G, R, A bytes in memory). */
struct img { uint32_t *px; int w, h; };

struct output {
	struct wl_list link;
	struct wl_output *wl;
	uint32_t gname;
	char name[64];
	int lx, ly;                       /* layout position (wl_output.geometry) */
	int iscale, pending_iscale;       /* wl_output integer scale */
	double fscale;                    /* wp_fractional_scale (0: not offered) */
	struct wl_surface *surf;
	struct zwlr_layer_surface_v1 *ls;
	struct wp_viewport *vp;
	struct wp_fractional_scale_v1 *frac;
	int w, h;                         /* logical size (layer-shell configure) */
	int pw, ph;                       /* buffer size in pixels */
	double scale;                     /* pw / w */
	bool configured, frame_pending, paused, closed;
	/* content */
	struct img still;                 /* PICTURE / PEROUT / COLOUR: what this output shows */
	unsigned still_tex;
	bool still_dirty;                 /* still changed since the renderer last uploaded it */
	uint32_t perout_bg;               /* PEROUT: colour until its picture arrives */
	/* transition: what was on screen before, faded out over the new content */
	struct img prev;
	unsigned prev_tex;
	bool prev_dirty, fade_wait;       /* fade_wait: new content not ready yet (video's first frame) */
	double fade_t0, fade_len;
	long drawn;                       /* video: content index on screen */
	void *r;                          /* renderer state */
};

/* ---- main.c ---- */
extern struct wl_display *dpy;
extern struct wl_compositor *comp;
extern struct wl_shm *shm;
extern struct wl_list outputs;
extern Tcl_Interp *interp;
extern enum mode mode;
extern uint32_t bg_colour;
extern enum fit fitmode;
extern FILE *stats;
extern struct wp_presentation *presentation;
double now(void);
void request_frame(struct output *o);
void draw(struct output *o);
void fill(uint32_t *px, size_t n, uint32_t c);
void pre_commit(struct output *o, bool more);
struct img load_picture(const char *file, int *srcw, int *srch); /* BGRA, own size */
void img_free(struct img *i);
int video_barcode(const AVFrame *f);

/* ---- video.c ---- */
enum hwkind { HW_NONE, HW_VAAPI, HW_CUDA };
struct video_info {
	char codec[32], decoder[32], hw[16], store[16], why_sw[64];
	int w, h;
	double fps, duration;
	long frames;
	int64_t bytes, resident_bytes;
};
extern double video_max_seconds;
bool video_probe(const char *file, struct video_info *vi, char *err, size_t n);
bool video_start(const char *file, struct video_info *vi, char *err, size_t n);
void video_stop(void);
bool video_running(void);
bool video_advance(void);            /* advance the content clock; true: a new frame is current */
void video_reset_clock(void);
AVFrame *video_frame(long *index);   /* the current frame (NULL before the first) */
double video_fps(void);
void video_want_copyback(void);      /* GPU frames can't be imported: copy them to memory from now on */
void video_stats(char *buf, size_t n);
extern bool video_need_sw_frames;    /* shm renderer: always hand over frames in memory */

/* ---- renderers: gl.c (EGL + GLES2) and shm.c (wl_shm, software) ---- */
struct renderer {
	const char *name;
	bool (*init)(void);
	void (*output_init)(struct output *o);
	void (*output_fini)(struct output *o);
	void (*draw)(struct output *o, bool *more);            /* draw + commit (calls pre_commit) */
	bool (*capture_prev)(struct output *o);                 /* what is shown now -> o->prev (crossfades) */
};
extern struct renderer gl_renderer, shm_renderer;
extern struct renderer *R;

/* shared helpers for both renderers */
void place(enum fit m, int W, int H, int PW, int PH, int r[8]);
void yuv_matrix(const AVFrame *f, float m[9], float off[3]);
#endif
