/*
 * rbnalpha.c - real per-pixel alpha for Tk toplevels on X11 and XWayland,
 * and the per-pixel loops of the shell's raster.tcl, in C. Ribbon's shell,
 * login screen, installer and apps load it with [package require rbnalpha]
 * (rbnalpha.tcl is the Tcl side; docs/TK-CORNERS.md explains the design).
 *
 * Tk can't put alpha into the pixels it draws, but it can make a toplevel
 * on a 32-bit ARGB visual and leave its background alone (-background "").
 * Such a toplevel gets an X background pixmap holding premultiplied ARGB
 * (the soft shadow, the anti-aliased rounded box, its ring): the X server
 * paints it on every expose and the compositor blends it over whatever is
 * behind (a video, other windows). Tk's widgets live in an ordinary 24-bit
 * child cut to the inside of the box (X Shape), so Tk never draws a pixel
 * that needs alpha.
 *
 * Templates (one small picture per look) are uploaded once and shared;
 * frames for any size are nine-sliced from them in the X server (XRender),
 * and identical frames are one pixmap however many windows show them.
 *
 *   rbnalpha::rrect PHOTO W H ?-fill #hex? ?-radius R|{tl tr br bl}?
 *        ?-ring {#hex W ?sides?}? ?-shadow {dy blur alpha ?#hex?}?
 *        ?-offset {ox oy}?            raster::rrect's picture; returns {pad pt}
 *   rbnalpha::blur SRC DST RADIUS ?-dim PERCENT?
 *        Gaussian blur (CSS blur(RADIUS)) of photo SRC into DST, darkened
 *   rbnalpha::template KEY PHOTO      upload once (premultiplied), shared
 *   rbnalpha::frame WIN W H PIECES    WIN's background: pieces
 *        {KEY sx sy sw sh dx dy dw dh} composited (tiled when dw > sw or
 *        dh > sh); the same W H PIECES give the same pixmap
 *   rbnalpha::release WIN             WIN shows no frame any more (hidden)
 *   rbnalpha::backdrop WIN PHOTO      WIN's background straight from a photo
 *   rbnalpha::shape WIN BOXES         bounding shape: the pixels fully inside
 *        the union of BOXES {x y w h R|{tl tr br bl}}; {} = no shape
 *   rbnalpha::input WIN BOXES         input shape of WIN's toplevel (clicks
 *        outside fall through); {} = all
 *   rbnalpha::plain WIN               give a widget not yet shown the screen's
 *        default visual and colormap (a canvas inside an ARGB toplevel)
 *   rbnalpha::composited WIN          1 when a 32-bit visual and a compositor
 *   rbnalpha::stats                   templates, frames and their bytes
 *
 * Build: see the Makefile (Tk stubs; libX11, libXext, libXrender).
 */
#include <tcl.h>
#include <tk.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <X11/extensions/Xrender.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef TCL_SIZE_MAX
typedef int Tcl_Size;
#endif

typedef struct { Pixmap pm; Picture pic; int w, h; } Tpl;
typedef struct { Pixmap pm; int w, h; unsigned long used; int refs; } Frame;
typedef struct { Pixmap pm; Picture pic; } Tile;

static Tcl_HashTable tpls, frames, tiles, shownBy; /* shownBy: window path -> Frame */
static int ready = 0;
static Display *dpy = NULL;
static Window root = None;
static XRenderPictFormat *argb = NULL;
static unsigned long clock_ = 0;
static size_t tplBytes = 0, frameBytes = 0;
static unsigned long nUploads = 0, nComposed = 0, nReused = 0, nBackdrops = 0;
/* frames no window shows are kept up to this much, for the next popup */
#define FRAME_CACHE (2u << 20)

static int
Setup(Tcl_Interp *interp)
{
	if (ready) return TCL_OK;
	Tk_Window main = Tk_MainWindow(interp);
	if (main == NULL) return TCL_ERROR;
	dpy = Tk_Display(main);
	root = RootWindow(dpy, Tk_ScreenNumber(main));
	argb = XRenderFindStandardFormat(dpy, PictStandardARGB32);
	Tcl_InitHashTable(&tpls, TCL_STRING_KEYS);
	Tcl_InitHashTable(&frames, TCL_STRING_KEYS);
	Tcl_InitHashTable(&tiles, TCL_STRING_KEYS);
	Tcl_InitHashTable(&shownBy, TCL_STRING_KEYS);
	ready = 1;
	return TCL_OK;
}

static Tk_Window
Win(Tcl_Interp *interp, Tcl_Obj *path)
{
	Tk_Window tkwin = Tk_NameToWindow(interp, Tcl_GetString(path), Tk_MainWindow(interp));
	if (tkwin != NULL) Tk_MakeWindowExist(tkwin);
	return tkwin;
}

/* The X parent of a toplevel: Tk's wrapper, the window the compositor sees. */
static Window
Wrapper(Tk_Window tkwin)
{
	Window r, parent, *kids = NULL;
	unsigned n;
	tkwin = Tk_IsTopLevel(tkwin) ? tkwin : NULL;
	if (tkwin == NULL) return None;
	if (!XQueryTree(Tk_Display(tkwin), Tk_WindowId(tkwin), &r, &parent, &kids, &n)) return Tk_WindowId(tkwin);
	if (kids) XFree(kids);
	return parent == r ? Tk_WindowId(tkwin) : parent;
}

/* ---- raster.tcl's rounded box, ring and shadow ------------------------------ */

