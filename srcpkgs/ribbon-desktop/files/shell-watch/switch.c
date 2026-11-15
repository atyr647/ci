/*
 * ribbon-shell-switch - the Alt+Tab switcher's window to the compositor (U19).
 *
 * The switcher is drawn by the Tk shell. Tk can't hold the keyboard against other clients, read other
 * windows or take a still of the screen, so this small helper does those three, and talks over a pipe:
 * commands one per line on stdin, events one per line on stdout. It is started by the shell when the
 * switcher is first asked for and quit when it closes.
 *
 * Keyboard. `grab` puts a 1x1 transparent layer-shell surface on the overlay layer with exclusive
 * keyboard interactivity and an empty input region (the pointer goes through to the switcher), the same
 * trick as apps/polkit/native/rpk-keys.c. Every key then comes here and goes to no other client, so
 * the Alt release cannot be missed by the window underneath. Events:
 *
 *   ready            the surface has the keyboard (before this, keys went to the focused window)
 *   lost             the keyboard went elsewhere, or the surface was closed
 *   altup            Alt is no longer held (also sent when `ready` finds Alt already up: a quick tap)
 *   key NAME         tab btab left right up down grave w q esc enter   (key repeat: tab btab arrows grave)
 *
 * Stills. `shot FILE DESAT [NAME [WIDTH]]` takes one wlr-screencopy of the output named NAME (its wl_output
 * name, version 4; the first output when NAME is left out or the compositor's outputs have no names) and writes
 * FILE as binary PPM (P6), scaled to WIDTH pixels wide when WIDTH is given and smaller (the output's logical
 * width: a scaled output's pixels are more than the shell draws on), with DESAT percent of the colour taken out.
 * Reply: `shot FILE W H`, or `shot FILE fail` (also when no output has that name).
 *
 * Windows. `cap TOKEN WIDTH FILE APP_ID<TAB>TITLE` copies the window (ext-image-copy-capture-v1 with an
 * ext-foreign-toplevel-list source: the first toplevel with that app id and title), scales it to WIDTH
 * pixels wide and writes FILE as PPM. Reply: `cap TOKEN ok W H` or `cap TOKEN fail`. `caps` prints
 * `caps shot` / `caps shot cap`: what the compositor offers, so the shell knows whether to ask.
 *
 * Other commands: `release` (drop the surface, back to idle), `quit`. Exits when stdin or the
 * compositor goes away. Copyright 2026 Ribbon OS contributors, MIT licence.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/timerfd.h>
#include <unistd.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include "ext-foreign-toplevel-list-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

static struct wl_display *dpy;
static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct wl_seat *seat;
/* the outputs, with their names (wl_output version 4) as they come and go */
struct outp { struct wl_list link; uint32_t gname; struct wl_output *o; char *name; };
static struct wl_list outs;
static struct zwlr_layer_shell_v1 *lshell;
static struct zwlr_screencopy_manager_v1 *scmgr;
static struct ext_foreign_toplevel_list_v1 *tlist;
static struct ext_foreign_toplevel_image_capture_source_manager_v1 *srcmgr;
static struct ext_image_copy_capture_manager_v1 *capmgr;
static struct wl_surface *surf;
static struct zwlr_layer_surface_v1 *ls;
static struct wl_keyboard *kbd;
static struct xkb_context *xctx;
static struct xkb_keymap *xmap;
static struct xkb_state *xst;
static int tfd = -1, have_focus, quit_now, alt_held, mods_seen;
static int rep_delay = 400, rep_rate = 25;
static uint32_t rep_key;

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void out(const char *fmt, ...)
{
	char b[1024];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(b, sizeof b - 1, fmt, ap);
	va_end(ap);
	if (n < 0) return;
	if ((size_t)n > sizeof b - 2) n = sizeof b - 2;
	b[n++] = '\n';
	if (write(1, b, (size_t)n) < 0 && errno != EINTR) quit_now = 1;
}

/* ---- pixels --------------------------------------------------------------------------------------------- */

struct img { int w, h; unsigned char *rgb; };

