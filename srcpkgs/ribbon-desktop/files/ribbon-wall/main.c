/*
 * ribbon-wall - Ribbon's wallpaper: a wlr-layer-shell background surface on
 * every output, showing a colour, a picture, a procedural design drawn for
 * each output's exact size, a slideshow with crossfades, or a muted video
 * that loops without a hitch. It replaces swaybg.
 *
 * C does what Tcl can't: Wayland surfaces and buffers, decoding pictures
 * and video (FFmpeg; VA-API / NVDEC), and compositing (EGL + GLES2, or
 * wl_shm in software). Everything else is Tcl, in wall.tcl, which this
 * program runs in an embedded interpreter: reading wallpaper.conf, the
 * slideshow timer, previews for the Appearance app, the pause rules, the
 * procedural designs and the control commands (one text line each, on the
 * FIFO $XDG_RUNTIME_DIR/ribbon-wall or stdin; the list is in wall.tcl and
 * docs/WALLPAPER.md).
 *
 *   ribbon-wall [-f FIFO] [COMMAND...]    run (no commands: wallpaper.conf)
 *   ribbon-wall --probe FILE              a video's facts, and whether it's
 *                                         accepted (exit status 0) or too long (1)
 *   ribbon-wall --tcl SCRIPT [ARG...]     run a Tcl script (the design renderer)
 *
 * Files: main.c (this: Wayland, outputs, content, Tcl), video.c (decoding,
 * streaming, looping), gl.c and shm.c (the two renderers), wall.tcl
 * (policy), look.tcl (procedural designs).
 *
 * Copyright 2026 Ribbon OS contributors, MIT licence.
 */
#include "rw.h"
#include <errno.h>
#include <fcntl.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "fractional-scale-v1-client-protocol.h"
#include "presentation-time-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#ifndef RW_LIBDIR
#define RW_LIBDIR "/usr/lib/ribbon/wall"
#endif

struct wl_display *dpy;
struct wl_compositor *comp;
struct wl_shm *shm;
struct wl_list outputs;
struct wp_presentation *presentation;
Tcl_Interp *interp;
enum mode mode = M_COLOUR;
uint32_t bg_colour = 0xff121110;
enum fit fitmode = FIT_FILL;
FILE *stats;
struct renderer *R;

static struct zwlr_layer_shell_v1 *layer_shell;
static struct wp_viewporter *viewporter;
static struct wp_fractional_scale_manager_v1 *frac_mgr;
static struct zwlr_foreign_toplevel_manager_v1 *tl_mgr;
static bool quitting;

double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
void fill(uint32_t *px, size_t n, uint32_t c) { for (size_t i = 0; i < n; i++) px[i] = c; }
void img_free(struct img *i) { free(i->px); memset(i, 0, sizeof *i); }

/* Call a Tcl procedure with string arguments; errors go to stderr. */
static void tcl_call(const char *proc, int argc, const char **argv) {
	Tcl_Obj *o[12];
	o[0] = Tcl_NewStringObj(proc, -1);
	for (int i = 0; i < argc && i < 11; i++) o[i + 1] = Tcl_NewStringObj(argv[i], -1);
	for (int i = 0; i <= argc; i++) Tcl_IncrRefCount(o[i]);
	if (Tcl_EvalObjv(interp, argc + 1, o, TCL_EVAL_GLOBAL) != TCL_OK)
		fprintf(stderr, "ribbon-wall: %s\n", Tcl_GetVar(interp, "errorInfo", TCL_GLOBAL_ONLY));
	for (int i = 0; i <= argc; i++) Tcl_DecrRefCount(o[i]);
}

/* ---- pictures ------------------------------------------------------------------ */

/* Decode the first frame of any picture FFmpeg reads (PNG, JPEG, WebP, ...)
 * into BGRA at its own size; alpha kept. */
