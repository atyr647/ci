/* hud-surface.c - ribbon-hud-surface: the Game HUD's on-screen surface (U23).
 *
 * A wlr-layer-shell surface on the OVERLAY layer, anchored top-left and placed with margins, with keyboard
 * interactivity none and an EMPTY input region: the compositor never gives it the keyboard and every click goes to the
 * client below (a fullscreen game included). The HUD (apps/hud, Tcl) lays the panel out as drawing ops in screen pixels
 * (hud-draw.tcl); this program draws them with cairo into an ARGB buffer, so the glass is truly see-through (Tk cannot
 * put alpha under its text, and under XWayland an X input shape does not let clicks through: docs in design/handoff/u23.md).
 *
 * stdin, one command per line, fields separated by TAB:
 *   frame                       start collecting ops
 *   rrect x y w h r fill alpha ringcolour ringw dy blur shadowalpha shadowcolour    ("-" for no ring; blur 0 for no shadow)
 *   rect x y w h colour
 *   text x y anchor family px colour string        anchor w, e or c (vertical centre on y, as Tk draws)
 *   line x1 y1 x2 y2 width colour dash             dash "-" or "on off"
 *   poly colour x y x y ...      filled polygon
 *   pline width colour x y ...   open polyline, round joins and caps
 *   image x y w h path          a PNG (the game's art, made by hud-art.tcl) at x y, scaled to w x h if it is not that size
 *   end                         draw the collected ops and show them (no ops: hide the surface)
 *   region x y w h [x y w h ..] input rectangles in screen pixels; "region" alone: none (the default, nothing is taken)
 *   keyboard 0|1                1: the surface asks for the keyboard (exclusive: the quick menu is open; the game gets
 *                               no keys), 0: none (the default)
 *   grab 0|1                    1: the controllers' events go to this program only (EVIOCGRAB) while the menu is open
 *   snapshot PATH               write the current picture as a PNG (tests)
 *   ping                        answer "pong"
 *   quit
 * stdout: "hello W H" (the output's logical size, once), "mapped X Y W H" after the surface shows at that box,
 *         "hidden", "click X Y" (a button press in an input rectangle, screen pixels), "pong", "closed",
 *         "key CODE" and "keyup CODE" (a key pressed and let go while the surface has the keyboard: a Linux input
 *         code), "repeat RATE DELAY" (the compositor's key repeat: per second, ms; the daemon repeats held keys),
 *         "focus 0|1" (the keyboard came or went), "motion X Y" and "leave" (the pointer over an input rectangle, screen
 *         pixels; the HUD's buttons' tooltips),
 *         "pad home|a|b|up|down|left|right" (a controller button, read with evdev from every game controller under
 *         /dev/input, or RIBBON_HUD_INPUT: devices that come later are found through inotify; a test may put FIFOs
 *         there that carry struct input_event records).
 * Game controllers are the event devices with the gamepad buttons (BTN_SOUTH) or a home button (BTN_MODE); on a
 * Ribbon seat they are the session user's (elogind's uaccess). The home button is BTN_MODE, A BTN_SOUTH, B BTN_EAST,
 * the d-pad BTN_DPAD_* or the first hat.
 * End of input quits. */
#define _GNU_SOURCE
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <linux/input.h>
#include <cairo.h>
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

static struct wl_display *dpy;
static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct zwlr_layer_shell_v1 *lshell;
static struct wl_seat *seat;
static struct wl_output *out;
static int out_w, out_h, out_scale = 1, out_transform;

static struct wl_surface *surf;
static struct zwlr_layer_surface_v1 *lsurf;
static int configured;
static int cfg_w, cfg_h;           /* the size the compositor last configured */
static int box_x, box_y, box_w, box_h;   /* the box of the picture, screen pixels */
static cairo_surface_t *pic;       /* the current picture, premultiplied ARGB */
static struct wl_buffer *buf;
static int shown_box_w, shown_box_h, shown_x, shown_y;
static int pending;                /* a picture waits to be attached */
static int regions[64][4], nreg;
static int sx, sy;                 /* the pointer in surface-local pixels */
static int want_kb;                /* the quick menu wants the keyboard */