static int
Hex(Tcl_Interp *interp, const char *s, double rgb[3])
{
	unsigned r, g, b;
	if (s[0] != '#' || strlen(s) != 7 || sscanf(s + 1, "%2x%2x%2x", &r, &g, &b) != 3) {
		Tcl_SetObjResult(interp, Tcl_ObjPrintf("bad colour \"%s\": want #rrggbb", s));
		return TCL_ERROR;
	}
	rgb[0] = r; rgb[1] = g; rgb[2] = b;
	return TCL_OK;
}

/* erf, Abramowitz & Stegun 7.1.26, exactly as raster::erf */
static double
Erf(double x)
{
	double s = x < 0 ? -1.0 : 1.0;
	x = fabs(x);
	double t = 1.0 / (1.0 + 0.3275911 * x);
	double y = 1.0 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t
		- 0.284496736) * t + 0.254829592) * t * exp(-x * x);
	return s * y;
}

/* raster::rbox: coverage of a rounded box at pixel centre px py. n radii:
 * 1, or 4 (top-left top-right bottom-right bottom-left). */
static double
Rbox(double px, double py, double x0, double y0, double x1, double y1, const double *r, int n)
{
	double cx = (x0 + x1) / 2.0, cy = (y0 + y1) / 2.0;
	double rr = r[0];
	if (n == 4) rr = r[py < cy ? (px < cx ? 0 : 1) : (px < cx ? 3 : 2)];
	double qx = fabs(px - cx) - ((x1 - x0) / 2.0 - rr);
	double qy = fabs(py - cy) - ((y1 - y0) / 2.0 - rr);
	double ox = qx > 0 ? qx : 0.0, oy = qy > 0 ? qy : 0.0;
	double m = qx > qy ? qx : qy;
	double d = hypot(ox, oy) + (m < 0 ? m : 0.0) - rr;
	double c = 0.5 - d;
	return c < 0 ? 0.0 : (c > 1 ? 1.0 : c);
}

static int
Doubles(Tcl_Interp *interp, Tcl_Obj *o, double *v, int max, int *n)
{
	Tcl_Size c; Tcl_Obj **e;
	if (Tcl_ListObjGetElements(interp, o, &c, &e) != TCL_OK) return TCL_ERROR;
	if (c > max) c = max;
	for (int i = 0; i < c; i++) if (Tcl_GetDoubleFromObj(interp, e[i], &v[i]) != TCL_OK) return TCL_ERROR;
	*n = (int) c;
	return TCL_OK;
}

