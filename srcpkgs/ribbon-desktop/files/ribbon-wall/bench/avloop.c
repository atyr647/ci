/* avloop FILE SECONDS QUEUE MODE [HZ] : the ribbon-wall loop design, measured.
 * A decode thread keeps up to QUEUE decoded frames ahead; a presenter ticks
 * at HZ (default 60, like a monitor's vblank) and shows the frame a
 * continuous content clock asks for: index = floor(t * fps) mod N, so the
 * loop point is just frame N-1 -> 0 and no clock is ever restarted.
 * MODE: seek   - at EOF drain, av_seek_frame(0), avcodec_flush_buffers
 *       reopen - at EOF close and reopen file and decoder (restart-style)
 *       mem    - all packets read into memory once; at EOF rewind the list
 * Logs "time index" whenever the shown frame changes; stderr: loop service
 * times (EOF -> first new frame decoded) and stalls. */
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>
static const char *path; static int Q, mode, N; static double fps;
static AVFrame **ring; static int rhead, rcount; static long produced;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t notfull = PTHREAD_COND_INITIALIZER;
static volatile int quit;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static AVFormatContext *fc; static AVCodecContext *cc; static int vs;
static AVPacket **mem; static int nmem;
static void open_all(void) {
	fc = NULL; avformat_open_input(&fc, path, NULL, NULL); avformat_find_stream_info(fc, NULL);
	vs = av_find_best_stream(fc, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
	AVStream *st = fc->streams[vs];
	const AVCodec *c = avcodec_find_decoder(st->codecpar->codec_id);
	if (st->codecpar->codec_id == AV_CODEC_ID_AV1) { const AVCodec *d = avcodec_find_decoder_by_name("libdav1d"); if (d) c = d; }
	cc = avcodec_alloc_context3(c); avcodec_parameters_to_context(cc, st->codecpar);
	cc->thread_count = 0; avcodec_open2(cc, c, NULL);
	fps = av_q2d(st->avg_frame_rate);
}
static void push(AVFrame *f) {
	pthread_mutex_lock(&mu);
	while (rcount == Q && !quit) pthread_cond_wait(&notfull, &mu);
	ring[(rhead + rcount) % Q] = f; rcount++; produced++;
	pthread_mutex_unlock(&mu);
}
static void *decoder(void *u) {
	(void)u; AVPacket *p = av_packet_alloc(); int mi = 0; double eof_t = 0; int want_first = 0;
	double worst = 0, sum = 0; int loops = 0;
	while (!quit) {
		int r;
		if (mode == 2) { if (mi < nmem) { av_packet_ref(p, mem[mi++]); r = 0; } else r = AVERROR_EOF; }
		else r = av_read_frame(fc, p);
		if (r == 0 && p->stream_index != vs) { av_packet_unref(p); continue; }
		avcodec_send_packet(cc, r == 0 ? p : NULL);
		av_packet_unref(p);
		for (;;) {
			AVFrame *f = av_frame_alloc();
			if (avcodec_receive_frame(cc, f) < 0) { av_frame_free(&f); break; }
			if (want_first) { double d = now() - eof_t; if (d > worst) worst = d; sum += d; loops++; want_first = 0; }
			push(f);
		}
		if (r < 0) { /* EOF: everything is drained; go round */
			eof_t = now(); want_first = 1;
			if (mode == 1) { avcodec_free_context(&cc); avformat_close_input(&fc); open_all(); }
			else { avcodec_flush_buffers(cc); if (mode == 0) av_seek_frame(fc, vs, 0, AVSEEK_FLAG_BACKWARD); else mi = 0; }
		}
	}
	fprintf(stderr, "loop service (EOF->first frame decoded): mean %.2f ms worst %.2f ms over %d loops\n", loops ? sum / loops * 1e3 : 0, worst * 1e3, loops);
	return NULL;
}
int main(int argc, char **argv) {
	path = argv[1]; double dur = atof(argv[2]); Q = atoi(argv[3]);
	mode = !strcmp(argv[4], "reopen") ? 1 : !strcmp(argv[4], "mem") ? 2 : 0;
	double hz = argc > 5 ? atof(argv[5]) : 60;
	open_all();
	{ /* count frames (N) */ AVPacket *p = av_packet_alloc(); N = 0;
	  while (av_read_frame(fc, p) == 0) { if (p->stream_index == vs) { N++; if (mode == 2) { mem = realloc(mem, (nmem + 1) * sizeof *mem); mem[nmem++] = av_packet_clone(p); } } av_packet_unref(p); }
	  av_seek_frame(fc, vs, 0, AVSEEK_FLAG_BACKWARD); av_packet_free(&p); }
	ring = calloc(Q, sizeof *ring);
	pthread_t th; pthread_create(&th, NULL, decoder, NULL);
	while (1) { pthread_mutex_lock(&mu); int n = rcount; pthread_mutex_unlock(&mu); if (n == Q) break; struct timespec s = {0, 1000000}; nanosleep(&s, NULL); }
	struct timespec tick; clock_gettime(CLOCK_MONOTONIC, &tick);
	double t0 = tick.tv_sec + tick.tv_nsec / 1e9; long shown = -1; int stalls = 0, drops = 0, lastidx = -1;
	long period = (long)(1e9 / hz);
	while (now() - t0 < dur) {
		long due = (long)((now() - t0) * fps + 1e-6); /* content frame wanted now */
		pthread_mutex_lock(&mu);
		while (shown < due && rcount) { /* consume up to the due frame */
			AVFrame *f = ring[rhead]; rhead = (rhead + 1) % Q; rcount--; shown++;
			if (shown < due) drops++;
			lastidx = 0; /* barcode from luma */
			for (int b = 0; b < 16; b++) if (f->data[0][12 * f->linesize[0] + b * 24 + 12] > 128) lastidx |= 1 << b;
			av_frame_free(&f);
			pthread_cond_signal(&notfull);
			if (shown == due) printf("%.6f %d\n", now() - t0, lastidx);
		}
		if (shown < due) stalls++;
		pthread_mutex_unlock(&mu);
		tick.tv_nsec += period; while (tick.tv_nsec >= 1000000000) { tick.tv_nsec -= 1000000000; tick.tv_sec++; }
		clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &tick, NULL);
	}
	quit = 1; pthread_mutex_lock(&mu); pthread_cond_broadcast(&notfull); pthread_mutex_unlock(&mu);
	pthread_join(th, NULL);
	struct rusage ru; getrusage(RUSAGE_SELF, &ru);
	fprintf(stderr, "cpu %.1f%% of one core, maxrss %ld MB\n", 100.0 * (ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 + ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6) / (now() - t0), ru.ru_maxrss / 1024);
	fprintf(stderr, "presenter: stalled vblanks %d, dropped frames %d, N=%d fps=%.2f\n", stalls, drops, N, fps);
	return 0;
}