/* ---------------- ops ---------------- */
#define MAXOPS 4096
static char *ops[MAXOPS];
static int nops;
static int collecting;

static void clear_ops(void) { for (int i = 0; i < nops; i++) free(ops[i]); nops = 0; }

static void colour(cairo_t *cr, const char *hex, double a)
{
	unsigned r = 0, g = 0, b = 0;
	if (hex && hex[0] == '#') sscanf(hex + 1, "%2x%2x%2x", &r, &g, &b);
	cairo_set_source_rgba(cr, r / 255.0, g / 255.0, b / 255.0, a);
}

static void rrpath(cairo_t *cr, double x, double y, double w, double h, double r)
{
	if (r > w / 2) r = w / 2;
	if (r > h / 2) r = h / 2;
	cairo_new_sub_path(cr);
	if (r <= 0) { cairo_rectangle(cr, x, y, w, h); return; }
	cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
	cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
	cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
	cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
	cairo_close_path(cr);
}

/* split a line at TABs in place; returns the number of fields */
static int split(char *s, char **f, int max)
{
	int n = 0;
	while (n < max) {
		f[n++] = s;
		char *t = strchr(s, '\t');
		if (!t) break;
		*t = 0; s = t + 1;
	}
	return n;
}

static double rowpad(int n, char **f, double *blur, double *dy)
{
	*blur = 0; *dy = 0;
	if (n >= 14 && atof(f[11]) > 0) { *blur = atof(f[11]); *dy = atof(f[10]); }
	return ceil(*blur * 1.5);
}

/* the box of everything drawn: ops in screen pixels, shadows included */
static void bounds(double *x0, double *y0, double *x1, double *y1)
{
	*x0 = *y0 = 1e9; *x1 = *y1 = -1e9;
	for (int i = 0; i < nops; i++) {
		char *line = strdup(ops[i]), *f[40];
		int n = split(line, f, 40);
		if (!strcmp(f[0], "rrect") && n >= 14) {
			double blur, dy, pad = rowpad(n, f, &blur, &dy);
			double x = atof(f[1]), y = atof(f[2]), w = atof(f[3]), h = atof(f[4]);
			double t = y - pad + (dy < 0 ? dy : 0), b = y + h + pad + (dy > 0 ? dy : 0);
			if (x - pad < *x0) *x0 = x - pad;
			if (t < *y0) *y0 = t;
			if (x + w + pad > *x1) *x1 = x + w + pad;
			if (b > *y1) *y1 = b;
		}
		free(line);
	}
	if (*x1 < *x0) { *x0 = *y0 = 0; *x1 = *y1 = 0; }
	*x0 = floor(*x0); *y0 = floor(*y0); *x1 = ceil(*x1); *y1 = ceil(*y1);
	/* the surface stays on its output: a shadow that would run off the edge is cut there */
	int lw = (out_transform & 1) ? out_h : out_w, lh = (out_transform & 1) ? out_w : out_h, sc = out_scale > 0 ? out_scale : 1;
	if (*x0 < 0) *x0 = 0;
	if (*y0 < 0) *y0 = 0;
	if (lw > 0 && *x1 > lw / sc) *x1 = lw / sc;
	if (lh > 0 && *y1 > lh / sc) *y1 = lh / sc;
}

