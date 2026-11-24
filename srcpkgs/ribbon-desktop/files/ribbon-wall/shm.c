/* shm.c - ribbon-wall's software renderer: wl_shm buffers, FFmpeg's swscale
 * for video, a plain C loop for crossfades. Used when EGL isn't
 * available (some virtual machines) or RIBBON_WALL_RENDERER=shm.
 *
 * Copyright 2026 Ribbon OS contributors, MIT licence. */
#include "rw.h"
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

struct buf {
	struct wl_buffer *wl;
	uint32_t *px;
	size_t size;
	int w, h;
	bool busy;
	struct shm_out *owner;
};

struct shm_out {
	struct buf bufs[3];
	bool idle;            /* nothing animates: give back the buffers the compositor returns */
	struct SwsContext *sws;
	int sws_key[5];
};

static void buf_free(struct buf *b) {
	if (b->wl) wl_buffer_destroy(b->wl);
	if (b->px) munmap(b->px, b->size);
	struct shm_out *s = b->owner;
	memset(b, 0, sizeof *b);
	b->owner = s;
}

static void buf_release(void *data, struct wl_buffer *wb) {
	(void)wb;
	struct buf *b = data;
	b->busy = false;
	if (b->owner->idle) buf_free(b);
}
static const struct wl_buffer_listener buf_listener = { buf_release };

static struct buf *buf_get(struct output *o) {
	struct shm_out *s = o->r;
	for (int i = 0; i < 3; i++) {
		struct buf *b = &s->bufs[i];
		if (b->busy) continue;
		if (b->wl && (b->w != o->pw || b->h != o->ph)) buf_free(b);
		if (!b->wl) {
			int stride = o->pw * 4;
			b->size = (size_t)stride * o->ph;
			int fd = memfd_create("ribbon-wall", MFD_CLOEXEC);
			if (fd < 0 || ftruncate(fd, b->size) < 0) { if (fd >= 0) close(fd); return NULL; }
			b->px = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
			struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, b->size);
			b->wl = wl_shm_pool_create_buffer(pool, 0, o->pw, o->ph, stride, WL_SHM_FORMAT_XRGB8888);
			wl_shm_pool_destroy(pool);
			close(fd);
			wl_buffer_add_listener(b->wl, &buf_listener, b);
			b->w = o->pw; b->h = o->ph;
		}
		return b;
	}
	return NULL; /* all three with the compositor: skip this frame */
}

static bool init(void) { return true; }
static void output_init(struct output *o) {
	struct shm_out *s = calloc(1, sizeof *s);
	for (int i = 0; i < 3; i++) s->bufs[i].owner = s;
	o->r = s;
}
static void output_fini(struct output *o) {
	struct shm_out *s = o->r;
	if (!s) return;
	for (int i = 0; i < 3; i++) buf_free(&s->bufs[i]);
	sws_freeContext(s->sws);
	free(s);
	o->r = NULL;
}

static void draw_video(struct output *o, uint32_t *px, AVFrame *f) {
	struct shm_out *s = o->r;
	int r[8];
	place(fitmode == FIT_TILE ? FIT_FILL : fitmode, f->width, f->height, o->pw, o->ph, r);
	const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(f->format);
	r[0] &= ~((1 << d->log2_chroma_w) - 1); r[1] &= ~((1 << d->log2_chroma_h) - 1);
	int key[5] = {f->format, f->width, f->height, o->pw * 65536 + o->ph, fitmode};
	if (!s->sws || memcmp(key, s->sws_key, sizeof key)) {
		sws_freeContext(s->sws);
		s->sws = sws_getContext(r[2], r[3], f->format, r[6], r[7], AV_PIX_FMT_BGR0, SWS_BILINEAR, NULL, NULL, NULL);
		memcpy(s->sws_key, key, sizeof key);
	}
	const uint8_t *src[4] = { f->data[0], f->data[1], f->data[2], f->data[3] };
	bool done[4] = {0};
	for (int c = 0; c < d->nb_components; c++) { /* crop: each plane's start at (r[0], r[1]) */
		int p = d->comp[c].plane;
		if (done[p]) continue;
		bool chroma = (c == 1 || c == 2) && !(d->flags & AV_PIX_FMT_FLAG_RGB);
		int sx = chroma ? r[0] >> d->log2_chroma_w : r[0], sy = chroma ? r[1] >> d->log2_chroma_h : r[1];
		src[p] = f->data[p] + sy * f->linesize[p] + sx * d->comp[c].step;
		done[p] = true;
	}
	if (r[6] != o->pw || r[7] != o->ph) fill(px, (size_t)o->pw * o->ph, bg_colour);
	uint8_t *dst[4] = { (uint8_t *)(px + (size_t)r[5] * o->pw + r[4]) };
	int dls[4] = { o->pw * 4 };
	sws_scale(s->sws, src, f->linesize, 0, r[3], dst, dls);
}

static void blend(uint32_t *dst, const uint32_t *src, size_t n, uint32_t k /* 0..256: weight of src */) {
	for (size_t i = 0; i < n; i++) {
		uint32_t a = src[i], c = dst[i];
		uint32_t rb = ((a & 0xff00ff) * k + (c & 0xff00ff) * (256 - k)) >> 8 & 0xff00ff;
		uint32_t g = ((a & 0xff00) * k + (c & 0xff00) * (256 - k)) >> 8 & 0xff00;
		dst[i] = 0xff000000 | rb | g;
	}
}

/* The content and an ongoing transition. Returns whether
 * the transition goes on. */
static bool compose(struct output *o, uint32_t *px) {
	size_t n = (size_t)o->pw * o->ph;
	AVFrame *f = mode == M_VIDEO ? video_frame(NULL) : NULL;
	if (f) draw_video(o, px, f);
	else if (o->still.px && o->still.w == o->pw && o->still.h == o->ph) memcpy(px, o->still.px, n * 4);
	else fill(px, n, mode == M_PEROUT ? o->perout_bg : bg_colour);
	if (!o->prev.px) return false;
	if (o->prev.w != o->pw || o->prev.h != o->ph) { img_free(&o->prev); return false; }
	double t = o->fade_wait ? 0 : (now() - o->fade_t0) / o->fade_len;
	if (t >= 1) { img_free(&o->prev); return false; }
	t = t * t * (3 - 2 * t); /* smoothstep: no visible start and end */
	blend(px, o->prev.px, n, (uint32_t)((1 - t) * 256));
	return true;
}

static void shm_draw(struct output *o, bool *more) {
	struct shm_out *s = o->r;
	struct buf *b = s ? buf_get(o) : NULL;
	if (!b) { request_frame(o); wl_surface_commit(o->surf); return; }
	*more = compose(o, b->px) || o->fade_wait;
	s->idle = !*more && mode != M_VIDEO;
	wl_surface_attach(o->surf, b->wl, 0, 0);
	wl_surface_damage_buffer(o->surf, 0, 0, o->pw, o->ph);
	b->busy = true;
	pre_commit(o, *more);
	wl_surface_commit(o->surf);
	if (s->idle) for (int i = 0; i < 3; i++) if (!s->bufs[i].busy) buf_free(&s->bufs[i]);
}

static bool capture_prev(struct output *o) {
	if (!o->configured || o->pw <= 0) return false;
	struct img g = { malloc((size_t)o->pw * o->ph * 4), o->pw, o->ph };
	compose(o, g.px);
	img_free(&o->prev);
	o->prev = g;
	return true;
}

struct renderer shm_renderer = { "shm", init, output_init, output_fini, shm_draw, capture_prev };