struct img load_picture(const char *file, int *srcw, int *srch) {
	struct img out = {0};
	AVFormatContext *fc = NULL;
	AVCodecContext *cc = NULL;
	AVFrame *f = av_frame_alloc();
	AVPacket *p = av_packet_alloc();
	if (avformat_open_input(&fc, file, NULL, NULL) < 0 || avformat_find_stream_info(fc, NULL) < 0) goto done;
	int s = av_find_best_stream(fc, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
	if (s < 0) goto done;
	const AVCodec *c = avcodec_find_decoder(fc->streams[s]->codecpar->codec_id);
	if (!c) goto done;
	cc = avcodec_alloc_context3(c);
	avcodec_parameters_to_context(cc, fc->streams[s]->codecpar);
	if (avcodec_open2(cc, c, NULL) < 0) goto done;
	bool got = false;
	while (!got && av_read_frame(fc, p) >= 0) {
		if (p->stream_index == s && avcodec_send_packet(cc, p) >= 0 && avcodec_receive_frame(cc, f) >= 0) got = true;
		av_packet_unref(p);
	}
	if (!got) { avcodec_send_packet(cc, NULL); got = avcodec_receive_frame(cc, f) >= 0; }
	if (!got || f->width <= 0 || f->height <= 0) goto done;
	out.w = f->width; out.h = f->height;
	out.px = malloc((size_t)out.w * out.h * 4);
	uint8_t *dst[4] = { (uint8_t *)out.px };
	int dls[4] = { out.w * 4 };
	struct SwsContext *sw = sws_getContext(f->width, f->height, f->format, f->width, f->height, AV_PIX_FMT_BGRA,
		SWS_POINT, NULL, NULL, NULL);
	sws_scale(sw, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, dls);
	sws_freeContext(sw);
	if (srcw) *srcw = out.w;
	if (srch) *srch = out.h;
done:
	av_frame_free(&f);
	av_packet_free(&p);
	avcodec_free_context(&cc);
	avformat_close_input(&fc);
	return out;
}

/* Where a W x H source goes on a PW x PH output for each fit mode: the source
 * crop (sx sy sw sh) and the destination rectangle (dx dy dw dh). */
void place(enum fit m, int W, int H, int PW, int PH, int r[8]) {
	int sx = 0, sy = 0, sw = W, sh = H, dx = 0, dy = 0, dw = PW, dh = PH;
	double s;
	switch (m) {
	case FIT_FILL: /* cover, crop the middle */
		s = fmax((double)PW / W, (double)PH / H);
		sw = (int)(PW / s + 0.5); sh = (int)(PH / s + 0.5);
		if (sw > W) sw = W;
		if (sh > H) sh = H;
		sx = (W - sw) / 2; sy = (H - sh) / 2;
		break;
	case FIT_FIT:
		s = fmin((double)PW / W, (double)PH / H);
		dw = (int)(W * s + 0.5); dh = (int)(H * s + 0.5);
		dx = (PW - dw) / 2; dy = (PH - dh) / 2;
		break;
	case FIT_CENTRE: case FIT_TILE:
		dw = W < PW ? W : PW; dh = H < PH ? H : PH;
		sw = dw; sh = dh;
		if (m == FIT_CENTRE) { sx = (W - sw) / 2; sy = (H - sh) / 2; dx = (PW - dw) / 2; dy = (PH - dh) / 2; }
		break;
	case FIT_STRETCH: break;
	}
	int v[8] = {sx, sy, sw, sh, dx, dy, dw, dh};
	memcpy(r, v, sizeof v);
}

/* A picture laid out on PW x PH (opaque; `bg` around it). */
static struct img layout_picture(const struct img *src, enum fit m, int PW, int PH, uint32_t bg) {
	struct img o = { malloc((size_t)PW * PH * 4), PW, PH };
	fill(o.px, (size_t)PW * PH, bg);
	if (!src->px) return o;
	int r[8];
	place(m, src->w, src->h, PW, PH, r);
	if (r[2] <= 0 || r[3] <= 0 || r[6] <= 0 || r[7] <= 0) return o;
	const uint8_t *s[4] = { (const uint8_t *)(src->px + (size_t)r[1] * src->w + r[0]) };
	int sls[4] = { src->w * 4 };
	uint8_t *d[4] = { (uint8_t *)(o.px + (size_t)r[5] * PW + r[4]) };
	int dls[4] = { PW * 4 };
	bool same = r[2] == r[6] && r[3] == r[7];
	struct SwsContext *sw = sws_getContext(r[2], r[3], AV_PIX_FMT_BGRA, r[6], r[7], AV_PIX_FMT_BGRA,
		same ? SWS_POINT : SWS_LANCZOS, NULL, NULL, NULL);
	sws_scale(sw, s, sls, 0, r[3], d, dls);
	sws_freeContext(sw);
	for (int y = 0; y < PH; y++)
		for (int x = 0; x < PW; x++) {
			uint32_t *p = o.px + (size_t)y * PW + x;
			if (m == FIT_TILE && (x >= r[6] || y >= r[7])) *p = o.px[(size_t)(y % r[7]) * PW + x % r[6]];
			if (*p >> 24 != 0xff) { /* a transparent picture: over the colour */
				uint32_t a = *p >> 24, c = *p, b = bg, v = 0xff000000;
				for (int sh = 0; sh < 24; sh += 8)
					v |= ((((c >> sh) & 255) * a + ((b >> sh) & 255) * (255 - a) + 127) / 255) << sh;
				*p = v;
			}
		}
	return o;
}

/* ---- the content ------------------------------------------------------------------ */

static char pic_path[1024];
static struct img pic_src;          /* the decoded picture, kept briefly for every output */
static Tcl_TimerToken pic_timer;

static void pic_release(ClientData d) { (void)d; img_free(&pic_src); pic_timer = NULL; }

static bool pic_ensure(void) {
	if (pic_src.px) return true;
	if (!pic_path[0]) return false;
	pic_src = load_picture(pic_path, NULL, NULL);
	return pic_src.px != NULL;
}

/* Remember what is on screen now as `prev` and fade it out over FADE ms. */
static void begin_transition(struct output *o, double fade_ms, bool wait) {
	if (!o->configured || fade_ms <= 0 || !R->capture_prev(o)) {
		img_free(&o->prev);
		o->fade_len = 0; o->fade_wait = false;
		return;
	}
	o->fade_len = fade_ms / 1000;
	o->fade_t0 = now();
	o->fade_wait = wait;
}

static void prepare_output(struct output *o) {
	if (!o->configured) return;
	img_free(&o->still);
	if (mode == M_PICTURE && pic_ensure()) o->still = layout_picture(&pic_src, fitmode, o->pw, o->ph, bg_colour);
	o->still_dirty = true;
}

static void arm_release(void) {
	if (pic_timer) Tcl_DeleteTimerHandler(pic_timer);
	pic_timer = Tcl_CreateTimerHandler(3000, pic_release, NULL);
}

/* ---- presentation (frame callbacks) ------------------------------------------------- */

static void fb_presented(void *data, struct wp_presentation_feedback *fb, uint32_t hi, uint32_t lo, uint32_t ns,
		uint32_t refresh, uint32_t shi, uint32_t slo, uint32_t flags) {
	(void)refresh; (void)shi; (void)slo; (void)flags;
	fprintf(stats, "%.6f %ld\n", (((uint64_t)hi << 32) | lo) + ns / 1e9, (long)(intptr_t)data);
	wp_presentation_feedback_destroy(fb);
}
static void fb_discarded(void *data, struct wp_presentation_feedback *fb) {
	(void)data;
	fprintf(stats, "# discarded\n");
	wp_presentation_feedback_destroy(fb);
}
static void fb_sync(void *d, struct wp_presentation_feedback *f, struct wl_output *o) { (void)d; (void)f; (void)o; }
static const struct wp_presentation_feedback_listener fb_listener = { fb_sync, fb_presented, fb_discarded };

int video_barcode(const AVFrame *f) { /* the test clips' frame number, top-left */
	if (!f || f->width < 400 || f->height < 24 || !f->data[0] || f->hw_frames_ctx) return -1;
	int n = 0;
	for (int b = 0; b < 16; b++) if (f->data[0][12 * f->linesize[0] + (b * 24 + 12)] > 128) n |= 1 << b;
	return n;
}

static bool fading(struct output *o) { return o->prev.px || o->prev_tex; }

/* Called by a renderer just before it commits a frame. */
void pre_commit(struct output *o, bool more) {
	if (stats && presentation && mode == M_VIDEO && o == wl_container_of(outputs.next, o, link)) {
		struct wp_presentation_feedback *fb = wp_presentation_feedback(presentation, o->surf);
		wp_presentation_feedback_add_listener(fb, &fb_listener, (void *)(intptr_t)video_barcode(video_frame(NULL)));
	}
	if (more || (mode == M_VIDEO && !o->paused)) request_frame(o);
}

void draw(struct output *o) {
	if (!o->configured || o->closed) return;
	if (o->fade_wait && mode == M_VIDEO && video_frame(NULL)) { o->fade_wait = false; o->fade_t0 = now(); }
	bool more = false;
	R->draw(o, &more);
}

static struct output *clock_output(void) {
	struct output *o;
	wl_list_for_each(o, &outputs, link) if (o->configured && !o->closed && !o->paused) return o;
	return NULL;
}

static void frame_done(void *data, struct wl_callback *cb, uint32_t t) {
	(void)t;
	struct output *o = data;
	wl_callback_destroy(cb);
	o->frame_pending = false;
	if (mode == M_VIDEO && !o->paused) {
		if (o == clock_output()) video_advance(); /* one content clock for every output */
		long idx;
		AVFrame *f = video_frame(&idx);
		if ((f && o->drawn != idx) || fading(o)) { o->drawn = idx; draw(o); return; }
		request_frame(o);
		wl_surface_commit(o->surf);
		return;
	}
	if (fading(o)) draw(o);
}
static const struct wl_callback_listener frame_listener = { frame_done };

void request_frame(struct output *o) {
	if (o->frame_pending || !o->surf) return;
	struct wl_callback *cb = wl_surface_frame(o->surf);
	wl_callback_add_listener(cb, &frame_listener, o);
	o->frame_pending = true;
}

static void set_paused(struct output *o, bool p) {
	if (p == o->paused) return;
	o->paused = p;
	if (!p && mode == M_VIDEO && o->configured) {
		video_reset_clock();
		request_frame(o);
		wl_surface_commit(o->surf);
	}
}

/* ---- outputs ----------------------------------------------------------------------- */

static void output_event(struct output *o) {
	char pw[16], ph[16], sc[16], w[16], h[16], lx[16], ly[16];
	snprintf(pw, sizeof pw, "%d", o->pw); snprintf(ph, sizeof ph, "%d", o->ph);
	snprintf(sc, sizeof sc, "%g", o->scale); snprintf(w, sizeof w, "%d", o->w); snprintf(h, sizeof h, "%d", o->h);
	snprintf(lx, sizeof lx, "%d", o->lx); snprintf(ly, sizeof ly, "%d", o->ly);
	const char *a[] = { o->name, pw, ph, sc, w, h, lx, ly };
	tcl_call("wall::output", 8, a);
}

static void resize(struct output *o) {
	if (!o->w || !o->h || o->closed) return;
	int pw, ph;
	double scale;
	if (o->fscale > 0 && o->vp) {
		scale = o->fscale;
		pw = (int)lround(o->w * scale); ph = (int)lround(o->h * scale);
		wp_viewport_set_destination(o->vp, o->w, o->h);
		wl_surface_set_buffer_scale(o->surf, 1);
	} else {
		scale = o->iscale;
		pw = o->w * o->iscale; ph = o->h * o->iscale;
		wl_surface_set_buffer_scale(o->surf, o->iscale);
	}
	bool changed = !o->configured || pw != o->pw || ph != o->ph || scale != o->scale;
	o->pw = pw; o->ph = ph; o->scale = scale;
	o->configured = true;
	if (!changed) { wl_surface_commit(o->surf); return; }
	printf("output %s %d %d %g\n", o->name, o->pw, o->ph, o->scale);
	fflush(stdout);
	img_free(&o->prev); o->fade_len = 0;
	if (mode == M_PEROUT) img_free(&o->still);
	prepare_output(o);
	if (mode == M_PICTURE) arm_release();
	o->drawn = -1;
	draw(o);
	output_event(o);
}

static void ls_configure(void *data, struct zwlr_layer_surface_v1 *ls, uint32_t serial, uint32_t w, uint32_t h) {
	struct output *o = data;
	zwlr_layer_surface_v1_ack_configure(ls, serial);
	o->w = w; o->h = h;
	resize(o);
}

static void destroy_surface(struct output *o) {
	R->output_fini(o);
	if (o->frac) wp_fractional_scale_v1_destroy(o->frac);
	if (o->vp) wp_viewport_destroy(o->vp);
	if (o->ls) zwlr_layer_surface_v1_destroy(o->ls);
	if (o->surf) wl_surface_destroy(o->surf);
	o->frac = NULL; o->vp = NULL; o->ls = NULL; o->surf = NULL;
	o->configured = o->frame_pending = false;
	o->pw = o->ph = 0;
}

static void ls_closed(void *data, struct zwlr_layer_surface_v1 *ls) {
	(void)ls;
	struct output *o = data;
	destroy_surface(o);
	o->closed = true; /* until the output is configured again */
}
static const struct zwlr_layer_surface_v1_listener ls_listener = { ls_configure, ls_closed };

static void frac_preferred(void *data, struct wp_fractional_scale_v1 *f, uint32_t s120) {
	(void)f;
	struct output *o = data;
	o->fscale = s120 / 120.0;
	if (o->configured) resize(o);
}
static const struct wp_fractional_scale_v1_listener frac_listener = { frac_preferred };

static void make_surface(struct output *o) {
	if (o->surf || !layer_shell) return;
	o->closed = false;
	o->surf = wl_compositor_create_surface(comp);
	struct wl_region *empty = wl_compositor_create_region(comp); /* clicks go through */
	wl_surface_set_input_region(o->surf, empty);
	wl_region_destroy(empty);
	if (viewporter && frac_mgr) {
		o->vp = wp_viewporter_get_viewport(viewporter, o->surf);
		o->frac = wp_fractional_scale_manager_v1_get_fractional_scale(frac_mgr, o->surf);
		wp_fractional_scale_v1_add_listener(o->frac, &frac_listener, o);
	}
	o->ls = zwlr_layer_shell_v1_get_layer_surface(layer_shell, o->surf, o->wl, ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper");
	zwlr_layer_surface_v1_set_size(o->ls, 0, 0);
	zwlr_layer_surface_v1_set_anchor(o->ls, 15);
	zwlr_layer_surface_v1_set_exclusive_zone(o->ls, -1);
	zwlr_layer_surface_v1_add_listener(o->ls, &ls_listener, o);
	R->output_init(o);
	wl_surface_commit(o->surf);
}

static void out_geometry(void *d, struct wl_output *w, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp,
		const char *mk, const char *md, int32_t tr) {
	(void)w; (void)pw; (void)ph; (void)sp; (void)mk; (void)md; (void)tr;
	struct output *o = d;
	o->lx = x; o->ly = y;
}
static void out_mode(void *d, struct wl_output *w, uint32_t f, int32_t x, int32_t y, int32_t r) { (void)d; (void)w; (void)f; (void)x; (void)y; (void)r; }
static void out_done(void *data, struct wl_output *w) {
	(void)w;
	struct output *o = data;
	if (!o->surf) make_surface(o);
	/* a scale change alone brings no configure (unless fractional scale does) */
	if (o->configured && o->pending_iscale != o->iscale) { o->iscale = o->pending_iscale; if (!o->frac) resize(o); }
	o->iscale = o->pending_iscale;
}
static void out_scale(void *data, struct wl_output *w, int32_t s) { (void)w; ((struct output *)data)->pending_iscale = s; }
static void out_name(void *data, struct wl_output *w, const char *n) { (void)w; snprintf(((struct output *)data)->name, 64, "%s", n); }
static void out_desc(void *d, struct wl_output *w, const char *s) { (void)d; (void)w; (void)s; }
static const struct wl_output_listener out_listener = { out_geometry, out_mode, out_done, out_scale, out_name, out_desc };

static void output_gone(struct output *o) {
	const char *a[] = { o->name };
	destroy_surface(o);
	img_free(&o->still); img_free(&o->prev);
	wl_output_destroy(o->wl);
	wl_list_remove(&o->link);
	printf("output-gone %s\n", o->name);
	fflush(stdout);
	tcl_call("wall::output_gone", 1, a);
	free(o);
}

/* ---- windows (wlr-foreign-toplevel): the pause rules' facts -------------------------- */

struct toplevel {
	struct wl_list link;
	struct zwlr_foreign_toplevel_handle_v1 *h;
	unsigned id;
	char app[128], states[64], outs[256], sent[512];
	struct wl_output *on[8];
	int non;
};
static struct wl_list toplevels;
static unsigned next_tl = 1;

static void tl_title(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *t) { (void)d; (void)h; (void)t; }
static void tl_app(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, const char *a) { (void)h; snprintf(((struct toplevel *)d)->app, 128, "%s", a ? a : ""); }
static void tl_enter(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *w) {
	(void)h;
	struct toplevel *t = d;
	if (t->non < 8) t->on[t->non++] = w;
}
static void tl_leave(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *w) {
	(void)h;
	struct toplevel *t = d;
	for (int i = 0; i < t->non; i++) if (t->on[i] == w) { t->on[i] = t->on[--t->non]; break; }
}
static void tl_state(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *st) {
	(void)h;
	struct toplevel *t = d;
	t->states[0] = 0;
	uint32_t *s;
	wl_array_for_each(s, st) {
		const char *n = *s == 0 ? "max" : *s == 1 ? "min" : *s == 2 ? "act" : *s == 3 ? "full" : NULL;
		if (n) { if (t->states[0]) strcat(t->states, " "); strcat(t->states, n); }
	}
}
static void tl_done(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
	(void)h;
	struct toplevel *t = d;
	t->outs[0] = 0;
	for (int i = 0; i < t->non; i++) {
		struct output *o;
		wl_list_for_each(o, &outputs, link) if (o->wl == t->on[i]) {
			if (t->outs[0]) strncat(t->outs, " ", sizeof t->outs - strlen(t->outs) - 1);
			strncat(t->outs, o->name, sizeof t->outs - strlen(t->outs) - 1);
		}
	}
	char key[512];
	snprintf(key, sizeof key, "%s|%s|%s", t->app, t->states, t->outs);
	if (!strcmp(key, t->sent)) return; /* a title change: nothing the rules care about */
	snprintf(t->sent, sizeof t->sent, "%s", key);
	char id[16];
	snprintf(id, sizeof id, "%u", t->id);
	const char *a[] = { id, t->app, t->states, t->outs };
	tcl_call("wall::toplevel", 4, a);
}
static void tl_closed(void *d, struct zwlr_foreign_toplevel_handle_v1 *h) {
	struct toplevel *t = d;
	char id[16];
	snprintf(id, sizeof id, "%u", t->id);
	zwlr_foreign_toplevel_handle_v1_destroy(h);
	wl_list_remove(&t->link);
	free(t);
	const char *a[] = { id };
	tcl_call("wall::toplevel_gone", 1, a);
}
static void tl_parent(void *d, struct zwlr_foreign_toplevel_handle_v1 *h, struct zwlr_foreign_toplevel_handle_v1 *p) { (void)d; (void)h; (void)p; }
static const struct zwlr_foreign_toplevel_handle_v1_listener tl_listener = {
	tl_title, tl_app, tl_enter, tl_leave, tl_state, tl_done, tl_closed, tl_parent };

static void tlm_toplevel(void *d, struct zwlr_foreign_toplevel_manager_v1 *m, struct zwlr_foreign_toplevel_handle_v1 *h) {
	(void)d; (void)m;
	struct toplevel *t = calloc(1, sizeof *t);
	t->h = h; t->id = next_tl++;
	wl_list_insert(&toplevels, &t->link);
	zwlr_foreign_toplevel_handle_v1_add_listener(h, &tl_listener, t);
}
static void tlm_finished(void *d, struct zwlr_foreign_toplevel_manager_v1 *m) { (void)d; zwlr_foreign_toplevel_manager_v1_destroy(m); tl_mgr = NULL; }
static const struct zwlr_foreign_toplevel_manager_v1_listener tlm_listener = { tlm_toplevel, tlm_finished };

/* ---- registry ---------------------------------------------------------------------- */

static void reg_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
	(void)data;
#define IS(x) !strcmp(iface, x##_interface.name)
	if (IS(wl_compositor)) comp = wl_registry_bind(r, name, &wl_compositor_interface, ver < 4 ? ver : 4);
	else if (IS(wl_shm)) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
	else if (IS(zwlr_layer_shell_v1)) layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, ver < 4 ? ver : 4);
	else if (IS(wp_presentation)) presentation = wl_registry_bind(r, name, &wp_presentation_interface, 1);
	else if (IS(wp_viewporter)) viewporter = wl_registry_bind(r, name, &wp_viewporter_interface, 1);
	else if (IS(wp_fractional_scale_manager_v1)) frac_mgr = wl_registry_bind(r, name, &wp_fractional_scale_manager_v1_interface, 1);
	else if (IS(zwlr_foreign_toplevel_manager_v1) && !getenv("RIBBON_WALL_NO_WINDOWS")) {
		tl_mgr = wl_registry_bind(r, name, &zwlr_foreign_toplevel_manager_v1_interface, ver < 3 ? ver : 3);
		zwlr_foreign_toplevel_manager_v1_add_listener(tl_mgr, &tlm_listener, NULL);
	} else if (IS(wl_output)) {
		struct output *o = calloc(1, sizeof *o);
		o->gname = name; o->iscale = o->pending_iscale = 1;
		snprintf(o->name, sizeof o->name, "output-%u", name);
		o->wl = wl_registry_bind(r, name, &wl_output_interface, ver < 4 ? ver : 4);
		wl_output_add_listener(o->wl, &out_listener, o);
		wl_list_insert(outputs.prev, &o->link);
	}
#undef IS
}
static void reg_remove(void *data, struct wl_registry *r, uint32_t name) {
	(void)data; (void)r;
	struct output *o, *t;
	wl_list_for_each_safe(o, t, &outputs, link) if (o->gname == name) output_gone(o);
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* ---- Tcl commands (namespace rw) --------------------------------------------------- */

static enum fit parse_fit(const char *s) {
	if (!strcmp(s, "fit")) return FIT_FIT;
	if (!strcmp(s, "stretch")) return FIT_STRETCH;
	if (!strcmp(s, "centre") || !strcmp(s, "center")) return FIT_CENTRE;
	if (!strcmp(s, "tile")) return FIT_TILE;
	return FIT_FILL;
}
static bool parse_colour(const char *s, uint32_t *c) {
	unsigned v;
	if (strlen(s) != 7 || sscanf(s, "#%6x", &v) != 1) return false;
	*c = 0xff000000 | v;
	return true;
}
static int err(Tcl_Interp *ip, const char *msg) { Tcl_SetObjResult(ip, Tcl_NewStringObj(msg, -1)); return TCL_ERROR; }
#define ARGS(n, usage) if (objc != (n) + 1) { Tcl_WrongNumArgs(ip, 1, objv, usage); return TCL_ERROR; }
#define S(i) Tcl_GetString(objv[i])

static struct output *find_output(const char *name) {
	struct output *o;
	wl_list_for_each(o, &outputs, link) if (!strcmp(o->name, name)) return o;
	return NULL;
}

/* rw::colour #RRGGBB FADE_MS */
static int c_colour(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(2, "#RRGGBB fade_ms");
	uint32_t c;
	if (!parse_colour(S(1), &c)) return err(ip, "not a colour");
	double f = atof(S(2));
	struct output *o;
	wl_list_for_each(o, &outputs, link) begin_transition(o, f, false);
	if (mode == M_VIDEO) video_stop();
	bg_colour = c; mode = M_COLOUR;
	wl_list_for_each(o, &outputs, link) { img_free(&o->still); o->still_dirty = true; draw(o); }
	return TCL_OK;
}

/* rw::picture FILE FIT FADE_MS BG */
static int c_picture(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(4, "file fit fade_ms bg");
	struct img src = load_picture(S(1), NULL, NULL);
	if (!src.px) return err(ip, "cannot read the picture");
	uint32_t bg = bg_colour;
	parse_colour(S(4), &bg);
	double f = atof(S(3));
	struct output *o;
	wl_list_for_each(o, &outputs, link) begin_transition(o, f, false);
	if (mode == M_VIDEO) video_stop();
	img_free(&pic_src); pic_src = src;
	snprintf(pic_path, sizeof pic_path, "%s", S(1));
	fitmode = parse_fit(S(2)); bg_colour = bg; mode = M_PICTURE;
	wl_list_for_each(o, &outputs, link) { prepare_output(o); draw(o); }
	arm_release();
	return TCL_OK;
}

static Tcl_Obj *info_dict(const struct video_info *vi) {
	Tcl_Obj *d = Tcl_NewDictObj();
#define PUT(k, v) Tcl_DictObjPut(NULL, d, Tcl_NewStringObj(k, -1), v)
	PUT("codec", Tcl_NewStringObj(vi->codec, -1));
	PUT("width", Tcl_NewIntObj(vi->w)); PUT("height", Tcl_NewIntObj(vi->h));
	PUT("fps", Tcl_NewDoubleObj(vi->fps)); PUT("duration", Tcl_NewDoubleObj(vi->duration));
	PUT("frames", Tcl_NewLongObj(vi->frames)); PUT("bytes", Tcl_NewWideIntObj(vi->bytes));
	PUT("max", Tcl_NewDoubleObj(video_max_seconds));
	if (vi->decoder[0]) {
		PUT("decoder", Tcl_NewStringObj(vi->decoder, -1)); PUT("hw", Tcl_NewStringObj(vi->hw, -1));
		PUT("store", Tcl_NewStringObj(vi->store, -1)); PUT("renderer", Tcl_NewStringObj(R->name, -1));
		if (vi->why_sw[0] && strcmp(vi->hw, "none") == 0) PUT("software_because", Tcl_NewStringObj(vi->why_sw, -1));
	}
#undef PUT
	return d;
}

/* rw::video FILE FIT FADE_MS BG -> facts about it, or an error */
static int c_video(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(4, "file fit fade_ms bg");
	struct video_info vi;
	char e[160];
	if (!video_probe(S(1), &vi, e, sizeof e)) return err(ip, e);
	double f = atof(S(3));
	struct output *o;
	/* the old content stays up (fading) until the first frame is decoded: no black flash */
	wl_list_for_each(o, &outputs, link) begin_transition(o, f > 0 ? f : 1, true);
	if (!video_start(S(1), &vi, e, sizeof e)) {
		wl_list_for_each(o, &outputs, link) { o->fade_wait = false; o->fade_len = 0; img_free(&o->prev); }
		return err(ip, e);
	}
	uint32_t bg = bg_colour;
	parse_colour(S(4), &bg);
	fitmode = parse_fit(S(2)); bg_colour = bg; mode = M_VIDEO;
	wl_list_for_each(o, &outputs, link) { img_free(&o->still); o->still_dirty = true; o->drawn = -1; draw(o); }
	Tcl_SetObjResult(ip, info_dict(&vi));
	return TCL_OK;
}

/* rw::perout BG FADE_MS: each output gets its own picture (rw::still) */
static int c_perout(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(2, "bg fade_ms");
	uint32_t bg = bg_colour;
	parse_colour(S(1), &bg);
	struct output *o;
	bool was = mode == M_PEROUT;
	if (!was) wl_list_for_each(o, &outputs, link) begin_transition(o, atof(S(2)), true);
	if (mode == M_VIDEO) video_stop();
	mode = M_PEROUT;
	wl_list_for_each(o, &outputs, link) {
		o->perout_bg = bg;
		if (!was) { img_free(&o->still); o->still_dirty = true; draw(o); }
	}
	return TCL_OK;
}

/* rw::still OUTPUT FILE FADE_MS: OUTPUT's own picture, shown 1:1 (made for its size) */
static int c_still(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(3, "output file fade_ms");
	struct output *o = find_output(S(1));
	if (!o || !o->configured) return err(ip, "no such output");
	if (mode != M_PEROUT) return err(ip, "not showing per-output pictures");
	struct img src = load_picture(S(2), NULL, NULL);
	if (!src.px) return err(ip, "cannot read the picture");
	if (o->fade_wait) { o->fade_wait = false; o->fade_t0 = now(); } /* waiting for this */
	else begin_transition(o, atof(S(3)), false);
	img_free(&o->still);
	o->still = layout_picture(&src, FIT_CENTRE, o->pw, o->ph, o->perout_bg);
	o->still_dirty = true;
	img_free(&src);
	draw(o);
	return TCL_OK;
}

/* rw::pause OUTPUT|* 0|1 */
static int c_pause(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(2, "output|* 0|1");
	struct output *o;
	bool p = atoi(S(2)) != 0;
	wl_list_for_each(o, &outputs, link) if (!strcmp(S(1), "*") || !strcmp(S(1), o->name)) set_paused(o, p);
	return TCL_OK;
}

static int c_outputs(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(0, "");
	Tcl_Obj *l = Tcl_NewListObj(0, NULL);
	struct output *o;
	wl_list_for_each(o, &outputs, link) {
		if (!o->configured || o->closed) continue;
		Tcl_Obj *e[8] = { Tcl_NewStringObj(o->name, -1), Tcl_NewIntObj(o->pw), Tcl_NewIntObj(o->ph),
			Tcl_NewDoubleObj(o->scale), Tcl_NewIntObj(o->w), Tcl_NewIntObj(o->h), Tcl_NewIntObj(o->lx), Tcl_NewIntObj(o->ly) };
		Tcl_ListObjAppendElement(ip, l, Tcl_NewListObj(8, e));
	}
	Tcl_SetObjResult(ip, l);
	return TCL_OK;
}

static int c_stats(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(0, "");
	char b[600] = "";
	if (mode == M_VIDEO) video_stats(b, sizeof b);
	Tcl_Obj *r = Tcl_ObjPrintf("renderer %s mode %s %s", R->name,
		mode == M_VIDEO ? "video" : mode == M_PICTURE ? "picture" : mode == M_PEROUT ? "perout" : "colour", b);
	Tcl_SetObjResult(ip, r);
	return TCL_OK;
}

static int c_probe(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(1, "file");
	struct video_info vi;
	char e[160];
	bool ok = video_probe(S(1), &vi, e, sizeof e);
	Tcl_Obj *d = info_dict(&vi);
	Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("ok", -1), Tcl_NewBooleanObj(ok));
	if (!ok) Tcl_DictObjPut(NULL, d, Tcl_NewStringObj("error", -1), Tcl_NewStringObj(e, -1));
	Tcl_SetObjResult(ip, d);
	return TCL_OK;
}

