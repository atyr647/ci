/* gl.c - ribbon-wall's GPU renderer: EGL + OpenGL ES 2.
 *
 * Everything is a textured quad: pictures (laid out for the output on the
 * CPU once, with a Lanczos filter, then drawn 1:1), video frames (YUV -> RGB
 * in the shader, scaled by the GPU), the old content fading out over the
 * new (crossfades between any two kinds of content).
 *
 * Video frames reach it three ways:
 *   VA-API: the decoder's surface is exported as DRM PRIME dmabufs and
 *           imported as one EGLImage per plane (R8 + GR88 for NV12, R16 +
 *           GR1616 for P010): zero copies, the CPU never touches a pixel.
 *   copied: NVDEC (CUDA) frames, or VA-API frames when the import fails,
 *           are copied to memory by the decoder thread and uploaded.
 *   software: decoded frames (yuv420p / NV12) uploaded as textures.
 * If the dmabuf import fails once, the decoder switches to copying for good
 * (video_want_copyback), so a driver quirk costs one frame, not the video.
 *
 * Copyright 2026 Ribbon OS contributors, MIT licence. */
#include "rw.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/pixdesc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-egl.h>

#ifndef DRM_FORMAT_MOD_INVALID
#define DRM_FORMAT_MOD_INVALID ((1ULL << 56) - 1)
#endif
#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))

static EGLDisplay edpy = EGL_NO_DISPLAY;
static EGLConfig ecfg;
static EGLContext ectx;
static bool has_dmabuf, has_modifiers, has_unpack_row;
static PFNEGLCREATEIMAGEKHRPROC create_image;
static PFNEGLDESTROYIMAGEKHRPROC destroy_image;
static PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target;

static GLuint p_rgb, p_yuv;
static GLint u_rgb_tex, u_rgb_alpha, u_rgb_hasa, u_rgb_bgra, u_yuv_m, u_yuv_off, u_yuv_mode;
static GLuint vtex[3];               /* the current video frame's planes */
static long vtex_idx = -1;           /* which frame they hold */
static const AVFrame *vtex_f;
static int vmode;                    /* 0 three planes, 1 NV12 (UV in .ra), 2 NV12 (UV in .rg, imported) */
static float vm[9], voff[3];
static EGLImageKHR vimg[2];
static AVFrame *vmapped;             /* the DRM PRIME mapping behind vimg */

struct gl_out {
	struct wl_egl_window *win;
	EGLSurface surf;
	int w, h;
};

/* ---- setup -------------------------------------------------------------------- */

static GLuint shader(GLenum type, const char *src) {
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "ribbon-wall: shader: %s\n", log); }
	return s;
}

static GLuint program(const char *fs) {
	static const char *vs =
		"attribute vec2 pos; attribute vec2 tc; varying vec2 v;\n"
		"void main() { v = tc; gl_Position = vec4(pos, 0.0, 1.0); }\n";
	GLuint p = glCreateProgram();
	glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
	glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(p, 0, "pos");
	glBindAttribLocation(p, 1, "tc");
	glLinkProgram(p);
	GLint ok;
	glGetProgramiv(p, GL_LINK_STATUS, &ok);
	return ok ? p : 0;
}