static void draw_rrect(cairo_t *cr, char **f, int n)
{
	if (n < 14) return;
	double x = atof(f[1]), y = atof(f[2]), w = atof(f[3]), h = atof(f[4]), r = atof(f[5]), alpha = atof(f[7]);
	double rw = atof(f[9]), dy = atof(f[10]), blur = atof(f[11]), sa = atof(f[12]);
	if (blur > 0) {
		/* CSS "0 dy blur rgba": a Gaussian-blurred copy of the box, sigma blur/2, drawn outside the box only
		 * (the glass is see-through, so nothing may lie under it). Same formula as raster.tcl. */
		int pad = (int)ceil(blur * 1.5);
		int mw = (int)ceil(w) + 2 * pad, mh = (int)ceil(h) + 2 * pad + 2 * (int)fabs(dy);
		double ox = x - pad, oy = y - pad - fabs(dy);
		cairo_surface_t *m = cairo_image_surface_create(CAIRO_FORMAT_A8, mw, mh);
		unsigned char *d = cairo_image_surface_get_data(m); int st = cairo_image_surface_get_stride(m);
		double k = 1.0 / (blur / 2.0 * sqrt(2.0)), *fx = malloc(sizeof(double) * (size_t)mw), *fy = malloc(sizeof(double) * (size_t)mh);
		for (int i = 0; i < mw; i++) { double p = i + 0.5 + ox - x; fx[i] = 0.5 * (erf(p * k) - erf((p - w) * k)); }
		for (int j = 0; j < mh; j++) { double p = j + 0.5 + oy - dy - y; fy[j] = 0.5 * (erf(p * k) - erf((p - h) * k)); }
		for (int j = 0; j < mh; j++) for (int i = 0; i < mw; i++) d[j * st + i] = (unsigned char)(sa * fy[j] * fx[i] * 255.0 + 0.5);
		cairo_surface_mark_dirty(m);
		free(fx); free(fy);
		cairo_save(cr);
		cairo_rectangle(cr, -1e5, -1e5, 2e5, 2e5);
		rrpath(cr, x, y, w, h, r);
		cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
		cairo_clip(cr);
		colour(cr, f[13], 1.0);
		cairo_mask_surface(cr, m, ox, oy);
		cairo_restore(cr);
		cairo_surface_destroy(m);
	}
	rrpath(cr, x, y, w, h, r);
	colour(cr, f[6], alpha);
	cairo_fill(cr);
	if (strcmp(f[8], "-") && rw > 0) {
		cairo_save(cr);
		rrpath(cr, x, y, w, h, r);
		rrpath(cr, x + rw, y + rw, w - 2 * rw, h - 2 * rw, r > rw ? r - rw : 0);
		cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
		colour(cr, f[8], 1.0);
		cairo_fill(cr);
		cairo_restore(cr);
	}
}