static int c_mkfifo(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(1, "path");
	struct stat st;
	if (lstat(S(1), &st) == 0 && !S_ISFIFO(st.st_mode)) unlink(S(1));
	if (mkfifo(S(1), 0600) < 0 && errno != EEXIST) return err(ip, strerror(errno));
	return TCL_OK;
}

static int c_quit(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; (void)ip; (void)objc; (void)objv;
	quitting = true;
	return TCL_OK;
}

static int c_pid_alive(ClientData cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[]) {
	(void)cd; ARGS(1, "pid");
	int pid = atoi(S(1));
	Tcl_SetObjResult(ip, Tcl_NewBooleanObj(pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)));
	return TCL_OK;
}

static void tcl_commands(Tcl_Interp *ip) {
	struct { const char *n; Tcl_ObjCmdProc *f; } c[] = {
		{"rw::colour", c_colour}, {"rw::picture", c_picture}, {"rw::video", c_video}, {"rw::perout", c_perout},
		{"rw::still", c_still}, {"rw::pause", c_pause}, {"rw::outputs", c_outputs}, {"rw::stats", c_stats}, {"rw::probe", c_probe}, {"rw::mkfifo", c_mkfifo},
		{"rw::quit", c_quit}, {"rw::alive", c_pid_alive} };
	Tcl_Eval(ip, "namespace eval rw {}");
	for (size_t i = 0; i < sizeof c / sizeof *c; i++) Tcl_CreateObjCommand(ip, c[i].n, c[i].f, NULL, NULL);
}