/* A wl_shm buffer of a known format, as 8-bit RGB, optionally scaled to width W (0: as is) and desaturated. */
static int shm_format_ok(uint32_t f)
{
	return f == WL_SHM_FORMAT_ARGB8888 || f == WL_SHM_FORMAT_XRGB8888 || f == WL_SHM_FORMAT_ABGR8888 || f == WL_SHM_FORMAT_XBGR8888;
}

static int to_rgb(struct img *im, const uint8_t *src, int w, int h, int stride, uint32_t fmt, int yinv, int outw, int desat)
{
	int bgr = fmt == WL_SHM_FORMAT_ARGB8888 || fmt == WL_SHM_FORMAT_XRGB8888; /* little-endian words: B G R x in memory */
	if (outw <= 0 || outw > w) outw = w;
	int oh = (int)((long)h * outw / w);
	if (oh < 1) oh = 1;
	im->w = outw; im->h = oh;
	im->rgb = malloc((size_t)outw * (size_t)oh * 3);
	if (!im->rgb) return -1;
	for (int y = 0; y < oh; y++) {
		int y0 = (int)((long)y * h / oh), y1 = (int)((long)(y + 1) * h / oh);
		if (y1 <= y0) y1 = y0 + 1;
		for (int x = 0; x < outw; x++) {
			int x0 = (int)((long)x * w / outw), x1 = (int)((long)(x + 1) * w / outw);
			if (x1 <= x0) x1 = x0 + 1;
			long r = 0, g = 0, b = 0, n = 0;
			for (int sy = y0; sy < y1; sy++) {
				int row = yinv ? h - 1 - sy : sy;
				const uint8_t *p = src + (size_t)row * (size_t)stride + (size_t)x0 * 4;
				for (int sx = x0; sx < x1; sx++, p += 4, n++) {
					if (bgr) { b += p[0]; g += p[1]; r += p[2]; } else { r += p[0]; g += p[1]; b += p[2]; }
				}
			}
			double R = (double)r / (double)n, G = (double)g / (double)n, B = (double)b / (double)n;
			if (desat) {
				double l = 0.2126 * R + 0.7152 * G + 0.0722 * B, k = desat / 100.0;
				R += (l - R) * k; G += (l - G) * k; B += (l - B) * k;
			}
			unsigned char *o = im->rgb + ((size_t)y * (size_t)outw + (size_t)x) * 3;
			o[0] = (unsigned char)(R + 0.5); o[1] = (unsigned char)(G + 0.5); o[2] = (unsigned char)(B + 0.5);
		}
	}
	return 0;
}

/* Written to a temporary name and renamed, so Tk never reads half a file. */
static int write_ppm(const char *file, const struct img *im)
{
	char tmp[1560];
	snprintf(tmp, sizeof tmp, "%s.part", file);
	FILE *f = fopen(tmp, "wb");
	if (!f) return -1;
	fprintf(f, "P6\n%d %d\n255\n", im->w, im->h);
	size_t n = (size_t)im->w * (size_t)im->h * 3;
	int ok = fwrite(im->rgb, 1, n, f) == n;
	ok = (fclose(f) == 0) && ok;
	if (!ok || rename(tmp, file) < 0) { unlink(tmp); return -1; }
	return 0;
}

static struct wl_buffer *make_buffer(int w, int h, int stride, uint32_t fmt, uint8_t **mem, size_t *len)
{
	*len = (size_t)stride * (size_t)h;
	int fd = memfd_create("rsw", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, (off_t)*len) < 0) { if (fd >= 0) close(fd); return NULL; }
	*mem = mmap(NULL, *len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (*mem == MAP_FAILED) { close(fd); return NULL; }
	struct wl_shm_pool *p = wl_shm_create_pool(shm, fd, (int)*len);
	struct wl_buffer *b = wl_shm_pool_create_buffer(p, 0, w, h, stride, fmt);
	wl_shm_pool_destroy(p);
	close(fd);
	return b;
}

/* ---- a still of the screen (wlr-screencopy) ------------------------------------------------------------------ */