static void draw_text(cairo_t *cr, char **f, int n)
{
	if (n < 8) return;
	double x = atof(f[1]), y = atof(f[2]), px = atof(f[5]);
	cairo_font_options_t *fo = cairo_font_options_create();
	cairo_font_options_set_antialias(fo, CAIRO_ANTIALIAS_GRAY);
	cairo_font_options_set_hint_style(fo, CAIRO_HINT_STYLE_NONE);
	cairo_font_options_set_hint_metrics(fo, CAIRO_HINT_METRICS_OFF);
	cairo_set_font_options(cr, fo);
	cairo_font_options_destroy(fo);
	cairo_select_font_face(cr, f[4], CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
	cairo_set_font_size(cr, px);
	cairo_font_extents_t fe; cairo_font_extents(cr, &fe);
	cairo_text_extents_t te; cairo_text_extents(cr, f[7], &te);
	double bx = x;
	if (f[3][0] == 'e') bx = x - te.x_advance; else if (f[3][0] == 'c') bx = x - te.x_advance / 2;
	/* Tk centres the line box (ascent + descent) on y for the anchors w, e and c */
	double by = y + (fe.ascent - fe.descent) / 2;
	colour(cr, f[6], 1.0);
	cairo_move_to(cr, bx, by);
	cairo_show_text(cr, f[7]);
}

/* the PNGs of the image op, read once each (the last few) */
#define NIMG 8
static struct { char *path; cairo_surface_t *s; } imgs[NIMG];
static int img_next;

static cairo_surface_t *image_of(const char *path)
{
	for (int i = 0; i < NIMG; i++)
		if (imgs[i].path && !strcmp(imgs[i].path, path)) return imgs[i].s;
	cairo_surface_t *s = cairo_image_surface_create_from_png(path);
	if (cairo_surface_status(s) != CAIRO_STATUS_SUCCESS) { cairo_surface_destroy(s); s = NULL; }
	int k = img_next++ % NIMG;
	free(imgs[k].path);
	if (imgs[k].s) cairo_surface_destroy(imgs[k].s);
	imgs[k].path = strdup(path);
	imgs[k].s = s;
	return s;
}

static void draw_image(cairo_t *cr, char **f, int n)
{
	if (n < 6) return;
	cairo_surface_t *s = image_of(f[5]);
	if (!s) return;
	double x = atof(f[1]), y = atof(f[2]), w = atof(f[3]), h = atof(f[4]);
	int iw = cairo_image_surface_get_width(s), ih = cairo_image_surface_get_height(s);
	if (iw <= 0 || ih <= 0 || w <= 0 || h <= 0) return;
	cairo_save(cr);
	cairo_translate(cr, x, y);
	if (iw != (int)w || ih != (int)h) cairo_scale(cr, w / iw, h / ih);
	cairo_set_source_surface(cr, s, 0, 0);
	if (iw != (int)w || ih != (int)h) cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
	cairo_paint(cr);
	cairo_restore(cr);
}

static void draw_all(cairo_t *cr)
{
	for (int i = 0; i < nops; i++) {
		char *line = strdup(ops[i]), *f[512];
		int n = split(line, f, 512);
		const char *op = f[0];
		if (!strcmp(op, "rrect")) draw_rrect(cr, f, n);
		else if (!strcmp(op, "rect") && n >= 6) {
			/* Tk fills whole pixels: round the edges */
			double x0 = round(atof(f[1])), y0 = round(atof(f[2])), x1 = round(atof(f[1]) + atof(f[3])), y1 = round(atof(f[2]) + atof(f[4]));
			cairo_rectangle(cr, x0, y0, x1 - x0, y1 - y0); colour(cr, f[5], 1.0); cairo_fill(cr);
		} else if (!strcmp(op, "text")) draw_text(cr, f, n);
		else if (!strcmp(op, "image")) draw_image(cr, f, n);
		else if (!strcmp(op, "line") && n >= 8) {
			cairo_save(cr);
			cairo_set_line_width(cr, atof(f[5]));
			if (strcmp(f[7], "-")) { double a = 0, b = 0; sscanf(f[7], "%lf %lf", &a, &b); double dd[2] = { a, b ? b : a }; cairo_set_dash(cr, dd, 2, 0); }
			cairo_move_to(cr, atof(f[1]), atof(f[2])); cairo_line_to(cr, atof(f[3]), atof(f[4]));
			colour(cr, f[6], 1.0); cairo_stroke(cr);
			cairo_restore(cr);
		} else if (!strcmp(op, "poly") && n >= 6) {
			for (int k = 2; k + 1 < n; k += 2) { if (k == 2) cairo_move_to(cr, atof(f[k]), atof(f[k + 1])); else cairo_line_to(cr, atof(f[k]), atof(f[k + 1])); }
			cairo_close_path(cr); colour(cr, f[1], 1.0); cairo_fill(cr);
		} else if (!strcmp(op, "pline") && n >= 5) {
			cairo_save(cr);
			cairo_set_line_width(cr, atof(f[1]));
			cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND); cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
			for (int k = 3; k + 1 < n; k += 2) { if (k == 3) cairo_move_to(cr, atof(f[k]), atof(f[k + 1])); else cairo_line_to(cr, atof(f[k]), atof(f[k + 1])); }
			colour(cr, f[2], 1.0); cairo_stroke(cr);
			cairo_restore(cr);
		}
		free(line);
	}
}

/* ---------------- surface ---------------- */
static void reg_input(void)
{
	struct wl_region *r = wl_compositor_create_region(comp);
	for (int i = 0; i < nreg; i++) {
		int x = regions[i][0] - box_x, y = regions[i][1] - box_y;
		wl_region_add(r, x, y, regions[i][2], regions[i][3]);
	}
	wl_surface_set_input_region(surf, r);   /* an empty region: no input at all */
	wl_region_destroy(r);
}