/* ---- main loop: Tcl's event loop, with the Wayland socket in it --------------------- */

static int sigpipe[2];
static void on_hup(int s) { (void)s; int e = errno; if (write(sigpipe[1], "h", 1) < 0) {} errno = e; }
static void sig_ready(ClientData d, int mask) {
	(void)d; (void)mask;
	char c[64];
	bool hup = false;
	ssize_t n;
	while ((n = read(sigpipe[0], c, sizeof c)) > 0) hup |= memchr(c, 'h', n) != NULL;
	if (hup) tcl_call("wall::reload", 0, NULL);
}

static void wl_ready(ClientData d, int mask) {
	(void)d; (void)mask;
	if (wl_display_prepare_read(dpy) == 0) {
		if (wl_display_read_events(dpy) < 0) { quitting = true; return; }
	}
	if (wl_display_dispatch_pending(dpy) < 0) quitting = true;
}

static Tcl_Interp *new_interp(int argc, char **argv, int first) {
	Tcl_Interp *ip = Tcl_CreateInterp();
	if (Tcl_Init(ip) != TCL_OK) fprintf(stderr, "ribbon-wall: %s\n", Tcl_GetStringResult(ip));
	Tcl_Obj *l = Tcl_NewListObj(0, NULL);
	for (int i = first; i < argc; i++) Tcl_ListObjAppendElement(ip, l, Tcl_NewStringObj(argv[i], -1));
	Tcl_SetVar2Ex(ip, "argv", NULL, l, TCL_GLOBAL_ONLY);
	Tcl_SetVar2Ex(ip, "argc", NULL, Tcl_NewIntObj(argc - first), TCL_GLOBAL_ONLY);
	return ip;
}