static int
Rrect(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	double w, h;
	if (objc < 4 || (objc - 4) % 2) {
		Tcl_WrongNumArgs(interp, 1, objv, "photo w h ?-fill #hex? ?-radius r? ?-ring spec? ?-shadow spec? ?-offset {x y}?");
		return TCL_ERROR;
	}
	Tk_PhotoHandle ph = Tk_FindPhoto(interp, Tcl_GetString(objv[1]));
	if (ph == NULL) { Tcl_SetObjResult(interp, Tcl_ObjPrintf("no photo %s", Tcl_GetString(objv[1]))); return TCL_ERROR; }
	if (Tcl_GetDoubleFromObj(interp, objv[2], &w) || Tcl_GetDoubleFromObj(interp, objv[3], &h)) return TCL_ERROR;
	double fill[3] = {0, 0, 0}, ring[3] = {0, 0, 0}, sc[3] = {0, 0, 0};
	double r[4] = {0, 0, 0, 0}, rw = 0, dy = 0, blur = 0, sa = 0, ox = 0, oy = 0;
	int nr = 1, shadow = 0;
	const char *sides = "tlrb";
	for (int i = 4; i < objc; i += 2) {
		const char *k = Tcl_GetString(objv[i]);
		Tcl_Obj *v = objv[i + 1];
		Tcl_Size c; Tcl_Obj **e;
		if (!strcmp(k, "-fill")) {
			if (Hex(interp, Tcl_GetString(v), fill)) return TCL_ERROR;
		} else if (!strcmp(k, "-radius")) {
			if (Doubles(interp, v, r, 4, &nr)) return TCL_ERROR;
			if (nr != 4) nr = 1;
		} else if (!strcmp(k, "-ring")) {
			if (Tcl_ListObjGetElements(interp, v, &c, &e)) return TCL_ERROR;
			if (c >= 2) {
				if (Hex(interp, Tcl_GetString(e[0]), ring) || Tcl_GetDoubleFromObj(interp, e[1], &rw)) return TCL_ERROR;
				if (c >= 3 && Tcl_GetString(e[2])[0]) sides = Tcl_GetString(e[2]);
			}
		} else if (!strcmp(k, "-shadow")) {
			if (Tcl_ListObjGetElements(interp, v, &c, &e)) return TCL_ERROR;
			if (c >= 3) {
				shadow = 1;
				if (Tcl_GetDoubleFromObj(interp, e[0], &dy) || Tcl_GetDoubleFromObj(interp, e[1], &blur)
						|| Tcl_GetDoubleFromObj(interp, e[2], &sa)) return TCL_ERROR;
				if (c >= 4 && Hex(interp, Tcl_GetString(e[3]), sc)) return TCL_ERROR;
			}
		} else if (!strcmp(k, "-offset")) {
			double o[2] = {0, 0}; int n;
			if (Doubles(interp, v, o, 2, &n)) return TCL_ERROR;
			ox = o[0]; oy = o[1];
		} else {
			Tcl_SetObjResult(interp, Tcl_ObjPrintf("unknown option %s", k));
			return TCL_ERROR;
		}
	}
	int pad = 0, pt = 0, pb = 0;
	if (shadow) {
		pad = (int) ceil(blur * 1.5);
		pt = pad - (int) dy; if (pt < 0) pt = 0;
		pb = pad + (int) dy;
	}
	int iw = (int) ceil(w + ox) + 2 * pad, ih = (int) ceil(h + oy) + pt + pb;
	double x0 = pad + ox, y0 = pt + oy, x1 = x0 + w, y1 = y0 + h;
	double ri[4];
	int ring4 = rw > 0;
	for (int i = 0; i < 4; i++) { double v = (nr == 4 ? r[i] : r[0]) - rw; ri[i] = v > 0 ? v : 0.0; }
	double ix0 = strchr(sides, 'l') ? x0 + rw : x0 - rw - 50, iy0 = strchr(sides, 't') ? y0 + rw : y0 - rw - 50;
	double ix1 = strchr(sides, 'r') ? x1 - rw : x1 + rw + 50, iy1 = strchr(sides, 'b') ? y1 - rw : y1 + rw + 50;
	double *fx = NULL, *fy = NULL;
	if (shadow) {
		double k = 1.0 / (blur / 2.0 * sqrt(2.0));
		fx = malloc(sizeof(double) * (iw + 1)); fy = malloc(sizeof(double) * (ih + 1));
		for (int x = 0; x < iw; x++) { double p = x + 0.5; fx[x] = 0.5 * (Erf((p - x0) * k) - Erf((p - x1) * k)); }
		for (int y = 0; y < ih; y++) { double p = y + 0.5 - dy; fy[y] = 0.5 * (Erf((p - y0) * k) - Erf((p - y1) * k)); }
	}
	unsigned char *px = malloc((size_t) iw * ih * 4 + 4);
	for (int y = 0; y < ih; y++) {
		double py = y + 0.5;
		for (int x = 0; x < iw; x++) {
			double pxc = x + 0.5;
			unsigned char *o = px + ((size_t) y * iw + x) * 4;
			double co = Rbox(pxc, py, x0, y0, x1, y1, r, nr);
			double s = shadow ? sa * fy[y] * fx[x] : 0.0;
			double cr, cg, cb;
			if (ring4 && co > 0) {
				double ci = Rbox(pxc, py, ix0, iy0, ix1, iy1, ri, 4);
				double f = (co - ci) / co;
				cr = ring[0] * f + fill[0] * (1 - f); cg = ring[1] * f + fill[1] * (1 - f); cb = ring[2] * f + fill[2] * (1 - f);
			} else {
				cr = fill[0]; cg = fill[1]; cb = fill[2];
			}
			double a = co + s * (1.0 - co);
			if (a <= 0.0) { o[0] = o[1] = o[2] = o[3] = 0; continue; }
			double k2 = co / a, k3 = 1.0 - k2;
			o[0] = (unsigned char) (int) (cr * k2 + sc[0] * k3 + 0.5);
			o[1] = (unsigned char) (int) (cg * k2 + sc[1] * k3 + 0.5);
			o[2] = (unsigned char) (int) (cb * k2 + sc[2] * k3 + 0.5);
			o[3] = (unsigned char) (int) (a * 255 + 0.5);
		}
	}
	free(fx); free(fy);
	Tk_PhotoImageBlock b = { px, iw, ih, iw * 4, 4, {0, 1, 2, 3} };
	Tk_PhotoBlank(ph);
	if (Tk_PhotoSetSize(interp, ph, iw, ih) != TCL_OK
			|| Tk_PhotoPutBlock(interp, ph, &b, 0, 0, iw, ih, TK_PHOTO_COMPOSITE_SET) != TCL_OK) {
		free(px); return TCL_ERROR;
	}
	free(px);
	Tcl_Obj *res[2] = { Tcl_NewIntObj(pad), Tcl_NewIntObj(pt) };
	Tcl_SetObjResult(interp, Tcl_NewListObj(2, res));
	return TCL_OK;
}

/* ---- blur ------------------------------------------------------------------------ */

/* One box pass of radius r along rows (4 channels, edges extended). */
static void
BoxH(const uint8_t *s, uint8_t *d, int w, int h, int r)
{
	int n = 2 * r + 1;
	for (int y = 0; y < h; y++) {
		const uint8_t *row = s + (size_t) y * w * 4;
		uint8_t *out = d + (size_t) y * w * 4;
		unsigned s0 = 0, s1 = 0, s2 = 0, s3 = 0;
		for (int i = -r; i <= r; i++) {
			const uint8_t *p = row + (i < 0 ? 0 : (i >= w ? w - 1 : i)) * 4;
			s0 += p[0]; s1 += p[1]; s2 += p[2]; s3 += p[3];
		}
		for (int x = 0; x < w; x++) {
			uint8_t *o = out + x * 4;
			o[0] = (uint8_t) ((s0 + r) / n); o[1] = (uint8_t) ((s1 + r) / n);
			o[2] = (uint8_t) ((s2 + r) / n); o[3] = (uint8_t) ((s3 + r) / n);
			int a = x + r + 1, b = x - r;
			const uint8_t *pa = row + (a >= w ? w - 1 : a) * 4, *pb = row + (b < 0 ? 0 : b) * 4;
			s0 += pa[0] - pb[0]; s1 += pa[1] - pb[1]; s2 += pa[2] - pb[2]; s3 += pa[3] - pb[3];
		}
	}
}