static bool init(void) {
	PFNEGLGETPLATFORMDISPLAYEXTPROC gpd = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
	edpy = gpd ? gpd(EGL_PLATFORM_WAYLAND_KHR, dpy, NULL) : eglGetDisplay((EGLNativeDisplayType)dpy);
	EGLint maj, min;
	if (edpy == EGL_NO_DISPLAY || !eglInitialize(edpy, &maj, &min)) return false;
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint ca[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0, EGL_NONE };
	EGLint n = 0;
	if (!eglChooseConfig(edpy, ca, &ecfg, 1, &n) || n < 1) { eglTerminate(edpy); return false; }
	EGLint xa[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	ectx = eglCreateContext(edpy, ecfg, EGL_NO_CONTEXT, xa);
	if (ectx == EGL_NO_CONTEXT || !eglMakeCurrent(edpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ectx)) { eglTerminate(edpy); return false; }
	const char *ee = eglQueryString(edpy, EGL_EXTENSIONS), *ge = (const char *)glGetString(GL_EXTENSIONS);
	const char *ver = (const char *)glGetString(GL_VERSION);
	has_unpack_row = strstr(ge, "GL_EXT_unpack_subimage") || (ver && strstr(ver, "OpenGL ES 3"));
	create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
	destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
	image_target = (void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	has_dmabuf = strstr(ee, "EGL_EXT_image_dma_buf_import") && strstr(ge, "GL_OES_EGL_image") && create_image && image_target;
	has_modifiers = strstr(ee, "EGL_EXT_image_dma_buf_import_modifiers") != NULL;
	p_rgb = program(
		"precision mediump float; varying vec2 v; uniform sampler2D t; uniform float alpha, hasa, bgra;\n"
		"void main() { vec4 c = texture2D(t, v); c = mix(c, c.bgra, bgra); c.a = mix(1.0, c.a, hasa); gl_FragColor = c * alpha; }\n");
	p_yuv = program(
		"precision mediump float; varying vec2 v; uniform sampler2D ty, tu, tv; uniform mat3 m; uniform vec3 off; uniform int mode;\n"
		"void main() { float y = texture2D(ty, v).r; vec2 uv;\n"
		"  if (mode == 0) uv = vec2(texture2D(tu, v).r, texture2D(tv, v).r);\n"
		"  else if (mode == 1) uv = texture2D(tu, v).ra; else uv = texture2D(tu, v).rg;\n"
		"  gl_FragColor = vec4(clamp(m * (vec3(y, uv) - off), 0.0, 1.0), 1.0); }\n");
	if (!p_rgb || !p_yuv) return false;
	u_rgb_tex = glGetUniformLocation(p_rgb, "t");
	u_rgb_alpha = glGetUniformLocation(p_rgb, "alpha");
	u_rgb_hasa = glGetUniformLocation(p_rgb, "hasa");
	u_rgb_bgra = glGetUniformLocation(p_rgb, "bgra");
	u_yuv_m = glGetUniformLocation(p_yuv, "m");
	u_yuv_off = glGetUniformLocation(p_yuv, "off");
	u_yuv_mode = glGetUniformLocation(p_yuv, "mode");
	glUseProgram(p_yuv);
	glUniform1i(glGetUniformLocation(p_yuv, "ty"), 0);
	glUniform1i(glGetUniformLocation(p_yuv, "tu"), 1);
	glUniform1i(glGetUniformLocation(p_yuv, "tv"), 2);
	glGenTextures(3, vtex);
	printf("gl %s | %s | dmabuf import %s\n", glGetString(GL_RENDERER), ver, has_dmabuf ? "yes" : "no");
	return true;
}

static void output_init(struct output *o) { o->r = calloc(1, sizeof(struct gl_out)); }

static void output_fini(struct output *o) {
	struct gl_out *g = o->r;
	if (!g) return;
	eglMakeCurrent(edpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ectx);
	if (g->surf) eglDestroySurface(edpy, g->surf);
	if (g->win) wl_egl_window_destroy(g->win);
	if (o->still_tex) glDeleteTextures(1, &o->still_tex);
	if (o->prev_tex) glDeleteTextures(1, &o->prev_tex);
	o->still_tex = o->prev_tex = 0;
	free(g);
	o->r = NULL;
}

static bool make_current(struct output *o) {
	struct gl_out *g = o->r;
	if (!g || !o->surf || o->pw <= 0) return false;
	if (!g->win) {
		g->win = wl_egl_window_create(o->surf, o->pw, o->ph);
		PFNEGLCREATEPLATFORMWINDOWSURFACEEXTPROC cps = (void *)eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT");
		g->surf = cps ? cps(edpy, ecfg, g->win, NULL) : eglCreateWindowSurface(edpy, ecfg, (EGLNativeWindowType)g->win, NULL);
		g->w = o->pw; g->h = o->ph;
	} else if (g->w != o->pw || g->h != o->ph) {
		wl_egl_window_resize(g->win, o->pw, o->ph, 0, 0);
		g->w = o->pw; g->h = o->ph;
	}
	if (g->surf == EGL_NO_SURFACE || !eglMakeCurrent(edpy, g->surf, g->surf, ectx)) return false;
	eglSwapInterval(edpy, 0); /* frame callbacks pace us; never block in swap */
	return true;
}

/* ---- drawing ----------------------------------------------------------------------- */

static void tex_params(void) {
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

/* A quad covering pixels (x, y, w, h) of a PW x PH target (y down), with
 * texture coordinates (s0, t0) - (s1, t1) at its top-left / bottom-right. */
static void quad(int PW, int PH, double x, double y, double w, double h, float s0, float t0, float s1, float t1) {
	float x0 = (float)(2 * x / PW - 1), x1 = (float)(2 * (x + w) / PW - 1);
	float y0 = (float)(1 - 2 * y / PH), y1 = (float)(1 - 2 * (y + h) / PH);
	float pos[] = { x0, y0, x1, y0, x0, y1, x1, y1 };
	float tc[] = { s0, t0, s1, t0, s0, t1, s1, t1 };
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, pos);
	glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, tc);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

static void upload_rgba(GLuint *tex, const struct img *im) {
	if (!*tex) glGenTextures(1, tex);
	glBindTexture(GL_TEXTURE_2D, *tex);
	tex_params();
	glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, im->w, im->h, 0, GL_RGBA, GL_UNSIGNED_BYTE, im->px);
}

static void rgb_quad(GLuint tex, int PW, int PH, double x, double y, double w, double h, float alpha, bool hasa, bool flip) {
	glUseProgram(p_rgb);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, tex);
	glUniform1i(u_rgb_tex, 0);
	glUniform1f(u_rgb_alpha, alpha);
	glUniform1f(u_rgb_hasa, hasa ? 1 : 0);
	glUniform1f(u_rgb_bgra, flip ? 0 : 1); /* our pictures are BGRA bytes; frames copied from the screen are RGB */
	quad(PW, PH, x, y, w, h, 0, flip ? 1 : 0, 1, flip ? 0 : 1);
}