static void present(void)
{
	if (!surf || !configured || !pending || !pic) return;
	if (cfg_w != box_w || cfg_h != box_h) return;   /* waiting for the configure of the new size */
	int sc = out_scale > 0 ? out_scale : 1;
	int bw = box_w * sc, bh = box_h * sc, stride = cairo_image_surface_get_stride(pic);
	size_t sz = (size_t)stride * (size_t)bh;
	int fd = memfd_create("hud", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, (off_t)sz) < 0) { perror("memfd"); exit(1); }
	void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	memcpy(p, cairo_image_surface_get_data(pic), sz);
	munmap(p, sz);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)sz);
	struct wl_buffer *nb = wl_shm_pool_create_buffer(pool, 0, bw, bh, stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool); close(fd);
	if (buf) wl_buffer_destroy(buf);
	buf = nb;
	reg_input();
	wl_surface_set_buffer_scale(surf, sc);
	wl_surface_attach(surf, buf, 0, 0);
	wl_surface_damage(surf, 0, 0, box_w, box_h);
	wl_surface_commit(surf);
	pending = 0;
	if (shown_x != box_x || shown_y != box_y || shown_box_w != box_w || shown_box_h != box_h) {
		shown_x = box_x; shown_y = box_y; shown_box_w = box_w; shown_box_h = box_h;
	}
	printf("mapped %d %d %d %d\n", box_x, box_y, box_w, box_h); fflush(stdout);
}

static void l_conf(void *d, struct zwlr_layer_surface_v1 *l, uint32_t serial, uint32_t w, uint32_t h)
{
	(void)d;
	zwlr_layer_surface_v1_ack_configure(l, serial);
	cfg_w = (int)w; cfg_h = (int)h; configured = 1;
	present();
}
static void l_closed(void *d, struct zwlr_layer_surface_v1 *l)
{
	(void)d; (void)l;
	puts("closed"); fflush(stdout);
	exit(0);
}
static const struct zwlr_layer_surface_v1_listener lsl = { l_conf, l_closed };

static void hide_surface(void)
{
	if (!surf) return;
	zwlr_layer_surface_v1_destroy(lsurf); wl_surface_destroy(surf);
	surf = NULL; lsurf = NULL; configured = 0; cfg_w = cfg_h = 0; pending = 0;
	if (buf) { wl_buffer_destroy(buf); buf = NULL; }
	puts("hidden"); fflush(stdout);
}

static void show_surface(void)
{
	if (!surf) {
		surf = wl_compositor_create_surface(comp);
		lsurf = zwlr_layer_shell_v1_get_layer_surface(lshell, surf, out, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "ribbon-hud");
		zwlr_layer_surface_v1_add_listener(lsurf, &lsl, NULL);
		zwlr_layer_surface_v1_set_anchor(lsurf, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
		zwlr_layer_surface_v1_set_exclusive_zone(lsurf, -1);
		configured = 0;
	}
	zwlr_layer_surface_v1_set_keyboard_interactivity(lsurf, want_kb ? ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE
		: ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	zwlr_layer_surface_v1_set_size(lsurf, (uint32_t)box_w, (uint32_t)box_h);
	zwlr_layer_surface_v1_set_margin(lsurf, box_y, 0, 0, box_x);
	/* the input region is empty from the first commit, before the surface can ever be hit */
	reg_input();
	wl_surface_commit(surf);
	pending = 1;
	present();
}

static void render_and_show(void)
{
	if (nops == 0) { hide_surface(); return; }
	double x0, y0, x1, y1;
	bounds(&x0, &y0, &x1, &y1);
	int sc = out_scale > 0 ? out_scale : 1;
	int w = (int)(x1 - x0), h = (int)(y1 - y0);
	if (w <= 0 || h <= 0) { hide_surface(); return; }
	if (pic) cairo_surface_destroy(pic);
	pic = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w * sc, h * sc);
	cairo_surface_set_device_scale(pic, sc, sc);
	cairo_t *cr = cairo_create(pic);
	cairo_translate(cr, -x0, -y0);
	cairo_set_antialias(cr, CAIRO_ANTIALIAS_GRAY);
	draw_all(cr);
	cairo_destroy(cr);
	cairo_surface_flush(pic);
	box_x = (int)x0; box_y = (int)y0; box_w = w; box_h = h;
	show_surface();
}

/* ---------------- pointer (only when an input region exists) ---------------- */
static void po_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *f, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)p; (void)s; (void)f;
	sx = wl_fixed_to_int(x); sy = wl_fixed_to_int(y);
	printf("motion %d %d\n", sx + box_x, sy + box_y); fflush(stdout);
}
static void po_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *f)
{ (void)d; (void)p; (void)s; (void)f; puts("leave"); fflush(stdout); }
static void po_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)p; (void)t;
	int nx = wl_fixed_to_int(x), ny = wl_fixed_to_int(y);
	if (nx == sx && ny == sy) return;
	sx = nx; sy = ny;
	printf("motion %d %d\n", sx + box_x, sy + box_y); fflush(stdout);
}
static void po_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t st)
{
	(void)d; (void)p; (void)s; (void)t; (void)b;
	if (st == WL_POINTER_BUTTON_STATE_PRESSED) { printf("click %d %d\n", sx + box_x, sy + box_y); fflush(stdout); }
}
static void po_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) { (void)d; (void)p; (void)t; (void)a; (void)v; }
static const struct wl_pointer_listener pol = { .enter = po_enter, .leave = po_leave, .motion = po_motion, .button = po_button, .axis = po_axis };
/* ---------------- keyboard (only while the surface asks for it) ---------------- */
static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t sz) { (void)d; (void)k; (void)f; (void)sz; close(fd); }
static void kb_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *f, struct wl_array *keys)
{ (void)d; (void)k; (void)s; (void)f; (void)keys; puts("focus 1"); fflush(stdout); }
static void kb_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *f)
{ (void)d; (void)k; (void)s; (void)f; puts("focus 0"); fflush(stdout); }
static void kb_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t st)
{
	(void)d; (void)k; (void)s; (void)t;
	if (!want_kb) return;
	printf(st == WL_KEYBOARD_KEY_STATE_PRESSED ? "key %u\n" : "keyup %u\n", key); fflush(stdout);
}
static void kb_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g)
{ (void)d; (void)k; (void)s; (void)a; (void)b; (void)c; (void)g; }
static void kb_repeat(void *d, struct wl_keyboard *k, int32_t r, int32_t dl) { (void)d; (void)k; printf("repeat %d %d\n", r, dl); fflush(stdout); }
static const struct wl_keyboard_listener kbl = { kb_keymap, kb_enter, kb_leave, kb_key, kb_mods, kb_repeat };