static const char *libdir(void) {
	const char *e = getenv("RIBBON_WALL_LIB");
	return e && *e ? e : RW_LIBDIR;
}

int main(int argc, char **argv) {
	Tcl_FindExecutable(argv[0]);
	av_log_set_level(AV_LOG_ERROR);
	const char *ms = getenv("RIBBON_WALL_MAX_SECONDS");
	if (ms && atof(ms) > 0) video_max_seconds = atof(ms);
	if (argc >= 3 && !strcmp(argv[1], "--tcl")) { /* the design renderer, without a display */
		Tcl_Interp *ip = new_interp(argc, argv, 3);
		Tcl_SetVar(ip, "argv0", argv[2], TCL_GLOBAL_ONLY);
		if (Tcl_EvalFile(ip, argv[2]) != TCL_OK) {
			fprintf(stderr, "%s\n", Tcl_GetVar(ip, "errorInfo", TCL_GLOBAL_ONLY));
			return 1;
		}
		return 0;
	}
	if (argc == 3 && !strcmp(argv[1], "--probe")) {
		struct video_info vi;
		char e[160];
		bool ok = video_probe(argv[2], &vi, e, sizeof e);
		printf("codec %s width %d height %d fps %.3f duration %.3f bytes %lld max %.0f ok %d%s%s\n",
			vi.codec[0] ? vi.codec : "-", vi.w, vi.h, vi.fps, vi.duration, (long long)vi.bytes, video_max_seconds,
			ok, ok ? "" : " error ", ok ? "" : e);
		return ok ? 0 : 1;
	}
	const char *fifo = "";
	int first = 1;
	if (argc > 2 && !strcmp(argv[1], "-f")) { fifo = argv[2]; first = 3; }
	if (getenv("RIBBON_WALL_STATS")) stats = fopen(getenv("RIBBON_WALL_STATS"), "w");
	if (stats) setvbuf(stats, NULL, _IOLBF, 0);
	setvbuf(stdout, NULL, _IOLBF, 0);
	wl_list_init(&outputs);
	wl_list_init(&toplevels);
	dpy = wl_display_connect(NULL);
	if (!dpy) { fprintf(stderr, "ribbon-wall: no Wayland display\n"); return 1; }
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);
	if (!comp || !shm || !layer_shell) { fprintf(stderr, "ribbon-wall: the compositor lacks wlr-layer-shell\n"); return 1; }
	const char *rn = getenv("RIBBON_WALL_RENDERER");
	R = &gl_renderer;
	if ((rn && !strcmp(rn, "shm")) || !R->init()) R = &shm_renderer, R->init();
	video_need_sw_frames = R == &shm_renderer;
	printf("renderer %s\n", R->name);

	interp = new_interp(argc, argv, first);
	tcl_commands(interp);
	char path[1024];
	snprintf(path, sizeof path, "%s/wall.tcl", libdir());
	Tcl_SetVar2(interp, "::rw::lib", NULL, libdir(), TCL_GLOBAL_ONLY);
	Tcl_SetVar2(interp, "::rw::fifo", NULL, fifo, TCL_GLOBAL_ONLY);
	if (Tcl_EvalFile(interp, path) != TCL_OK) {
		fprintf(stderr, "ribbon-wall: %s\n", Tcl_GetVar(interp, "errorInfo", TCL_GLOBAL_ONLY));
		return 1;
	}
	if (pipe2(sigpipe, O_CLOEXEC | O_NONBLOCK) < 0) return 1;
	signal(SIGHUP, on_hup);
	signal(SIGPIPE, SIG_IGN);
	Tcl_CreateFileHandler(sigpipe[0], TCL_READABLE, sig_ready, NULL);
	Tcl_CreateFileHandler(wl_display_get_fd(dpy), TCL_READABLE, wl_ready, NULL);
	wl_display_roundtrip(dpy); /* outputs' names and scales, then their surfaces */
	tcl_call("wall::start", 0, NULL);
	while (!quitting) {
		if (wl_display_dispatch_pending(dpy) < 0) break;
		if (wl_display_flush(dpy) < 0 && errno != EAGAIN) break;
		Tcl_DoOneEvent(TCL_ALL_EVENTS);
	}
	video_stop();
	return 0;
}