/* The same down the columns, a row at a time (cache friendly). */
static void
BoxV(const uint8_t *s, uint8_t *d, int w, int h, int r, unsigned *sum)
{
	int n = 2 * r + 1, W4 = w * 4;
	memset(sum, 0, sizeof(unsigned) * W4);
	for (int i = -r; i <= r; i++) {
		const uint8_t *row = s + (size_t) (i < 0 ? 0 : (i >= h ? h - 1 : i)) * W4;
		for (int k = 0; k < W4; k++) sum[k] += row[k];
	}
	for (int y = 0; y < h; y++) {
		uint8_t *out = d + (size_t) y * W4;
		for (int k = 0; k < W4; k++) out[k] = (uint8_t) ((sum[k] + r) / n);
		int a = y + r + 1, b = y - r;
		const uint8_t *add = s + (size_t) (a >= h ? h - 1 : a) * W4;
		const uint8_t *sub = s + (size_t) (b < 0 ? 0 : b) * W4;
		for (int k = 0; k < W4; k++) sum[k] += add[k] - sub[k];
	}
}

/* rbnalpha::blur SRC DST RADIUS ?-dim PERCENT?: a Gaussian blur of standard
 * deviation RADIUS px (CSS blur(RADIUS)), as three box passes; past 3 px it
 * works on a copy shrunk by RADIUS / 3, at most 8 (area average) and enlarges it again
 * bilinearly, which can't be told apart at that blur. -dim darkens. */
static int
Blur(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	double sigma, dim = 0;
	if (objc != 4 && objc != 6) { Tcl_WrongNumArgs(interp, 1, objv, "src dst radius ?-dim percent?"); return TCL_ERROR; }
	Tk_PhotoHandle sp = Tk_FindPhoto(interp, Tcl_GetString(objv[1]));
	Tk_PhotoHandle dp = Tk_FindPhoto(interp, Tcl_GetString(objv[2]));
	if (sp == NULL || dp == NULL) { Tcl_SetObjResult(interp, Tcl_ObjPrintf("no photo %s", Tcl_GetString(objv[sp == NULL ? 1 : 2]))); return TCL_ERROR; }
	if (Tcl_GetDoubleFromObj(interp, objv[3], &sigma)) return TCL_ERROR;
	if (objc == 6) {
		if (strcmp(Tcl_GetString(objv[4]), "-dim")) { Tcl_SetObjResult(interp, Tcl_ObjPrintf("unknown option %s", Tcl_GetString(objv[4]))); return TCL_ERROR; }
		if (Tcl_GetDoubleFromObj(interp, objv[5], &dim)) return TCL_ERROR;
	}
	Tk_PhotoImageBlock b;
	Tk_PhotoGetImage(sp, &b);
	int W = b.width, H = b.height;
	if (W <= 0 || H <= 0) return TCL_OK;
	int k = sigma >= 3 ? (int) ceil(sigma / 3) : 1;
	if (k > 8) k = 8;
	int w = (W + k - 1) / k, h = (H + k - 1) / k;
	uint8_t *a = malloc((size_t) w * h * 4), *t = malloc((size_t) w * h * 4);
	unsigned *sum = malloc(sizeof(unsigned) * w * 4);
	int opaque = 1;
	/* shrink (area average) into a, as RGBA */
	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			unsigned acc[4] = {0, 0, 0, 0}, cnt = 0;
			for (int yy = y * k; yy < y * k + k && yy < H; yy++) {
				const unsigned char *p = b.pixelPtr + (size_t) yy * b.pitch + (size_t) x * k * b.pixelSize;
				for (int xx = x * k; xx < x * k + k && xx < W; xx++, p += b.pixelSize) {
					acc[0] += p[b.offset[0]]; acc[1] += p[b.offset[1]]; acc[2] += p[b.offset[2]];
					acc[3] += b.offset[3] < b.pixelSize ? p[b.offset[3]] : 255;
					cnt++;
				}
			}
			uint8_t *o = a + ((size_t) y * w + x) * 4;
			for (int c = 0; c < 4; c++) o[c] = (uint8_t) ((acc[c] + cnt / 2) / cnt);
			if (o[3] != 255) opaque = 0;
		}
	}
	double s = sigma / k;
	int r = (int) lround((sqrt(12.0 * s * s / 3 + 1) - 1) / 2);
	if (r >= 1) {
		for (int pass = 0; pass < 3; pass++) { BoxH(a, t, w, h, r); BoxV(t, a, w, h, r, sum); }
	}
	double f = 1.0 - dim / 100.0;
	if (f < 0) f = 0;
	uint8_t *out = malloc((size_t) W * H * 4);
	if (k == 1) {
		for (size_t i = 0; i < (size_t) W * H; i++) {
			for (int c = 0; c < 3; c++) out[i * 4 + c] = (uint8_t) (a[i * 4 + c] * f + 0.5);
			out[i * 4 + 3] = a[i * 4 + 3];
		}
	} else {
		/* enlarge, bilinear, centre-aligned, in 8-bit fixed point: a
		 * row is interpolated vertically once, then each pixel across */
		int fi = (int) (f * 256 + 0.5);
		int *xi = malloc(sizeof(int) * W * 3);
		for (int x = 0; x < W; x++) {
			double fx = (x + 0.5) / k - 0.5;
			if (fx < 0) fx = 0;
			if (fx > w - 1) fx = w - 1;
			int x0 = (int) fx;
			xi[3 * x] = x0 * 4; xi[3 * x + 1] = (x0 + 1 < w ? x0 + 1 : w - 1) * 4;
			xi[3 * x + 2] = (int) ((fx - x0) * 256 + 0.5);
		}
		int *row = malloc(sizeof(int) * w * 4);
		int lasty0 = -1, lastv = -1;
		for (int y = 0; y < H; y++) {
			double fy = (y + 0.5) / k - 0.5;
			if (fy < 0) fy = 0;
			if (fy > h - 1) fy = h - 1;
			int y0 = (int) fy, y1 = y0 + 1 < h ? y0 + 1 : h - 1;
			int v = (int) ((fy - y0) * 256 + 0.5);
			if (y0 != lasty0 || v != lastv) {
				const uint8_t *r0 = a + (size_t) y0 * w * 4, *r1 = a + (size_t) y1 * w * 4;
				for (int i = 0; i < w * 4; i++) row[i] = r0[i] * (256 - v) + r1[i] * v;
				lasty0 = y0; lastv = v;
			}
			uint8_t *o = out + (size_t) y * W * 4;
			for (int x = 0; x < W; x++, o += 4) {
				const int *p0 = row + xi[3 * x], *p1 = row + xi[3 * x + 1];
				int u = xi[3 * x + 2], iu = 256 - u;
				o[0] = (uint8_t) ((((p0[0] * iu + p1[0] * u + 32768) >> 16) * fi + 128) >> 8);
				o[1] = (uint8_t) ((((p0[1] * iu + p1[1] * u + 32768) >> 16) * fi + 128) >> 8);
				o[2] = (uint8_t) ((((p0[2] * iu + p1[2] * u + 32768) >> 16) * fi + 128) >> 8);
				o[3] = (uint8_t) ((p0[3] * iu + p1[3] * u + 32768) >> 16);
			}
		}
		free(xi); free(row);
	}
	free(a); free(t); free(sum);
	/* an opaque picture goes in without an alpha channel: Tk copies it faster */
	Tk_PhotoImageBlock ob = { out, W, H, W * 4, 4, {0, 1, 2, opaque ? 4 : 3} };
	int rc = Tk_PhotoSetSize(interp, dp, W, H) == TCL_OK
		&& Tk_PhotoPutBlock(interp, dp, &ob, 0, 0, W, H, TK_PHOTO_COMPOSITE_SET) == TCL_OK;
	free(out);
	return rc ? TCL_OK : TCL_ERROR;
}