static void s_caps(void *d, struct wl_seat *s, uint32_t c)
{
	(void)d;
	static int has_ptr, has_kb;
	if ((c & WL_SEAT_CAPABILITY_POINTER) && !has_ptr) { wl_pointer_add_listener(wl_seat_get_pointer(s), &pol, NULL); has_ptr = 1; }
	if ((c & WL_SEAT_CAPABILITY_KEYBOARD) && !has_kb) { wl_keyboard_add_listener(wl_seat_get_keyboard(s), &kbl, NULL); has_kb = 1; }
}
static void s_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener sl = { s_caps, s_name };

/* ---------------- registry ---------------- */
static void o_geom(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sub, const char *mk, const char *md, int32_t tr)
{ (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sub; (void)mk; (void)md; out_transform = tr; }
static void o_mode(void *d, struct wl_output *o, uint32_t fl, int32_t w, int32_t h, int32_t r)
{ (void)d; (void)o; (void)r; if (fl & WL_OUTPUT_MODE_CURRENT) { out_w = w; out_h = h; } }
static void o_done(void *d, struct wl_output *o) { (void)d; (void)o; }
static void o_scale(void *d, struct wl_output *o, int32_t s) { (void)d; (void)o; out_scale = s; }
static const struct wl_output_listener ol = { .geometry = o_geom, .mode = o_mode, .done = o_done, .scale = o_scale };
static void g_add(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v)
{
	(void)d;
	if (!strcmp(i, "wl_compositor")) comp = wl_registry_bind(r, n, &wl_compositor_interface, 4);
	else if (!strcmp(i, "wl_shm")) shm = wl_registry_bind(r, n, &wl_shm_interface, 1);
	else if (!strcmp(i, "zwlr_layer_shell_v1")) lshell = wl_registry_bind(r, n, &zwlr_layer_shell_v1_interface, v < 4 ? v : 4);
	else if (!strcmp(i, "wl_seat") && !seat) { seat = wl_registry_bind(r, n, &wl_seat_interface, v < 4 ? v : 4); wl_seat_add_listener(seat, &sl, NULL); }
	else if (!strcmp(i, "wl_output") && !out) { out = wl_registry_bind(r, n, &wl_output_interface, v < 2 ? v : 2); wl_output_add_listener(out, &ol, NULL); }
}
static void g_del(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener gl = { g_add, g_del };

/* ---------------- game controllers (evdev) ---------------- */
#define MAXPADS 16
static struct { int fd; char name[64]; int hx, hy; } pads[MAXPADS];
static int npads, ino = -1, grabbed;
static char indir[256] = "/dev/input";

#define BITS(n) (((n) + 8 * sizeof(long) - 1) / (8 * sizeof(long)))
static int bit(const unsigned long *b, int n) { return (int)((b[n / (8 * sizeof(long))] >> (n % (8 * sizeof(long)))) & 1); }

static void pad_open(const char *name)
{
	if (strncmp(name, "event", 5) || npads >= MAXPADS) return;
	for (int i = 0; i < npads; i++) if (!strcmp(pads[i].name, name)) return;
	char path[512]; snprintf(path, sizeof path, "%s/%s", indir, name);
	struct stat st;
	if (stat(path, &st) < 0) return;
	int fifo = S_ISFIFO(st.st_mode);
	int fd = open(path, (fifo ? O_RDWR : O_RDONLY) | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) return;
	if (!fifo) {
		/* a controller has the gamepad buttons or a home button */
		unsigned long keys[BITS(KEY_MAX + 1)];
		memset(keys, 0, sizeof keys);
		if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keys), keys) < 0 || !(bit(keys, BTN_SOUTH) || bit(keys, BTN_MODE))) { close(fd); return; }
		if (grabbed) ioctl(fd, EVIOCGRAB, 1);
	}
	pads[npads].fd = fd; pads[npads].hx = pads[npads].hy = 0;
	snprintf(pads[npads].name, sizeof pads[npads].name, "%s", name);
	npads++;
}

