/* video.c - ribbon-wall's video: muted, seamlessly looping, any file size.
 *
 * Three threads' worth of work, two threads:
 *
 *   reader:  demuxes the file into a packet queue, a few seconds ahead.
 *            Small clips (RESIDENT_BYTES) are read once and kept whole in
 *            memory: no disk I/O after the first pass. Longer ones keep only
 *            their start resident (the "head", up to the first keyframe after
 *            HEAD_SECONDS, within HEAD_BYTES) and stream the rest; at the end
 *            the reader seeks to the keyframe after the head while the
 *            decoder plays the head from memory, so the loop point never
 *            waits for the disk.
 *   decoder: decodes a few frames ahead into a small queue (QMAX). At the
 *            end of the clip it drains and flushes the decoder and starts
 *            again from the head; the 10-30 ms that takes is hidden by the
 *            queued frames.
 *   main:    a content clock that never restarts picks frame
 *            floor(t * fps), counted forever across loops, so frame N-1 is
 *            followed by frame 0 like any other frame (main.c's frame
 *            callbacks call video_advance()).
 *
 * Decoding: VA-API where the GPU's driver is a Mesa or Intel one (and on
 * NVIDIA through nvidia-vaapi-driver as the second choice), NVDEC through
 * FFmpeg's CUDA hwaccel on NVIDIA's own driver, software everywhere else
 * (nouveau/NVK, no driver, an unsupported codec). RIBBON_WALL_HW=
 * auto|vaapi|cuda|none overrides. GPU frames stay on the GPU when the GL
 * renderer can import them (VA-API -> DRM PRIME dmabuf -> EGLImage);
 * otherwise they are copied to memory here, in this thread.
 *
 * Copyright 2026 Ribbon OS contributors, MIT licence. */
#include "rw.h"
#include <dirent.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef HAVE_VA
#include <libavutil/hwcontext_vaapi.h>
#include <va/va.h>
#endif

#define QMAX 4                       /* decoded frames ahead */
#define PQMAX 2048                   /* packet ring (the byte/time caps below bind first) */
#define AHEAD_SECONDS 3.0            /* read-ahead while streaming */
#define AHEAD_BYTES (64 << 20)
#define HEAD_SECONDS 2.0
#define HEAD_BYTES (32 << 20)
static int64_t resident_bytes = 64 << 20; /* whole clip in memory up to this (RIBBON_WALL_RESIDENT_MB) */
double video_max_seconds = 300;           /* the longest clip accepted (RIBBON_WALL_MAX_SECONDS) */
bool video_need_sw_frames;

static struct {
	pthread_t rd, dec;
	bool running;
	volatile bool quit;
	pthread_mutex_t mu;
	pthread_cond_t cv;               /* any queue changed */
	AVFormatContext *fc;
	AVCodecContext *cc;
	AVBufferRef *hw;
	enum hwkind hwk;
	enum AVPixelFormat hwfmt;
	int vs;
	double fps;
	/* resident packets: the whole clip (all = true) or its head */
	AVPacket **mem;
	int nmem, head_n;                /* head_n: packets before the boundary keyframe */
	bool all, head_closed, mem_frozen;
	int64_t mem_bytes;
	AVPacket *bnd;                   /* the boundary keyframe (a copy, for checking seeks) */
	/* reader -> decoder; NULL marks the end of a pass through the clip */
	AVPacket *pq[PQMAX];
	int pq_head, pq_n;
	int64_t pq_bytes;
	/* decoder -> presentation */
	AVFrame *fq[QMAX];
	long fqidx[QMAX];
	int fq_head, fq_n;
	bool copyback;
	struct SwsContext *conv;         /* odd pixel formats -> yuv420p (software path) */
	/* presentation */
	double clock, last;
	long shown;
	AVFrame *cur;
	/* stats */
	long passes, seeks_exact, seeks_fallback, refills;
	int64_t bytes_read;
	struct video_info info;
} V = { .mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER, .shown = -1 };

static int64_t pkt_ts(const AVPacket *p) { return p->pts != AV_NOPTS_VALUE ? p->pts : p->dts; }
static bool same_pkt(const AVPacket *a, const AVPacket *b) {
	return a->pts == b->pts && a->dts == b->dts && a->size == b->size;
}