/* ---- pictures into the X server ------------------------------------------------ */

/* A photo as a premultiplied ARGB pixmap. */
static Pixmap
Upload(Tk_PhotoHandle ph, int *w, int *h)
{
	Tk_PhotoImageBlock b;
	Tk_PhotoGetImage(ph, &b);
	*w = b.width; *h = b.height;
	if (b.width <= 0 || b.height <= 0) return None;
	uint32_t *data = malloc((size_t) b.width * b.height * 4);
	for (int y = 0; y < b.height; y++) {
		unsigned char *p = b.pixelPtr + (size_t) y * b.pitch;
		uint32_t *o = data + (size_t) y * b.width;
		for (int x = 0; x < b.width; x++, p += b.pixelSize) {
			unsigned a = p[b.offset[3]];
			unsigned r = (p[b.offset[0]] * a + 127) / 255;
			unsigned g = (p[b.offset[1]] * a + 127) / 255;
			unsigned bl = (p[b.offset[2]] * a + 127) / 255;
			o[x] = a << 24 | r << 16 | g << 8 | bl;
		}
	}
	XImage *im = XCreateImage(dpy, NULL, 32, ZPixmap, 0, (char *) data, b.width, b.height, 32, b.width * 4);
	im->byte_order = LSBFirst;
	{ uint32_t one = 1; if (*(unsigned char *) &one == 0) im->byte_order = MSBFirst; }
	Pixmap pm = XCreatePixmap(dpy, root, b.width, b.height, 32);
	GC gc = XCreateGC(dpy, pm, 0, NULL);
	XPutImage(dpy, pm, gc, im, 0, 0, 0, 0, b.width, b.height);
	XFreeGC(dpy, gc);
	XDestroyImage(im);
	nUploads++;
	return pm;
}

static void
SetBackground(Tk_Window tkwin, Pixmap pm)
{
	Tk_SetWindowBackgroundPixmap(tkwin, pm);
	Window w = Wrapper(tkwin);
	if (w != None && w != Tk_WindowId(tkwin)) XSetWindowBackgroundPixmap(dpy, w, None);
	XClearWindow(dpy, Tk_WindowId(tkwin));
}

static int
Check32(Tcl_Interp *interp, Tk_Window tkwin, Tcl_Obj *path)
{
	if (Tk_Depth(tkwin) == 32) return TCL_OK;
	Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s is not on a 32-bit visual", Tcl_GetString(path)));
	return TCL_ERROR;
}

static int
Template(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc != 3) { Tcl_WrongNumArgs(interp, 1, objv, "key photo"); return TCL_ERROR; }
	if (Setup(interp)) return TCL_ERROR;
	int isNew;
	Tcl_HashEntry *e = Tcl_CreateHashEntry(&tpls, Tcl_GetString(objv[1]), &isNew);
	if (!isNew) return TCL_OK;
	Tk_PhotoHandle ph = Tk_FindPhoto(interp, Tcl_GetString(objv[2]));
	if (ph == NULL || argb == NULL) {
		Tcl_DeleteHashEntry(e);
		Tcl_SetObjResult(interp, Tcl_ObjPrintf(ph == NULL ? "no photo %s" : "no ARGB32 format for %s", Tcl_GetString(objv[2])));
		return TCL_ERROR;
	}
	Tpl *t = ckalloc(sizeof *t);
	t->pm = Upload(ph, &t->w, &t->h);
	t->pic = XRenderCreatePicture(dpy, t->pm, argb, 0, NULL);
	tplBytes += (size_t) t->w * t->h * 4;
	Tcl_SetHashValue(e, t);
	return TCL_OK;
}

/* A repeating picture of a template's region (the nine-slice's edges and
 * middle). */