static void pad_close(int i)
{
	close(pads[i].fd);
	pads[i] = pads[--npads];
}

static void pads_start(void)
{
	const char *e = getenv("RIBBON_HUD_INPUT");
	if (e && *e) snprintf(indir, sizeof indir, "%s", e);
	ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (ino >= 0 && inotify_add_watch(ino, indir, IN_CREATE | IN_ATTRIB) < 0) { close(ino); ino = -1; }
	DIR *d = opendir(indir);
	if (!d) return;
	struct dirent *de;
	while ((de = readdir(d))) pad_open(de->d_name);
	closedir(d);
}

static void pads_grab(int on)
{
	grabbed = on;
	for (int i = 0; i < npads; i++) ioctl(pads[i].fd, EVIOCGRAB, on);   /* fails harmlessly on a FIFO */
}

static void pad_say(const char *b) { printf("pad %s\n", b); fflush(stdout); }

static void pad_read(int i)
{
	struct input_event ev[32];
	for (;;) {
		ssize_t n = read(pads[i].fd, ev, sizeof ev);
		if (n < 0 && errno == EAGAIN) return;
		if (n <= 0) { pad_close(i); return; }   /* unplugged */
		for (size_t k = 0; k < (size_t)n / sizeof ev[0]; k++) {
			struct input_event *e = &ev[k];
			if (e->type == EV_KEY && e->value == 1) {
				switch (e->code) {
				case BTN_MODE: pad_say("home"); break;
				case BTN_SOUTH: pad_say("a"); break;
				case BTN_EAST: pad_say("b"); break;
				case BTN_DPAD_UP: pad_say("up"); break;
				case BTN_DPAD_DOWN: pad_say("down"); break;
				case BTN_DPAD_LEFT: pad_say("left"); break;
				case BTN_DPAD_RIGHT: pad_say("right"); break;
				}
			} else if (e->type == EV_ABS && (e->code == ABS_HAT0X || e->code == ABS_HAT0Y)) {
				int *h = e->code == ABS_HAT0X ? &pads[i].hx : &pads[i].hy, v = e->value > 0 ? 1 : e->value < 0 ? -1 : 0;
				if (v && v != *h) pad_say(e->code == ABS_HAT0X ? (v < 0 ? "left" : "right") : (v < 0 ? "up" : "down"));
				*h = v;
			}
		}
	}
}