static void plane(int unit, GLenum fmt, int w, int h, const uint8_t *data, int stride, int bpp) {
	glActiveTexture(GL_TEXTURE0 + unit);
	glBindTexture(GL_TEXTURE_2D, vtex[unit]);
	tex_params();
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	if (stride == w * bpp) {
		glTexImage2D(GL_TEXTURE_2D, 0, fmt, w, h, 0, fmt, GL_UNSIGNED_BYTE, data);
	} else if (has_unpack_row) {
		glPixelStorei(0x0CF2 /* GL_UNPACK_ROW_LENGTH */, stride / bpp);
		glTexImage2D(GL_TEXTURE_2D, 0, fmt, w, h, 0, fmt, GL_UNSIGNED_BYTE, data);
		glPixelStorei(0x0CF2, 0);
	} else { /* no row length: tighten it */
		uint8_t *t = malloc((size_t)w * h * bpp);
		for (int y = 0; y < h; y++) memcpy(t + (size_t)y * w * bpp, data + (size_t)y * stride, (size_t)w * bpp);
		glTexImage2D(GL_TEXTURE_2D, 0, fmt, w, h, 0, fmt, GL_UNSIGNED_BYTE, t);
		free(t);
	}
}

static void unmap_video(void) {
	for (int i = 0; i < 2; i++) if (vimg[i]) { destroy_image(edpy, vimg[i]); vimg[i] = NULL; }
	av_frame_free(&vmapped);
}