/* ---- choosing a decoder --------------------------------------------------------- */

/* The kernel drivers of the render nodes: i915, xe, amdgpu, radeon, nouveau, nvidia... */
static void gpu_drivers(char *out, size_t n, char *node, size_t nn) {
	out[0] = 0;
	if (node) node[0] = 0;
	DIR *d = opendir("/sys/class/drm");
	struct dirent *e;
	while (d && (e = readdir(d))) {
		if (strncmp(e->d_name, "renderD", 7)) continue;
		char link[300], tgt[300];
		snprintf(link, sizeof link, "/sys/class/drm/%s/device/driver", e->d_name);
		ssize_t k = readlink(link, tgt, sizeof tgt - 1);
		if (k <= 0) continue;
		tgt[k] = 0;
		char drv[32];
		snprintf(drv, sizeof drv, "%.31s", strrchr(tgt, '/') ? strrchr(tgt, '/') + 1 : tgt);
		/* the first non-NVIDIA render node is the one to use on a hybrid laptop */
		if (node && (!node[0] || (strstr(out, "nvidia") && strcmp(drv, "nvidia"))) && strcmp(drv, "nouveau"))
			snprintf(node, nn, "/dev/dri/%.40s", e->d_name);
		if (!strstr(out, drv) && strlen(out) + strlen(drv) + 2 < n) { strcat(out, drv); strcat(out, " "); }
	}
	if (d) closedir(d);
}

/* The order to try: VA-API on Mesa/Intel drivers (an iGPU first on hybrid
 * laptops: it drives the screen and costs least), on NVIDIA's own driver
 * NVDEC (CUDA) then VA-API (nvidia-vaapi-driver), software on nouveau. */
static int hw_order(enum hwkind *order, char *node, size_t nn, char *why, size_t wn) {
	const char *env = getenv("RIBBON_WALL_HW");
	if (getenv("RIBBON_WALL_NO_HW") || (env && !strcmp(env, "none"))) { snprintf(why, wn, "disabled"); return 0; }
	if (env && !strcmp(env, "vaapi")) { order[0] = HW_VAAPI; return 1; }
	if (env && !strcmp(env, "cuda")) { order[0] = HW_CUDA; return 1; }
	char drv[256];
	gpu_drivers(drv, sizeof drv, node, nn);
	int n = 0;
	bool mesa = strstr(drv, "i915") || strstr(drv, "xe ") || strstr(drv, "amdgpu") || strstr(drv, "radeon");
	if (mesa) order[n++] = HW_VAAPI;
	if (strstr(drv, "nvidia")) { order[n++] = HW_CUDA; if (!mesa) order[n++] = HW_VAAPI; }
	if (!n) snprintf(why, wn, "%s", !drv[0] ? "no GPU" : strstr(drv, "nouveau") ? "nouveau" : "GPU driver");
	return n;
}

#ifdef HAVE_VA
/* Does the VA-API driver decode this codec/profile? (FFmpeg's AV1 decoder
 * can't fall back to software by itself, so ask first, for every codec.) */
static bool va_supports(AVBufferRef *dev, const AVCodecParameters *cp) {
	VADisplay d = ((AVVAAPIDeviceContext *)((AVHWDeviceContext *)dev->data)->hwctx)->display;
	VAProfile want[4]; int nw = 0;
	switch (cp->codec_id) {
	case AV_CODEC_ID_H264: want[nw++] = VAProfileH264High; want[nw++] = VAProfileH264Main; break;
	case AV_CODEC_ID_HEVC: want[nw++] = cp->profile == 2 ? VAProfileHEVCMain10 : VAProfileHEVCMain; break;
	case AV_CODEC_ID_VP9: want[nw++] = cp->profile == 2 ? VAProfileVP9Profile2 : VAProfileVP9Profile0; break;
	case AV_CODEC_ID_AV1: want[nw++] = VAProfileAV1Profile0; break;
	case AV_CODEC_ID_VP8: want[nw++] = VAProfileVP8Version0_3; break;
	case AV_CODEC_ID_MPEG2VIDEO: want[nw++] = VAProfileMPEG2Main; break;
	default: return false;
	}
	int np = vaMaxNumProfiles(d);
	VAProfile *have = calloc(np, sizeof *have);
	bool ok = false;
	if (vaQueryConfigProfiles(d, have, &np) == VA_STATUS_SUCCESS)
		for (int i = 0; i < np && !ok; i++)
			for (int j = 0; j < nw; j++) if (have[i] == want[j]) ok = true;
	free(have);
	return ok;
}
#endif