struct shot { char file[1536]; int desat, outw; uint32_t fmt; int w, h, stride, yinv; struct wl_buffer *buf; uint8_t *mem; size_t len; struct zwlr_screencopy_frame_v1 *fr; };

static void shot_end(struct shot *s, int ok)
{
	if (ok) {
		struct img im;
		if (to_rgb(&im, s->mem, s->w, s->h, s->stride, s->fmt, s->yinv, s->outw, s->desat) == 0) {
			if (write_ppm(s->file, &im) == 0) out("shot %s %d %d", s->file, im.w, im.h); else ok = 0;
			free(im.rgb);
		} else ok = 0;
	}
	if (!ok) out("shot %s fail", s->file);
	if (s->buf) wl_buffer_destroy(s->buf);
	if (s->mem) munmap(s->mem, s->len);
	zwlr_screencopy_frame_v1_destroy(s->fr);
	free(s);
}
static void sf_buffer(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t fmt, uint32_t w, uint32_t h, uint32_t stride)
{
	(void)f;
	struct shot *s = d;
	if (!shm_format_ok(fmt) || s->buf) return;
	s->fmt = fmt; s->w = (int)w; s->h = (int)h; s->stride = (int)stride;
	s->buf = make_buffer(s->w, s->h, s->stride, fmt, &s->mem, &s->len);
}
static void sf_flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t fl) { (void)f; ((struct shot *)d)->yinv = fl & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT; }
static void sf_ready(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c) { (void)f; (void)a; (void)b; (void)c; shot_end(d, 1); }
static void sf_failed(void *d, struct zwlr_screencopy_frame_v1 *f) { (void)f; shot_end(d, 0); }
static void sf_damage(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c, uint32_t e) { (void)d; (void)f; (void)a; (void)b; (void)c; (void)e; }
static void sf_dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c) { (void)d; (void)f; (void)a; (void)b; (void)c; }
static void sf_done(void *d, struct zwlr_screencopy_frame_v1 *f)
{
	struct shot *s = d;
	if (!s->buf) { shot_end(s, 0); return; }
	zwlr_screencopy_frame_v1_copy(f, s->buf);
}
static const struct zwlr_screencopy_frame_v1_listener sfl = { sf_buffer, sf_flags, sf_ready, sf_failed, sf_damage, sf_dmabuf, sf_done };

static int all_digits(const char *t)
{
	if (!*t) return 0;
	for (; *t; t++) if (*t < '0' || *t > '9') return 0;
	return 1;
}

/* The output called NAME; with NAME "" (or outputs that never said their names) the first one. */
static struct wl_output *output_named(const char *name)
{
	struct outp *p, *first = NULL;
	int named = 0;
	wl_list_for_each_reverse(p, &outs, link) {
		if (!first) first = p;
		if (p->name) named = 1;
		if (*name && p->name && !strcmp(p->name, name)) return p->o;
	}
	if (!first || (*name && named)) return NULL;
	return first->o;
}

/* FILE DESAT [NAME [WIDTH]], read from the end (FILE may hold spaces): a last word that is a number after a word
 * that is not one is WIDTH after NAME; a NAME is never a bare number. */
static void cmd_shot(char *arg)
{
	char *w[3] = { NULL, NULL, NULL };
	int n = 0;
	while (n < 3) {
		char *sp = strrchr(arg, ' ');
		if (!sp) break;
		w[n++] = sp + 1;
		*sp = 0;
	}
	/* w[0] is the last word */
	const char *name = "";
	int desat = -1, width = 0, used = 0;
	if (n >= 3 && all_digits(w[0]) && !all_digits(w[1]) && all_digits(w[2])) { width = atoi(w[0]); name = w[1]; desat = atoi(w[2]); used = 3; }
	else if (n >= 2 && !all_digits(w[0]) && all_digits(w[1])) { name = w[0]; desat = atoi(w[1]); used = 2; }
	else if (n >= 1 && all_digits(w[0])) { desat = atoi(w[0]); used = 1; }
	/* the words that were not ours are the file's */
	for (int i = n - 1; i >= used; i--) arg[strlen(arg)] = ' ';
	struct wl_output *o = desat < 0 ? NULL : output_named(name);
	if (desat < 0 || !scmgr || !o) { out("shot %s fail", n ? arg : "-"); return; }
	struct shot *s = calloc(1, sizeof *s);
	if (!s) { out("shot %s fail", arg); return; }
	snprintf(s->file, sizeof s->file, "%s", arg);
	s->desat = desat;
	s->outw = width;
	s->fr = zwlr_screencopy_manager_v1_capture_output(scmgr, 0, o);
	zwlr_screencopy_frame_v1_add_listener(s->fr, &sfl, s);
}