static Picture
TileOf(Tpl *t, const char *key, int sx, int sy, int sw, int sh)
{
	char name[512];
	snprintf(name, sizeof name, "%s %d %d %d %d", key, sx, sy, sw, sh);
	int isNew;
	Tcl_HashEntry *e = Tcl_CreateHashEntry(&tiles, name, &isNew);
	if (!isNew) return ((Tile *) Tcl_GetHashValue(e))->pic;
	Tile *tl = ckalloc(sizeof *tl);
	tl->pm = XCreatePixmap(dpy, root, sw, sh, 32);
	XRenderPictureAttributes pa;
	pa.repeat = RepeatNormal;
	tl->pic = XRenderCreatePicture(dpy, tl->pm, argb, CPRepeat, &pa);
	XRenderComposite(dpy, PictOpSrc, t->pic, None, tl->pic, sx, sy, 0, 0, 0, 0, sw, sh);
	tplBytes += (size_t) sw * sh * 4;
	Tcl_SetHashValue(e, tl);
	return tl->pic;
}

static size_t
Unused(void)
{
	size_t n = 0;
	Tcl_HashSearch s;
	for (Tcl_HashEntry *e = Tcl_FirstHashEntry(&frames, &s); e; e = Tcl_NextHashEntry(&s)) {
		Frame *f = Tcl_GetHashValue(e);
		if (f->refs <= 0) n += (size_t) f->w * f->h * 4;
	}
	return n;
}

/* Free the frames no window shows, oldest first, past FRAME_CACHE. */
static void
Evict(void)
{
	while (Unused() > FRAME_CACHE) {
		Tcl_HashSearch s;
		Tcl_HashEntry *old = NULL;
		unsigned long best = ~0UL;
		for (Tcl_HashEntry *e = Tcl_FirstHashEntry(&frames, &s); e; e = Tcl_NextHashEntry(&s)) {
			Frame *f = Tcl_GetHashValue(e);
			if (f->refs <= 0 && f->used < best) { best = f->used; old = e; }
		}
		if (old == NULL) break;
		Frame *f = Tcl_GetHashValue(old);
		XFreePixmap(dpy, f->pm);
		frameBytes -= (size_t) f->w * f->h * 4;
		ckfree(f);
		Tcl_DeleteHashEntry(old);
	}
}

/* Window PATH shows frame F now (NULL: none). */
static void
Shows(const char *path, Frame *f)
{
	int isNew;
	Tcl_HashEntry *e = Tcl_CreateHashEntry(&shownBy, path, &isNew);
	Frame *old = isNew ? NULL : Tcl_GetHashValue(e);
	if (old == f) return;
	if (old != NULL) old->refs--;
	if (f != NULL) { f->refs++; Tcl_SetHashValue(e, f); } else Tcl_DeleteHashEntry(e);
}

/* rbnalpha::release WIN: WIN shows nothing (hidden, or going away); its
 * frame's memory goes once no window shows it. */
static int
Release(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc != 2) { Tcl_WrongNumArgs(interp, 1, objv, "window"); return TCL_ERROR; }
	if (Setup(interp)) return TCL_ERROR;
	Tk_Window tkwin = Tk_NameToWindow(interp, Tcl_GetString(objv[1]), Tk_MainWindow(interp));
	if (tkwin != NULL && Tk_WindowId(tkwin) != None) {
		Tk_SetWindowBackgroundPixmap(tkwin, None);
	}
	Tcl_ResetResult(interp);
	Shows(Tcl_GetString(objv[1]), NULL);
	Evict();
	return TCL_OK;
}