static void ino_read(void)
{
	char b[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
	ssize_t n;
	while ((n = read(ino, b, sizeof b)) > 0)
		for (char *p = b; p < b + n; ) {
			struct inotify_event *ie = (struct inotify_event *)p;
			if (ie->len) pad_open(ie->name);   /* a new node, or its permissions set by udev after it appeared */
			p += sizeof *ie + ie->len;
		}
}

/* ---------------- commands ---------------- */
static void command(char *line)
{
	line[strcspn(line, "\n")] = 0;
	if (!strcmp(line, "frame")) { clear_ops(); collecting = 1; return; }
	if (!strcmp(line, "end")) { collecting = 0; render_and_show(); return; }
	if (collecting) { if (nops < MAXOPS) ops[nops++] = strdup(line); return; }
	if (!strncmp(line, "region", 6)) {
		nreg = 0;
		char *s = line + 6; int x, y, w, h, used;
		while (nreg < 64 && sscanf(s, "%d %d %d %d%n", &x, &y, &w, &h, &used) == 4) {
			regions[nreg][0] = x; regions[nreg][1] = y; regions[nreg][2] = w; regions[nreg][3] = h; nreg++; s += used;
		}
		if (surf) { reg_input(); wl_surface_commit(surf); }
	} else if (!strncmp(line, "keyboard ", 9)) {
		want_kb = atoi(line + 9) != 0;
		if (lsurf) {
			zwlr_layer_surface_v1_set_keyboard_interactivity(lsurf, want_kb ? ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE
				: ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
			wl_surface_commit(surf);
		}
	} else if (!strncmp(line, "grab ", 5)) {
		pads_grab(atoi(line + 5) != 0);
	} else if (!strncmp(line, "snapshot ", 9)) {
		if (pic) cairo_surface_write_to_png(pic, line + 9);
		puts("snapshot"); fflush(stdout);
	} else if (!strcmp(line, "ping")) { puts("pong"); fflush(stdout); }
	else if (!strcmp(line, "quit")) exit(0);
}

int main(void)
{
	dpy = wl_display_connect(NULL);
	if (!dpy) { fputs("ribbon-hud-surface: no Wayland display\n", stderr); return 2; }
	wl_registry_add_listener(wl_display_get_registry(dpy), &gl, NULL);
	wl_display_roundtrip(dpy);
	wl_display_roundtrip(dpy);
	if (!comp || !shm || !lshell) { fputs("ribbon-hud-surface: the compositor has no layer-shell\n", stderr); return 2; }
	int lw = out_w, lh = out_h;
	if (out_transform & 1) { lw = out_h; lh = out_w; }
	if (out_scale < 1) out_scale = 1;
	printf("hello %d %d\n", lw / out_scale, lh / out_scale); fflush(stdout);
	pads_start();

	char inbuf[1 << 20]; size_t have = 0;
	for (;;) {
		while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
		wl_display_flush(dpy);
		struct pollfd pf[3 + MAXPADS] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { 0, POLLIN, 0 }, { ino, POLLIN, 0 } };
		int np = npads;
		for (int i = 0; i < np; i++) { pf[3 + i].fd = pads[i].fd; pf[3 + i].events = POLLIN; pf[3 + i].revents = 0; }
		if (poll(pf, (nfds_t)(3 + np), -1) < 0 && errno != EINTR) return 1;
		if (ino >= 0 && (pf[2].revents & POLLIN)) ino_read();
		for (int i = np - 1; i >= 0; i--) if (i < npads && pads[i].fd == pf[3 + i].fd && (pf[3 + i].revents & (POLLIN | POLLHUP | POLLERR))) pad_read(i);
		if (pf[0].revents & POLLIN) wl_display_read_events(dpy); else wl_display_cancel_read(dpy);
		wl_display_dispatch_pending(dpy);
		if (pf[1].revents & (POLLIN | POLLHUP)) {
			ssize_t n = read(0, inbuf + have, sizeof inbuf - have - 1);
			if (n <= 0) return 0;
			have += (size_t)n;
			char *nl;
			while ((nl = memchr(inbuf, '\n', have))) {
				*nl = 0;
				command(inbuf);
				size_t used = (size_t)(nl - inbuf) + 1;
				memmove(inbuf, inbuf + used, have - used);
				have -= used;
			}
			if (have >= sizeof inbuf - 1) have = 0;
		}
	}
}