/* ---- a window (ext-image-copy-capture with a foreign-toplevel source) ----------------------------------------- */

struct top { struct wl_list link; struct ext_foreign_toplevel_handle_v1 *h; char *app, *title; };
static struct wl_list tops;

static void th_closed(void *d, struct ext_foreign_toplevel_handle_v1 *h)
{
	struct top *t = d;
	wl_list_remove(&t->link);
	ext_foreign_toplevel_handle_v1_destroy(h);
	free(t->app); free(t->title); free(t);
}
static void th_done(void *d, struct ext_foreign_toplevel_handle_v1 *h) { (void)d; (void)h; }
static void th_title(void *d, struct ext_foreign_toplevel_handle_v1 *h, const char *s) { (void)h; struct top *t = d; free(t->title); t->title = strdup(s); }
static void th_app(void *d, struct ext_foreign_toplevel_handle_v1 *h, const char *s) { (void)h; struct top *t = d; free(t->app); t->app = strdup(s); }
static void th_id(void *d, struct ext_foreign_toplevel_handle_v1 *h, const char *s) { (void)d; (void)h; (void)s; }
static const struct ext_foreign_toplevel_handle_v1_listener thl = { th_closed, th_done, th_title, th_app, th_id };
static void tl_toplevel(void *d, struct ext_foreign_toplevel_list_v1 *l, struct ext_foreign_toplevel_handle_v1 *h)
{
	(void)d; (void)l;
	struct top *t = calloc(1, sizeof *t);
	t->h = h; t->app = strdup(""); t->title = strdup("");
	wl_list_insert(tops.prev, &t->link);
	ext_foreign_toplevel_handle_v1_add_listener(h, &thl, t);
}
static void tl_finished(void *d, struct ext_foreign_toplevel_list_v1 *l) { (void)d; (void)l; }
static const struct ext_foreign_toplevel_list_v1_listener tll = { tl_toplevel, tl_finished };

struct cap {
	char token[64], file[1536];
	int width, bw, bh, stride, done_once;
	uint32_t fmt;
	struct ext_image_capture_source_v1 *src;
	struct ext_image_copy_capture_session_v1 *sess;
	struct ext_image_copy_capture_frame_v1 *fr;
	struct wl_buffer *buf; uint8_t *mem; size_t len;
};

static void cap_end(struct cap *c, int ok)
{
	if (ok) {
		struct img im;
		if (to_rgb(&im, c->mem, c->bw, c->bh, c->stride, c->fmt, 0, c->width, 0) == 0) {
			if (write_ppm(c->file, &im) == 0) out("cap %s ok %d %d", c->token, im.w, im.h); else ok = 0;
			free(im.rgb);
		} else ok = 0;
	}
	if (!ok) out("cap %s fail", c->token);
	if (c->fr) ext_image_copy_capture_frame_v1_destroy(c->fr);
	if (c->sess) ext_image_copy_capture_session_v1_destroy(c->sess);
	if (c->src) ext_image_capture_source_v1_destroy(c->src);
	if (c->buf) wl_buffer_destroy(c->buf);
	if (c->mem) munmap(c->mem, c->len);
	free(c);
}
static void fr_transform(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t t) { (void)d; (void)f; (void)t; }
static void fr_damage(void *d, struct ext_image_copy_capture_frame_v1 *f, int32_t a, int32_t b, int32_t c, int32_t e) { (void)d; (void)f; (void)a; (void)b; (void)c; (void)e; }
static void fr_time(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t a, uint32_t b, uint32_t c) { (void)d; (void)f; (void)a; (void)b; (void)c; }
static void fr_ready(void *d, struct ext_image_copy_capture_frame_v1 *f) { (void)f; cap_end(d, 1); }
static void fr_failed(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t why) { (void)f; (void)why; cap_end(d, 0); }
static const struct ext_image_copy_capture_frame_v1_listener frl = { fr_transform, fr_damage, fr_time, fr_ready, fr_failed };