/* VA-API surface -> DRM PRIME -> one EGLImage per plane. */
static bool import_vaapi(AVFrame *f) {
	if (!has_dmabuf) return false;
	AVFrame *m = av_frame_alloc();
	m->format = AV_PIX_FMT_DRM_PRIME;
	if (av_hwframe_map(m, f, AV_HWFRAME_MAP_READ) < 0) { av_frame_free(&m); return false; }
	const AVDRMFrameDescriptor *d = (const AVDRMFrameDescriptor *)m->data[0];
	/* the planes, whether exported as separate layers or one two-plane layer */
	struct { int obj, off, pitch; uint32_t fourcc; } pl[2];
	int np = 0;
	bool ten = false;
	for (int l = 0; l < d->nb_layers && np < 2; l++)
		for (int p = 0; p < d->layers[l].nb_planes && np < 2; p++) {
			uint32_t fmt = d->layers[l].format;
			if (fmt == FOURCC('P', '0', '1', '0')) ten = true;
			if (d->layers[l].nb_planes > 1 || fmt == FOURCC('N', 'V', '1', '2') || fmt == FOURCC('P', '0', '1', '0'))
				fmt = ten ? (np ? FOURCC('G', 'R', '3', '2') : FOURCC('R', '1', '6', ' ')) : (np ? FOURCC('G', 'R', '8', '8') : FOURCC('R', '8', ' ', ' '));
			pl[np].obj = d->layers[l].planes[p].object_index;
			pl[np].off = (int)d->layers[l].planes[p].offset;
			pl[np].pitch = (int)d->layers[l].planes[p].pitch;
			pl[np].fourcc = fmt;
			np++;
		}
	if (np != 2) { av_frame_free(&m); return false; }
	EGLImageKHR img[2] = {0};
	for (int i = 0; i < 2; i++) {
		uint64_t mod = d->objects[pl[i].obj].format_modifier;
		EGLint a[32], k = 0;
		a[k++] = EGL_WIDTH; a[k++] = i ? (f->width + 1) / 2 : f->width;
		a[k++] = EGL_HEIGHT; a[k++] = i ? (f->height + 1) / 2 : f->height;
		a[k++] = EGL_LINUX_DRM_FOURCC_EXT; a[k++] = (EGLint)pl[i].fourcc;
		a[k++] = EGL_DMA_BUF_PLANE0_FD_EXT; a[k++] = d->objects[pl[i].obj].fd;
		a[k++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT; a[k++] = pl[i].off;
		a[k++] = EGL_DMA_BUF_PLANE0_PITCH_EXT; a[k++] = pl[i].pitch;
		if (has_modifiers && mod != DRM_FORMAT_MOD_INVALID) {
			a[k++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT; a[k++] = (EGLint)(mod & 0xffffffff);
			a[k++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT; a[k++] = (EGLint)(mod >> 32);
		}
		a[k++] = EGL_NONE;
		img[i] = create_image(edpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, a);
		if (!img[i]) {
			if (i) destroy_image(edpy, img[0]);
			av_frame_free(&m);
			return false;
		}
	}
	unmap_video();
	for (int i = 0; i < 2; i++) {
		glActiveTexture(GL_TEXTURE0 + i);
		glBindTexture(GL_TEXTURE_2D, vtex[i]);
		tex_params();
		image_target(GL_TEXTURE_2D, img[i]);
		vimg[i] = img[i];
	}
	vmapped = m;
	vmode = 2;
	return glGetError() == GL_NO_ERROR;
}

/* Make vtex hold frame f. */
static bool load_video(AVFrame *f, long idx) {
	if (idx == vtex_idx && f == vtex_f) return true;
	yuv_matrix(f, vm, voff);
	if (f->format == AV_PIX_FMT_VAAPI) {
		if (!import_vaapi(f)) {
			static bool told;
			if (!told) { printf("video dmabuf-import failed: copying frames from now on\n"); told = true; }
			video_want_copyback();
			return false;
		}
		static bool said;
		if (!said) { printf("video path dmabuf\n"); said = true; }
	} else if (f->format == AV_PIX_FMT_NV12) {
		unmap_video();
		plane(0, GL_LUMINANCE, f->width, f->height, f->data[0], f->linesize[0], 1);
		plane(1, GL_LUMINANCE_ALPHA, (f->width + 1) / 2, (f->height + 1) / 2, f->data[1], f->linesize[1], 2);
		vmode = 1;
	} else if (f->format == AV_PIX_FMT_YUV420P || f->format == AV_PIX_FMT_YUVJ420P) {
		unmap_video();
		for (int i = 0; i < 3; i++)
			plane(i, GL_LUMINANCE, i ? (f->width + 1) / 2 : f->width, i ? (f->height + 1) / 2 : f->height, f->data[i], f->linesize[i], 1);
		vmode = 0;
	} else return false;
	vtex_idx = idx; vtex_f = f;
	return true;
}

static void draw_video(struct output *o, AVFrame *f, long idx) {
	if (!load_video(f, idx) && vtex_idx < 0) return;
	int r[8];
	place(fitmode == FIT_TILE ? FIT_FILL : fitmode, f->width, f->height, o->pw, o->ph, r);
	glUseProgram(p_yuv);
	glUniformMatrix3fv(u_yuv_m, 1, GL_FALSE, vm);
	glUniform3fv(u_yuv_off, 1, voff);
	glUniform1i(u_yuv_mode, vmode);
	for (int i = 0; i < 3; i++) { glActiveTexture(GL_TEXTURE0 + i); glBindTexture(GL_TEXTURE_2D, vtex[i]); }
	quad(o->pw, o->ph, r[4], r[5], r[6], r[7], (float)r[0] / f->width, (float)r[1] / f->height,
		(float)(r[0] + r[2]) / f->width, (float)(r[1] + r[3]) / f->height);
}

static void clear(uint32_t c) {
	glClearColor(((c >> 16) & 255) / 255.f, ((c >> 8) & 255) / 255.f, (c & 255) / 255.f, 1);
	glClear(GL_COLOR_BUFFER_BIT);
}

/* The content and an ongoing transition; returns whether it goes on. */
static bool compose(struct output *o) {
	glViewport(0, 0, o->pw, o->ph);
	glDisable(GL_BLEND);
	long idx;
	AVFrame *f = mode == M_VIDEO ? video_frame(&idx) : NULL;
	if (mode == M_VIDEO) {
		clear(bg_colour);
		if (f) draw_video(o, f, idx);
	} else if (o->still_dirty || o->still_tex) {
		if (o->still_dirty) {
			if (o->still.px && o->still.w == o->pw && o->still.h == o->ph) {
				upload_rgba(&o->still_tex, &o->still);
				img_free(&o->still); /* the GPU has it */
			} else if (o->still_tex) { glDeleteTextures(1, &o->still_tex); o->still_tex = 0; }
			o->still_dirty = false;
		}
		if (o->still_tex) rgb_quad(o->still_tex, o->pw, o->ph, 0, 0, o->pw, o->ph, 1, false, false);
		else clear(mode == M_PEROUT ? o->perout_bg : bg_colour);
	} else clear(mode == M_PEROUT ? o->perout_bg : bg_colour);
	if (!o->prev_tex) return false;
	double t = o->fade_wait ? 0 : (now() - o->fade_t0) / o->fade_len;
	if (t >= 1) { glDeleteTextures(1, &o->prev_tex); o->prev_tex = 0; return false; }
	t = t * t * (3 - 2 * t);
	glEnable(GL_BLEND);
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	rgb_quad(o->prev_tex, o->pw, o->ph, 0, 0, o->pw, o->ph, (float)(1 - t), false, true);
	glDisable(GL_BLEND);
	return true;
}

static void gl_draw(struct output *o, bool *more) {
	if (!make_current(o)) return;
	*more = compose(o) || o->fade_wait;
	pre_commit(o, *more);
	struct gl_out *g = o->r;
	eglSwapBuffers(edpy, g->surf);
}

/* What is shown now, copied on the GPU into prev_tex (the back buffer is
 * redrawn before anything is shown). */
static bool capture_prev(struct output *o) {
	if (!o->configured || !make_current(o)) return false;
	compose(o);
	if (!o->prev_tex) glGenTextures(1, &o->prev_tex);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, o->prev_tex);
	tex_params();
	glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 0, 0, o->pw, o->ph, 0);
	return glGetError() == GL_NO_ERROR;
}

struct renderer gl_renderer = { "gl", init, output_init, output_fini, gl_draw, capture_prev };

/* ---- colour: YUV -> RGB for a frame (shared with nothing else, but kept apart) ---- */

void yuv_matrix(const AVFrame *f, float m[9], float off[3]) {
	/* BT.709 for HD and up, BT.601 below, unless the frame says; limited
	 * range unless it says full ("JPEG") */
	bool b709 = f->colorspace == AVCOL_SPC_BT709 || (f->colorspace == AVCOL_SPC_UNSPECIFIED && f->height >= 720);
	bool b2020 = f->colorspace == AVCOL_SPC_BT2020_NCL || f->colorspace == AVCOL_SPC_BT2020_CL;
	double kr = b2020 ? 0.2627 : b709 ? 0.2126 : 0.299, kb = b2020 ? 0.0593 : b709 ? 0.0722 : 0.114, kg = 1 - kr - kb;
	bool full = f->color_range == AVCOL_RANGE_JPEG || f->format == AV_PIX_FMT_YUVJ420P;
	double ys = full ? 1 : 255.0 / 219, cs = full ? 1 : 255.0 / 224;
	off[0] = full ? 0 : 16 / 255.f; off[1] = off[2] = 128 / 255.f;
	/* column-major mat3: rgb = M * (y, u, v) */
	m[0] = (float)ys; m[1] = (float)ys; m[2] = (float)ys;
	m[3] = 0; m[4] = (float)(-cs * 2 * (1 - kb) * kb / kg); m[5] = (float)(cs * 2 * (1 - kb));
	m[6] = (float)(cs * 2 * (1 - kr)); m[7] = (float)(-cs * 2 * (1 - kr) * kr / kg); m[8] = 0;
}