static int
FrameCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc != 5) { Tcl_WrongNumArgs(interp, 1, objv, "window w h pieces"); return TCL_ERROR; }
	if (Setup(interp)) return TCL_ERROR;
	Tk_Window tkwin = Win(interp, objv[1]);
	if (tkwin == NULL || Check32(interp, tkwin, objv[1])) return TCL_ERROR;
	int W, H;
	if (Tcl_GetIntFromObj(interp, objv[2], &W) || Tcl_GetIntFromObj(interp, objv[3], &H)) return TCL_ERROR;
	if (W < 1) W = 1;
	if (H < 1) H = 1;
	Tcl_DString key;
	Tcl_DStringInit(&key);
	Tcl_DStringAppend(&key, Tcl_GetString(objv[2]), -1);
	Tcl_DStringAppend(&key, " ", 1);
	Tcl_DStringAppend(&key, Tcl_GetString(objv[3]), -1);
	Tcl_DStringAppend(&key, " ", 1);
	Tcl_DStringAppend(&key, Tcl_GetString(objv[4]), -1);
	int isNew;
	Tcl_HashEntry *he = Tcl_CreateHashEntry(&frames, Tcl_DStringValue(&key), &isNew);
	Tcl_DStringFree(&key);
	Frame *f;
	if (!isNew) {
		f = Tcl_GetHashValue(he);
		nReused++;
	} else {
		Tcl_Size n; Tcl_Obj **pieces;
		if (Tcl_ListObjGetElements(interp, objv[4], &n, &pieces)) { Tcl_DeleteHashEntry(he); return TCL_ERROR; }
		Pixmap pm = XCreatePixmap(dpy, root, W, H, 32);
		Picture dst = XRenderCreatePicture(dpy, pm, argb, 0, NULL);
		XRenderColor clear = {0, 0, 0, 0};
		XRenderFillRectangle(dpy, PictOpSrc, dst, &clear, 0, 0, W, H);
		for (Tcl_Size i = 0; i < n; i++) {
			Tcl_Size c; Tcl_Obj **e;
			int v[8];
			if (Tcl_ListObjGetElements(interp, pieces[i], &c, &e) || c != 9) {
				Tcl_SetObjResult(interp, Tcl_ObjPrintf("bad piece \"%s\": want {key sx sy sw sh dx dy dw dh}", Tcl_GetString(pieces[i])));
				XRenderFreePicture(dpy, dst); XFreePixmap(dpy, pm); Tcl_DeleteHashEntry(he);
				return TCL_ERROR;
			}
			for (int k = 0; k < 8; k++) {
				if (Tcl_GetIntFromObj(interp, e[k + 1], &v[k])) {
					XRenderFreePicture(dpy, dst); XFreePixmap(dpy, pm); Tcl_DeleteHashEntry(he);
					return TCL_ERROR;
				}
			}
			Tcl_HashEntry *te = Tcl_FindHashEntry(&tpls, Tcl_GetString(e[0]));
			if (te == NULL) {
				Tcl_SetObjResult(interp, Tcl_ObjPrintf("no template \"%s\"", Tcl_GetString(e[0])));
				XRenderFreePicture(dpy, dst); XFreePixmap(dpy, pm); Tcl_DeleteHashEntry(he);
				return TCL_ERROR;
			}
			Tpl *t = Tcl_GetHashValue(te);
			int sx = v[0], sy = v[1], sw = v[2], sh = v[3], dx = v[4], dy = v[5], dw = v[6], dh = v[7];
			if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) continue;
			if (dw == sw && dh == sh) {
				XRenderComposite(dpy, PictOpOver, t->pic, None, dst, sx, sy, 0, 0, dx, dy, dw, dh);
			} else {
				Picture tile = TileOf(t, Tcl_GetString(e[0]), sx, sy, sw, sh);
				XRenderComposite(dpy, PictOpOver, tile, None, dst, 0, 0, 0, 0, dx, dy, dw, dh);
			}
		}
		XRenderFreePicture(dpy, dst);
		f = ckalloc(sizeof *f);
		f->pm = pm; f->w = W; f->h = H; f->refs = 0;
		Tcl_SetHashValue(he, f);
		frameBytes += (size_t) W * H * 4;
		nComposed++;
	}
	f->used = ++clock_;
	SetBackground(tkwin, f->pm);
	Shows(Tcl_GetString(objv[1]), f);
	Evict();
	return TCL_OK;
}

static int
Backdrop(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc != 3) { Tcl_WrongNumArgs(interp, 1, objv, "window photo"); return TCL_ERROR; }
	if (Setup(interp)) return TCL_ERROR;
	Tk_Window tkwin = Win(interp, objv[1]);
	if (tkwin == NULL || Check32(interp, tkwin, objv[1])) return TCL_ERROR;
	Tk_PhotoHandle ph = Tk_FindPhoto(interp, Tcl_GetString(objv[2]));
	if (ph == NULL) { Tcl_SetObjResult(interp, Tcl_ObjPrintf("no photo %s", Tcl_GetString(objv[2]))); return TCL_ERROR; }
	int w, h;
	Pixmap pm = Upload(ph, &w, &h);
	if (pm == None) return TCL_OK;
	SetBackground(tkwin, pm);
	XFreePixmap(dpy, pm); /* the server keeps the window's reference */
	nBackdrops++;
	return TCL_OK;
}

/* ---- shapes ----------------------------------------------------------------------- */

/* Rows of the pixels fully inside a rounded box; radii tl tr br bl. */
static int
Rows(XRectangle *out, double X, double Y, double W, double H, const double *r)
{
	int n = 0;
	for (int y = (int) floor(Y); y < (int) ceil(Y + H); y++) {
		if (y < Y || y + 1 > Y + H) continue;
		double l = 0, rt = 0;
		for (int side = 0; side < 2; side++) {
			/* this side's corner for the row: top or bottom */
			double rr = r[y + 0.5 < Y + H / 2.0 ? (side ? 1 : 0) : (side ? 2 : 3)];
			if (rr > W / 2.0) rr = W / 2.0;
			if (rr > H / 2.0) rr = H / 2.0;
			double dy = 0;
			if (y < Y + rr) dy = (Y + rr) - y;
			else if (y + 1 > Y + H - rr) dy = (y + 1) - (Y + H - rr);
			double in = 0;
			if (dy > 0) { double q = rr * rr - dy * dy; in = q <= 0 ? rr + 1 : rr - sqrt(q); }
			if (side) rt = in; else l = in;
		}
		int xa = (int) ceil(X + l), xb = (int) floor(X + W - rt);
		if (xb <= xa) continue;
		if (n > 0 && out[n - 1].x == xa && out[n - 1].width == xb - xa && out[n - 1].y + out[n - 1].height == y) {
			out[n - 1].height++;
		} else {
			out[n].x = xa; out[n].y = y; out[n].width = xb - xa; out[n].height = 1; n++;
		}
	}
	return n;
}