static void se_size(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h) { (void)s; struct cap *c = d; c->bw = (int)w; c->bh = (int)h; }
static void se_fmt(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f)
{
	(void)s;
	struct cap *c = d;
	if (!c->fmt && shm_format_ok(f)) c->fmt = f;
}
static void se_dmadev(void *d, struct ext_image_copy_capture_session_v1 *s, struct wl_array *a) { (void)d; (void)s; (void)a; }
static void se_dmafmt(void *d, struct ext_image_copy_capture_session_v1 *s, uint32_t f, struct wl_array *a) { (void)d; (void)s; (void)f; (void)a; }
static void se_done(void *d, struct ext_image_copy_capture_session_v1 *s)
{
	struct cap *c = d;
	if (c->done_once) return;
	c->done_once = 1;
	if (!c->fmt || c->bw <= 0 || c->bh <= 0) { cap_end(c, 0); return; }
	c->stride = c->bw * 4;
	c->buf = make_buffer(c->bw, c->bh, c->stride, c->fmt, &c->mem, &c->len);
	if (!c->buf) { cap_end(c, 0); return; }
	c->fr = ext_image_copy_capture_session_v1_create_frame(s);
	ext_image_copy_capture_frame_v1_add_listener(c->fr, &frl, c);
	ext_image_copy_capture_frame_v1_attach_buffer(c->fr, c->buf);
	ext_image_copy_capture_frame_v1_damage_buffer(c->fr, 0, 0, c->bw, c->bh);
	ext_image_copy_capture_frame_v1_capture(c->fr);
}
static void se_stopped(void *d, struct ext_image_copy_capture_session_v1 *s) { (void)s; cap_end(d, 0); }
static const struct ext_image_copy_capture_session_v1_listener sel = { se_size, se_fmt, se_dmadev, se_dmafmt, se_done, se_stopped };

static void cmd_cap(char *arg)
{
	char token[64], file[1536];
	int width;
	char *tab = strchr(arg, '\t');
	if (sscanf(arg, "%63s %d %1535s", token, &width, file) != 3 || !capmgr || !srcmgr) {
		sscanf(arg, "%63s", token);
		out("cap %s fail", token);
		return;
	}
	const char *app = "", *title = "";
	if (tab) { *tab = 0; app = strrchr(arg, ' ') ? strrchr(arg, ' ') + 1 : ""; title = tab + 1; }
	/* the app id is the last word before the tab; the file name never has a space, nor does an app id */
	struct top *t, *found = NULL;
	wl_list_for_each(t, &tops, link) if (!strcmp(t->app, app) && !strcmp(t->title, title)) { found = t; break; }
	if (!found) { out("cap %s fail", token); return; }
	struct cap *c = calloc(1, sizeof *c);
	snprintf(c->token, sizeof c->token, "%s", token);
	snprintf(c->file, sizeof c->file, "%s", file);
	c->width = width;
	c->src = ext_foreign_toplevel_image_capture_source_manager_v1_create_source(srcmgr, found->h);
	c->sess = ext_image_copy_capture_manager_v1_create_session(capmgr, c->src, 0);
	ext_image_copy_capture_session_v1_add_listener(c->sess, &sel, c);
}

/* ---- the keyboard ------------------------------------------------------------------------------------------ */