static enum AVPixelFormat get_format(AVCodecContext *c, const enum AVPixelFormat *f) {
	(void)c;
	const enum AVPixelFormat *p;
	for (p = f; *p != AV_PIX_FMT_NONE; p++) if (*p == V.hwfmt) return *p;
	for (p = f; *p != AV_PIX_FMT_NONE; p++)
		if (!(av_pix_fmt_desc_get(*p)->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
	return AV_PIX_FMT_NONE;
}

static bool codec_has_hw(const AVCodec *c, enum AVHWDeviceType t, enum AVPixelFormat *fmt) {
	for (int i = 0;; i++) {
		const AVCodecHWConfig *h = avcodec_get_hw_config(c, i);
		if (!h) return false;
		if ((h->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && h->device_type == t) { *fmt = h->pix_fmt; return true; }
	}
}

static bool open_decoder(AVStream *st, char *err, size_t n) {
	const AVCodecParameters *cp = st->codecpar;
	const AVCodec *sw = avcodec_find_decoder(cp->codec_id), *c = NULL;
	if (cp->codec_id == AV_CODEC_ID_AV1) { const AVCodec *d = avcodec_find_decoder_by_name("libdav1d"); if (d) sw = d; }
	enum hwkind order[3];
	char node[64];
	int no = hw_order(order, node, sizeof node, V.info.why_sw, sizeof V.info.why_sw);
	for (int i = 0; i < no && !c; i++) {
		const AVCodec *hc = avcodec_find_decoder(cp->codec_id); /* FFmpeg's own decoders carry the hwaccels */
		enum AVHWDeviceType t = order[i] == HW_CUDA ? AV_HWDEVICE_TYPE_CUDA : AV_HWDEVICE_TYPE_VAAPI;
		enum AVPixelFormat fmt;
		if (!hc || !codec_has_hw(hc, t, &fmt)) { snprintf(V.info.why_sw, sizeof V.info.why_sw, "codec"); continue; }
		const char *dev = t == AV_HWDEVICE_TYPE_VAAPI && node[0] ? node : NULL;
		if (av_hwdevice_ctx_create(&V.hw, t, dev, NULL, 0) < 0) { snprintf(V.info.why_sw, sizeof V.info.why_sw, "no %s device", t == AV_HWDEVICE_TYPE_CUDA ? "CUDA" : "VA-API"); continue; }
#ifdef HAVE_VA
		if (t == AV_HWDEVICE_TYPE_VAAPI && !va_supports(V.hw, cp)) {
			snprintf(V.info.why_sw, sizeof V.info.why_sw, "VA-API lacks %s", avcodec_get_name(cp->codec_id));
			av_buffer_unref(&V.hw);
			continue;
		}
#endif
		c = hc; V.hwk = order[i]; V.hwfmt = fmt;
	}
	if (!c) { c = sw; V.hwk = HW_NONE; V.hwfmt = AV_PIX_FMT_NONE; }
	if (!c) { snprintf(err, n, "no decoder for %s", avcodec_get_name(cp->codec_id)); return false; }
	V.cc = avcodec_alloc_context3(c);
	avcodec_parameters_to_context(V.cc, cp);
	V.cc->pkt_timebase = st->time_base;
	V.cc->get_format = get_format;
	if (V.hwk != HW_NONE) {
		V.cc->hw_device_ctx = av_buffer_ref(V.hw);
		V.cc->extra_hw_frames = QMAX + 3; /* the queue, the frame on screen, the one being imported */
	} else {
		V.cc->thread_count = 0; /* as many as the CPU has: 4K needs them */
		V.cc->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
	}
	if (avcodec_open2(V.cc, c, NULL) < 0) { snprintf(err, n, "cannot open the %s decoder", c->name); return false; }
	snprintf(V.info.decoder, sizeof V.info.decoder, "%s", c->name);
	snprintf(V.info.hw, sizeof V.info.hw, "%s", V.hwk == HW_VAAPI ? "vaapi" : V.hwk == HW_CUDA ? "cuda" : "none");
	return true;
}

/* ---- opening and probing ---------------------------------------------------------- */

static bool open_file(const char *file, AVFormatContext **fc, int *vs, struct video_info *vi, char *err, size_t n) {
	*fc = NULL;
	if (avformat_open_input(fc, file, NULL, NULL) < 0) { snprintf(err, n, "cannot read"); return false; }
	if (avformat_find_stream_info(*fc, NULL) < 0) { snprintf(err, n, "not a video"); return false; }
	*vs = av_find_best_stream(*fc, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
	if (*vs < 0) { snprintf(err, n, "no video stream"); return false; }
	AVStream *st = (*fc)->streams[*vs];
	if (st->disposition & AV_DISPOSITION_ATTACHED_PIC) { snprintf(err, n, "a picture, not a video"); return false; }
	memset(vi, 0, sizeof *vi);
	snprintf(vi->codec, sizeof vi->codec, "%s", avcodec_get_name(st->codecpar->codec_id));
	vi->w = st->codecpar->width; vi->h = st->codecpar->height;
	vi->fps = av_q2d(st->avg_frame_rate);
	if (vi->fps <= 0 || vi->fps > 240) vi->fps = av_q2d(st->r_frame_rate);
	if (vi->fps <= 0 || vi->fps > 240) vi->fps = 30;
	vi->duration = st->duration != AV_NOPTS_VALUE ? st->duration * av_q2d(st->time_base)
		: (*fc)->duration != AV_NOPTS_VALUE ? (*fc)->duration / (double)AV_TIME_BASE : 0;
	vi->frames = st->nb_frames > 0 ? st->nb_frames : (long)(vi->duration * vi->fps + 0.5);
	vi->bytes = (*fc)->pb ? avio_size((*fc)->pb) : -1;
	return true;
}

static bool too_long(const struct video_info *vi, char *err, size_t n) {
	if (vi->duration > video_max_seconds + 0.05) {
		snprintf(err, n, "too long: %.1f s, at most %.0f s", vi->duration, video_max_seconds);
		return true;
	}
	if (vi->duration <= 0) { snprintf(err, n, "unknown length"); return true; }
	return false;
}

/* For the Appearance app's "Add video" (ribbon-wall --probe FILE) and for
 * "video": the same rule in both places. */
bool video_probe(const char *file, struct video_info *vi, char *err, size_t n) {
	AVFormatContext *fc;
	int vs;
	bool ok = open_file(file, &fc, &vs, vi, err, n) && !too_long(vi, err, n);
	avformat_close_input(&fc);
	return ok;
}

/* ---- reader thread ------------------------------------------------------------- */

static void pq_push(AVPacket *p) { /* p: an owned packet, or NULL (end of pass); blocks while full */
	pthread_mutex_lock(&V.mu);
	for (;;) {
		if (V.quit) { pthread_mutex_unlock(&V.mu); av_packet_free(&p); return; }
		bool full = V.pq_n >= PQMAX || (V.pq_n >= 8 && (V.pq_bytes >= AHEAD_BYTES || V.pq_n >= V.fps * AHEAD_SECONDS));
		if (!full) break;
		pthread_cond_wait(&V.cv, &V.mu);
	}
	V.pq[(V.pq_head + V.pq_n) % PQMAX] = p;
	V.pq_n++;
	if (p) V.pq_bytes += p->size;
	pthread_cond_broadcast(&V.cv);
	pthread_mutex_unlock(&V.mu);
}

/* Remember pass 0's packets while the whole clip may still fit; once it
 * can't, keep only the head (up to a keyframe boundary). */
static void remember(AVPacket *p) {
	if (V.mem_frozen) return;
	double t = (pkt_ts(p) - (V.fc->streams[V.vs]->start_time != AV_NOPTS_VALUE ? V.fc->streams[V.vs]->start_time : 0))
		* av_q2d(V.fc->streams[V.vs]->time_base);
	if (!V.head_closed && (p->flags & AV_PKT_FLAG_KEY) && V.nmem > 0 && t >= HEAD_SECONDS - 1e-3) {
		V.head_closed = true; V.head_n = V.nmem; V.bnd = av_packet_clone(p);
	}
	if (V.mem_bytes + p->size > resident_bytes) {
		/* too big to keep whole: shrink to the head */
		int keep = V.head_closed ? V.head_n : 0;
		int64_t b = 0;
		for (int i = 0; i < keep; i++) b += V.mem[i]->size;
		if (b > HEAD_BYTES || !V.head_closed) { /* the last keyframe within HEAD_BYTES */
			keep = 0; b = 0;
			int64_t acc = 0;
			for (int i = 0; i < V.nmem; i++) {
				if (i > 0 && (V.mem[i]->flags & AV_PKT_FLAG_KEY) && acc <= HEAD_BYTES) { keep = i; b = acc; }
				acc += V.mem[i]->size;
			}
			if (!V.head_closed && (p->flags & AV_PKT_FLAG_KEY) && acc <= HEAD_BYTES && V.nmem > 0) { keep = V.nmem; b = acc; }
			av_packet_free(&V.bnd);
			if (keep) V.bnd = av_packet_clone(keep < V.nmem ? V.mem[keep] : p);
		}
		for (int i = keep; i < V.nmem; i++) av_packet_free(&V.mem[i]);
		pthread_mutex_lock(&V.mu);
		V.nmem = V.head_n = keep; V.mem_bytes = b; V.head_closed = true; V.mem_frozen = true;
		pthread_mutex_unlock(&V.mu);
		return;
	}
	V.mem = realloc(V.mem, (V.nmem + 1) * sizeof *V.mem);
	V.mem[V.nmem++] = av_packet_clone(p);
	V.mem_bytes += p->size;
}

static void seek_start(void) {
	av_seek_frame(V.fc, V.vs, V.fc->streams[V.vs]->start_time != AV_NOPTS_VALUE ? V.fc->streams[V.vs]->start_time : 0,
		AVSEEK_FLAG_BACKWARD);
}

static void *reader(void *u) {
	(void)u;
	AVPacket *p = av_packet_alloc();
	int pass = 0, skip = 0;
	bool check = false; /* after a seek: the next packet must be the boundary */
	while (!V.quit) {
		int r = av_read_frame(V.fc, p);
		if (r == AVERROR(EAGAIN)) continue;
		if (r < 0) {
			if (pass == 0) {
				pthread_mutex_lock(&V.mu);
				if (!V.mem_frozen) { V.all = true; V.head_n = V.nmem; }
				V.mem_frozen = true;
				pthread_mutex_unlock(&V.mu);
			}
			pq_push(NULL);
			if (V.all) break; /* everything is in memory: the decoder loops on its own */
			pass++;
			V.refills++;
			if (V.head_n > 0 && V.bnd) {
				int64_t ts = pkt_ts(V.bnd);
				if (avformat_seek_file(V.fc, V.vs, ts, ts, ts, 0) >= 0) check = true;
				else { seek_start(); skip = V.head_n; check = true; V.seeks_fallback++; }
			} else seek_start();
			continue;
		}
		if (p->stream_index != V.vs) { av_packet_unref(p); continue; }
		V.bytes_read += p->size;
		if (pass == 0) remember(p);
		else if (skip > 0) { skip--; av_packet_unref(p); continue; }
		else if (check) {
			check = false;
			if (!same_pkt(p, V.bnd)) { /* the seek landed elsewhere: from the start, skip the head */
				av_packet_unref(p);
				seek_start(); skip = V.head_n; check = true; V.seeks_fallback++;
				continue;
			}
			V.seeks_exact++;
		}
		pq_push(av_packet_clone(p));
		av_packet_unref(p);
	}
	av_packet_free(&p);
	return NULL;
}

/* ---- decoder thread ---------------------------------------------------------- */

static long frame_idx;

static void fq_push(AVFrame *f) {
	pthread_mutex_lock(&V.mu);
	while (V.fq_n == QMAX && !V.quit) pthread_cond_wait(&V.cv, &V.mu);
	if (V.quit) { pthread_mutex_unlock(&V.mu); av_frame_free(&f); return; }
	V.fq[(V.fq_head + V.fq_n) % QMAX] = f;
	V.fqidx[(V.fq_head + V.fq_n) % QMAX] = frame_idx++;
	V.fq_n++;
	pthread_cond_broadcast(&V.cv);
	pthread_mutex_unlock(&V.mu);
}

static void receive_all(void) {
	for (;;) {
		AVFrame *f = av_frame_alloc();
		if (avcodec_receive_frame(V.cc, f) < 0) { av_frame_free(&f); return; }
		if (f->hw_frames_ctx && (V.copyback || video_need_sw_frames || V.hwk == HW_CUDA)) {
			AVFrame *s = av_frame_alloc(); /* GPU frame -> memory (NV12) */
			if (av_hwframe_transfer_data(s, f, 0) < 0) { av_frame_free(&s); av_frame_free(&f); continue; }
			av_frame_copy_props(s, f);
			av_frame_free(&f); f = s;
		}
		if (!f->hw_frames_ctx && f->format != AV_PIX_FMT_YUV420P && f->format != AV_PIX_FMT_YUVJ420P
			&& f->format != AV_PIX_FMT_NV12 && !video_need_sw_frames) {
			/* 10-bit, 4:2:2, 4:4:4...: to 8-bit 4:2:0 for the GL path's shader */
			AVFrame *s = av_frame_alloc();
			s->format = AV_PIX_FMT_YUV420P; s->width = f->width; s->height = f->height;
			av_frame_get_buffer(s, 0);
			V.conv = sws_getCachedContext(V.conv, f->width, f->height, f->format, f->width, f->height,
				AV_PIX_FMT_YUV420P, SWS_POINT, NULL, NULL, NULL);
			sws_scale(V.conv, (const uint8_t *const *)f->data, f->linesize, 0, f->height, s->data, s->linesize);
			av_frame_copy_props(s, f);
			av_frame_free(&f); f = s;
		}
		fq_push(f);
		if (V.quit) return;
	}
}

static void feed(AVPacket *p) {
	for (;;) {
		int r = avcodec_send_packet(V.cc, p);
		receive_all();
		if (r != AVERROR(EAGAIN) || V.quit) return;
	}
}

static void *decoder(void *u) {
	(void)u;
	AVPacket *p = av_packet_alloc();
	for (long pass = 0; !V.quit; pass++) {
		bool from_queue = true;
		if (pass > 0) {
			pthread_mutex_lock(&V.mu);
			int n = V.head_n; bool all = V.all;
			pthread_mutex_unlock(&V.mu);
			for (int i = 0; i < n && !V.quit; i++) { av_packet_ref(p, V.mem[i]); feed(p); av_packet_unref(p); }
			from_queue = !all;
		}
		while (from_queue && !V.quit) {
			pthread_mutex_lock(&V.mu);
			while (!V.pq_n && !V.quit) pthread_cond_wait(&V.cv, &V.mu);
			if (V.quit) { pthread_mutex_unlock(&V.mu); break; }
			AVPacket *q = V.pq[V.pq_head];
			V.pq_head = (V.pq_head + 1) % PQMAX; V.pq_n--;
			if (q) V.pq_bytes -= q->size;
			pthread_cond_broadcast(&V.cv);
			pthread_mutex_unlock(&V.mu);
			if (!q) break; /* end of this pass */
			feed(q);
			av_packet_free(&q);
		}
		/* end of the clip: drain, flush, and round again */
		feed(NULL);
		avcodec_flush_buffers(V.cc);
		V.passes++;
	}
	av_packet_free(&p);
	return NULL;
}

/* ---- start / stop ------------------------------------------------------------- */

void video_stop(void) {
	if (V.running) {
		pthread_mutex_lock(&V.mu); V.quit = true; pthread_cond_broadcast(&V.cv); pthread_mutex_unlock(&V.mu);
		pthread_join(V.rd, NULL);
		pthread_join(V.dec, NULL);
		V.running = false;
	}
	for (; V.fq_n; V.fq_n--, V.fq_head = (V.fq_head + 1) % QMAX) av_frame_free(&V.fq[V.fq_head]);
	for (; V.pq_n; V.pq_n--, V.pq_head = (V.pq_head + 1) % PQMAX) av_packet_free(&V.pq[V.pq_head]);
	av_frame_free(&V.cur);
	for (int i = 0; i < V.nmem; i++) av_packet_free(&V.mem[i]);
	free(V.mem);
	av_packet_free(&V.bnd);
	avcodec_free_context(&V.cc);
	avformat_close_input(&V.fc);
	av_buffer_unref(&V.hw);
	sws_freeContext(V.conv);
	V.mem = NULL; V.nmem = V.head_n = 0; V.mem_bytes = 0; V.all = V.head_closed = V.mem_frozen = false;
	V.conv = NULL; V.quit = false; V.fq_head = V.pq_head = 0; V.pq_bytes = 0; V.copyback = false;
	V.shown = -1; V.clock = 0; V.last = 0; V.hwk = HW_NONE; frame_idx = 0;
	V.passes = V.seeks_exact = V.seeks_fallback = V.refills = 0; V.bytes_read = 0;
}

bool video_start(const char *file, struct video_info *vi, char *err, size_t n) {
	video_stop();
	const char *e = getenv("RIBBON_WALL_RESIDENT_MB");
	if (e) resident_bytes = (int64_t)(atof(e) * (1 << 20));
	if (!open_file(file, &V.fc, &V.vs, &V.info, err, n) || too_long(&V.info, err, n)) { video_stop(); return false; }
	V.fps = V.info.fps;
	if (!open_decoder(V.fc->streams[V.vs], err, n)) { video_stop(); return false; }
	V.running = true;
	pthread_create(&V.rd, NULL, reader, NULL);
	pthread_create(&V.dec, NULL, decoder, NULL);
	/* wait (briefly) for the first pass to show whether the clip stays resident */
	snprintf(V.info.store, sizeof V.info.store, "%s", V.info.bytes >= 0 && V.info.bytes <= resident_bytes ? "resident" : "stream");
	*vi = V.info;
	return true;
}

bool video_running(void) { return V.running; }
double video_fps(void) { return V.fps; }
void video_want_copyback(void) { V.copyback = true; }

void video_stats(char *buf, size_t n) {
	pthread_mutex_lock(&V.mu);
	snprintf(buf, n, "store %s resident_bytes %lld head_packets %d queue_packets %d queue_bytes %lld frames_queued %d "
		"passes %ld seeks_exact %ld seeks_fallback %ld bytes_read %lld hw %s decoder %s",
		V.all ? "resident" : V.mem_frozen ? "stream" : "reading", (long long)V.mem_bytes, V.head_n, V.pq_n,
		(long long)V.pq_bytes, V.fq_n, V.passes, V.seeks_exact, V.seeks_fallback, (long long)V.bytes_read,
		V.info.hw, V.info.decoder);
	pthread_mutex_unlock(&V.mu);
}

/* ---- presentation ------------------------------------------------------------ */

void video_reset_clock(void) { V.last = 0; }

bool video_advance(void) {
	double t = now();
	if (V.last > 0) {
		double dt = t - V.last;
		if (dt > 0.1) dt = 1 / V.fps; /* after a pause or occlusion: carry on, don't catch up */
		V.clock += dt;
	}
	V.last = t;
	long due = (long)(V.clock * V.fps + 0.25); /* a quarter-frame early: vblank jitter */
	bool got = false;
	pthread_mutex_lock(&V.mu);
	if (!V.cur && V.fq_n) due = V.fqidx[V.fq_head]; /* the very first frame: start the clock at it */
	while (V.fq_n && V.fqidx[V.fq_head] <= due) {
		av_frame_free(&V.cur);
		V.cur = V.fq[V.fq_head]; V.shown = V.fqidx[V.fq_head];
		V.fq_head = (V.fq_head + 1) % QMAX; V.fq_n--;
		got = true;
	}
	if (got && V.shown == 0) V.clock = 0;
	pthread_cond_broadcast(&V.cv);
	pthread_mutex_unlock(&V.mu);
	return got;
}

AVFrame *video_frame(long *index) {
	if (index) *index = V.shown;
	return V.cur;
}