static int
ShapeOf(Tcl_Interp *interp, Tk_Window tkwin, Window w, int kind, Tcl_Obj *boxes)
{
	Tcl_Size nb; Tcl_Obj **b;
	if (Tcl_ListObjGetElements(interp, boxes, &nb, &b)) return TCL_ERROR;
	if (nb == 0) {
		XShapeCombineMask(Tk_Display(tkwin), w, kind, 0, 0, None, ShapeSet);
		return TCL_OK;
	}
	int cap = 0;
	XRectangle *all = NULL;
	int n = 0;
	for (Tcl_Size i = 0; i < nb; i++) {
		Tcl_Size c; Tcl_Obj **e;
		double v[4], r[4] = {0, 0, 0, 0};
		int nr = 1;
		if (Tcl_ListObjGetElements(interp, b[i], &c, &e) || c < 4) {
			Tcl_SetObjResult(interp, Tcl_ObjPrintf("bad box \"%s\": want {x y w h ?radius?}", Tcl_GetString(b[i])));
			ckfree(all); return TCL_ERROR;
		}
		for (int k = 0; k < 4; k++) if (Tcl_GetDoubleFromObj(interp, e[k], &v[k])) { ckfree(all); return TCL_ERROR; }
		if (c > 4 && Doubles(interp, e[4], r, 4, &nr)) { ckfree(all); return TCL_ERROR; }
		if (nr != 4) r[1] = r[2] = r[3] = r[0];
		int need = n + (int) ceil(v[3]) + 2;
		if (need > cap) { cap = need * 2; all = ckrealloc(all, cap * sizeof *all); }
		n += Rows(all + n, v[0], v[1], v[2], v[3], r);
	}
	XShapeCombineRectangles(Tk_Display(tkwin), w, kind, 0, 0, all, n, ShapeSet, Unsorted);
	ckfree(all);
	Tcl_SetObjResult(interp, Tcl_NewIntObj(n));
	return TCL_OK;
}

static int
Shape(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc != 3) { Tcl_WrongNumArgs(interp, 1, objv, "window boxes"); return TCL_ERROR; }
	Tk_Window tkwin = Win(interp, objv[1]);
	if (tkwin == NULL) return TCL_ERROR;
	Window w = Tk_IsTopLevel(tkwin) ? Wrapper(tkwin) : Tk_WindowId(tkwin);
	return ShapeOf(interp, tkwin, w, ShapeBounding, objv[2]);
}

static int
Input(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc != 3) { Tcl_WrongNumArgs(interp, 1, objv, "toplevel boxes"); return TCL_ERROR; }
	Tk_Window tkwin = Win(interp, objv[1]);
	if (tkwin == NULL) return TCL_ERROR;
	if (!Tk_IsTopLevel(tkwin)) { Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s is not a toplevel", Tcl_GetString(objv[1]))); return TCL_ERROR; }
	return ShapeOf(interp, tkwin, Wrapper(tkwin), ShapeInput, objv[2]);
}

static int
Plain(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc != 2) { Tcl_WrongNumArgs(interp, 1, objv, "window"); return TCL_ERROR; }
	Tk_Window tkwin = Tk_NameToWindow(interp, Tcl_GetString(objv[1]), Tk_MainWindow(interp));
	if (tkwin == NULL) return TCL_ERROR;
	Display *d = Tk_Display(tkwin);
	int scr = Tk_ScreenNumber(tkwin);
	if (!Tk_SetWindowVisual(tkwin, DefaultVisual(d, scr), DefaultDepth(d, scr), DefaultColormap(d, scr))) {
		Tcl_SetObjResult(interp, Tcl_ObjPrintf("%s already exists in the X server", Tcl_GetString(objv[1])));
		return TCL_ERROR;
	}
	return TCL_OK;
}

/* ---- facts -------------------------------------------------------------------------- */

static int
Composited(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd;
	if (objc > 2) { Tcl_WrongNumArgs(interp, 1, objv, "?window?"); return TCL_ERROR; }
	if (Setup(interp)) return TCL_ERROR;
	Tk_Window tkwin = objc == 2 ? Win(interp, objv[1]) : Tk_MainWindow(interp);
	if (tkwin == NULL) return TCL_ERROR;
	int scr = Tk_ScreenNumber(tkwin);
	XVisualInfo vi;
	int ok = argb != NULL && XMatchVisualInfo(dpy, scr, 32, TrueColor, &vi);
	if (ok) {
		char name[32];
		snprintf(name, sizeof name, "_NET_WM_CM_S%d", scr);
		ok = XGetSelectionOwner(dpy, XInternAtom(dpy, name, False)) != None;
	}
	Tcl_SetObjResult(interp, Tcl_NewBooleanObj(ok));
	return TCL_OK;
}

static int
Stats(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[])
{
	(void) cd; (void) objc; (void) objv;
	Tcl_SetObjResult(interp, Tcl_ObjPrintf(
		"templates %ld tiles %ld template_bytes %lu frames %ld frame_bytes %lu unused_bytes %lu uploads %lu composed %lu reused %lu backdrops %lu",
		/* numEntries is an int in Tcl 8.6 and a Tcl_Size (64 bits) in Tcl 9 */
		ready ? (long) tpls.numEntries : 0L, ready ? (long) tiles.numEntries : 0L, (unsigned long) tplBytes,
		ready ? (long) frames.numEntries : 0L, (unsigned long) frameBytes, (unsigned long) (ready ? Unused() : 0),
		nUploads, nComposed, nReused, nBackdrops));
	return TCL_OK;
}

int
Rbnalpha_Init(Tcl_Interp *interp)
{
	if (Tcl_InitStubs(interp, "8.6-", 0) == NULL || Tk_InitStubs(interp, "8.6-", 0) == NULL) return TCL_ERROR;
	Tcl_CreateObjCommand(interp, "rbnalpha::rrect", Rrect, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::blur", Blur, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::template", Template, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::frame", FrameCmd, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::release", Release, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::backdrop", Backdrop, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::shape", Shape, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::input", Input, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::plain", Plain, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::composited", Composited, NULL, NULL);
	Tcl_CreateObjCommand(interp, "rbnalpha::stats", Stats, NULL, NULL);
	return Tcl_PkgProvide(interp, "rbnalpha_c", "1.0");
}