static const char *keyname(uint32_t code)
{
	xkb_keysym_t sym = xkb_state_key_get_one_sym(xst, code + 8);
	int shift = xkb_state_mod_name_is_active(xst, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0;
	switch (sym) {
	case XKB_KEY_Tab: return shift ? "btab" : "tab";
	case XKB_KEY_ISO_Left_Tab: return "btab";
	case XKB_KEY_Left: case XKB_KEY_KP_Left: return "left";
	case XKB_KEY_Right: case XKB_KEY_KP_Right: return "right";
	case XKB_KEY_Up: case XKB_KEY_KP_Up: return "up";
	case XKB_KEY_Down: case XKB_KEY_KP_Down: return "down";
	case XKB_KEY_grave: case XKB_KEY_asciitilde: return "grave";
	case XKB_KEY_w: case XKB_KEY_W: return "w";
	case XKB_KEY_q: case XKB_KEY_Q: return "q";
	case XKB_KEY_Escape: return "esc";
	case XKB_KEY_Return: case XKB_KEY_KP_Enter: return "enter";
	}
	return NULL;
}
static int repeats(const char *n) { return !strcmp(n, "tab") || !strcmp(n, "btab") || !strcmp(n, "left") || !strcmp(n, "right") || !strcmp(n, "up") || !strcmp(n, "down") || !strcmp(n, "grave"); }

static void arm(int ms, int every_ms)
{
	struct itimerspec t = { { every_ms / 1000, (every_ms % 1000) * 1000000L }, { ms / 1000, (ms % 1000) * 1000000L } };
	timerfd_settime(tfd, 0, &t, NULL);
}

static void k_keymap(void *d, struct wl_keyboard *k, uint32_t fmt, int fd, uint32_t size)
{
	(void)d; (void)k;
	if (fmt == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
		char *m = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
		if (m != MAP_FAILED) {
			struct xkb_keymap *nm = xkb_keymap_new_from_string(xctx, m, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
			munmap(m, size);
			if (nm) { xkb_state_unref(xst); xkb_keymap_unref(xmap); xmap = nm; xst = xkb_state_new(xmap); }
		}
	}
	close(fd);
}
static void k_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys)
{
	(void)d; (void)k; (void)s;
	if (sf != surf || !surf) return;
	/* the keys held as the keyboard arrives: if Alt is one of them, its release is ours to report */
	alt_held = 0;
	uint32_t *kc;
	wl_array_for_each(kc, keys) if (*kc == KEY_LEFTALT || *kc == KEY_RIGHTALT) alt_held++;
	have_focus = 1; mods_seen = 0;
	out("ready");
}
static void k_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf)
{
	(void)d; (void)k; (void)s;
	if (sf != surf || !surf) return;
	have_focus = 0; rep_key = 0; arm(0, 0);
	out("lost");
}
static void k_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t state)
{
	(void)d; (void)k; (void)s; (void)t;
	if (!xst || !have_focus) return;
	if (key == KEY_LEFTALT || key == KEY_RIGHTALT) {
		if (state == WL_KEYBOARD_KEY_STATE_PRESSED) alt_held++;
		else if (alt_held > 0 && --alt_held == 0) { out("altup"); rep_key = 0; arm(0, 0); }
		return;
	}
	if (state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		const char *n = keyname(key);
		if (!n) return;
		out("key %s", n);
		if (repeats(n) && xmap && xkb_keymap_key_repeats(xmap, key + 8)) { rep_key = key; arm(rep_delay, 1000 / (rep_rate ? rep_rate : 1)); }
	} else if (key == rep_key) { rep_key = 0; arm(0, 0); }
}
static void k_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t dep, uint32_t lat, uint32_t lock, uint32_t grp)
{
	(void)d; (void)k; (void)s;
	if (!xst) return;
	xkb_state_update_mask(xst, dep, lat, lock, 0, 0, grp);
	/* The modifiers event that follows the keyboard's arrival settles a tap: Alt was already up (not among the
	 * keys held and not in the modifiers), so the switch is wanted now and there is no release to wait for. */
	if (have_focus && !mods_seen) {
		mods_seen = 1;
		if (!alt_held && !xkb_state_mod_name_is_active(xst, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE)) out("altup");
	}
}
static void k_repeat(void *d, struct wl_keyboard *k, int32_t rate, int32_t delay) { (void)d; (void)k; rep_rate = rate; rep_delay = delay; }
static const struct wl_keyboard_listener kl = { k_keymap, k_enter, k_leave, k_key, k_mods, k_repeat };

static void s_caps(void *d, struct wl_seat *s, uint32_t caps)
{
	(void)d;
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !kbd) { kbd = wl_seat_get_keyboard(s); wl_keyboard_add_listener(kbd, &kl, NULL); }
	else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && kbd) { wl_keyboard_release(kbd); kbd = NULL; }
}
static void s_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener sl = { s_caps, s_name };

/* ---- the surface -------------------------------------------------------------------------------------------- */

static int configured;
static void l_conf(void *d, struct zwlr_layer_surface_v1 *l, uint32_t serial, uint32_t w, uint32_t h)
{
	(void)d; (void)w; (void)h;
	zwlr_layer_surface_v1_ack_configure(l, serial);
	if (configured) return;
	configured = 1;
	uint8_t *mem; size_t len;
	struct wl_buffer *b = make_buffer(1, 1, 4, WL_SHM_FORMAT_ARGB8888, &mem, &len);
	if (!b) { fprintf(stderr, "ribbon-shell-switch: no memfd\n"); quit_now = 1; return; }
	memset(mem, 0, 4);
	wl_surface_attach(surf, b, 0, 0);
	wl_surface_commit(surf);
	munmap(mem, len);
}
static void drop(void);
static void l_closed(void *d, struct zwlr_layer_surface_v1 *l) { (void)d; (void)l; out("lost"); drop(); }
static const struct zwlr_layer_surface_v1_listener lsl = { l_conf, l_closed };

static void grab(void)
{
	if (surf || !lshell) return;
	configured = 0;
	surf = wl_compositor_create_surface(comp);
	struct wl_region *empty = wl_compositor_create_region(comp);
	wl_surface_set_input_region(surf, empty);
	wl_region_destroy(empty);
	ls = zwlr_layer_shell_v1_get_layer_surface(lshell, surf, NULL, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "ribbon-shell-switch");
	zwlr_layer_surface_v1_add_listener(ls, &lsl, NULL);
	zwlr_layer_surface_v1_set_size(ls, 1, 1);
	zwlr_layer_surface_v1_set_exclusive_zone(ls, -1);
	zwlr_layer_surface_v1_set_keyboard_interactivity(ls, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
	wl_surface_commit(surf);
}
static void drop(void)
{
	if (!surf) return;
	if (ls) zwlr_layer_surface_v1_destroy(ls);
	wl_surface_destroy(surf);
	ls = NULL; surf = NULL; have_focus = 0; rep_key = 0; alt_held = 0; arm(0, 0);
}

static void o_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp, const char *mk, const char *md, int32_t tr)
{ (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sp; (void)mk; (void)md; (void)tr; }
static void o_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) { (void)d; (void)o; (void)f; (void)w; (void)h; (void)r; }
static void o_done(void *d, struct wl_output *o) { (void)d; (void)o; }
static void o_scale(void *d, struct wl_output *o, int32_t f) { (void)d; (void)o; (void)f; }
static void o_name(void *d, struct wl_output *o, const char *n) { (void)o; struct outp *p = d; free(p->name); p->name = strdup(n); }
static void o_desc(void *d, struct wl_output *o, const char *n) { (void)d; (void)o; (void)n; }
static const struct wl_output_listener ol = { o_geometry, o_mode, o_done, o_scale, o_name, o_desc };

static void g_add(void *d, struct wl_registry *r, uint32_t name, const char *ifc, uint32_t ver)
{
	(void)d;
	if (!strcmp(ifc, "wl_compositor")) comp = wl_registry_bind(r, name, &wl_compositor_interface, 4);
	else if (!strcmp(ifc, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
	else if (!strcmp(ifc, "wl_seat") && !seat) { seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5); wl_seat_add_listener(seat, &sl, NULL); }
	else if (!strcmp(ifc, "wl_output")) {
		struct outp *p = calloc(1, sizeof *p);
		if (!p) return;
		p->gname = name;
		p->o = wl_registry_bind(r, name, &wl_output_interface, ver < 4 ? ver : 4);
		wl_output_add_listener(p->o, &ol, p);
		wl_list_insert(&outs, &p->link);
	}
	else if (!strcmp(ifc, "zwlr_layer_shell_v1")) lshell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, 1);
	else if (!strcmp(ifc, "zwlr_screencopy_manager_v1")) scmgr = wl_registry_bind(r, name, &zwlr_screencopy_manager_v1_interface, ver < 3 ? ver : 3);
	else if (!strcmp(ifc, "ext_foreign_toplevel_list_v1")) {
		tlist = wl_registry_bind(r, name, &ext_foreign_toplevel_list_v1_interface, 1);
		ext_foreign_toplevel_list_v1_add_listener(tlist, &tll, NULL); /* now: the toplevels come at once */
	}
	else if (!strcmp(ifc, "ext_foreign_toplevel_image_capture_source_manager_v1"))
		srcmgr = wl_registry_bind(r, name, &ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1);
	else if (!strcmp(ifc, "ext_image_copy_capture_manager_v1")) capmgr = wl_registry_bind(r, name, &ext_image_copy_capture_manager_v1_interface, 1);
}
static void g_del(void *d, struct wl_registry *r, uint32_t n)
{
	(void)d; (void)r;
	struct outp *p, *t;
	wl_list_for_each_safe(p, t, &outs, link) {
		if (p->gname != n) continue;
		wl_list_remove(&p->link);
		if (wl_output_get_version(p->o) >= 3) wl_output_release(p->o); else wl_output_destroy(p->o);
		free(p->name); free(p);
	}
}
static const struct wl_registry_listener gl = { g_add, g_del };

static void command(char *line)
{
	if (!strcmp(line, "grab")) grab();
	else if (!strcmp(line, "release")) drop();
	else if (!strncmp(line, "shot ", 5)) cmd_shot(line + 5);
	else if (!strncmp(line, "cap ", 4)) cmd_cap(line + 4);
	else if (!strcmp(line, "caps")) out("caps%s%s", scmgr ? " shot" : "", capmgr && srcmgr && tlist ? " cap" : "");
	else if (!strcmp(line, "quit")) quit_now = 1;
}

int main(void)
{
	signal(SIGPIPE, SIG_IGN);
	wl_list_init(&tops);
	wl_list_init(&outs);
	dpy = wl_display_connect(NULL);
	if (!dpy) { fprintf(stderr, "ribbon-shell-switch: no Wayland display\n"); return 2; }
	wl_registry_add_listener(wl_display_get_registry(dpy), &gl, NULL);
	wl_display_roundtrip(dpy);
	if (!comp || !shm || !seat) { fprintf(stderr, "ribbon-shell-switch: compositor lacks wl_compositor/wl_shm/wl_seat\n"); return 2; }
	xctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	wl_display_roundtrip(dpy);
	out("hello");

	char cmd[1536]; size_t cl = 0;
	while (!quit_now) {
		wl_display_flush(dpy);
		struct pollfd p[3] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { 0, POLLIN, 0 }, { tfd, POLLIN, 0 } };
		while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
		wl_display_flush(dpy);
		if (poll(p, 3, -1) < 0 && errno != EINTR) { wl_display_cancel_read(dpy); break; }
		if (p[0].revents & POLLIN) { if (wl_display_read_events(dpy) < 0) break; } else wl_display_cancel_read(dpy);
		if (wl_display_dispatch_pending(dpy) < 0) break;
		if (p[2].revents & POLLIN) {
			uint64_t x;
			if (read(tfd, &x, sizeof x) > 0 && rep_key && have_focus) { const char *n = keyname(rep_key); if (n) out("key %s", n); }
		}
		if (p[1].revents & (POLLIN | POLLHUP)) {
			char buf[1024];
			ssize_t r = read(0, buf, sizeof buf);
			if (r <= 0) break;
			for (ssize_t i = 0; i < r; i++) {
				if (buf[i] != '\n') { if (cl < sizeof cmd - 1) cmd[cl++] = buf[i]; continue; }
				cmd[cl] = 0; cl = 0;
				command(cmd);
			}
		}
	}
	return 0;
}
