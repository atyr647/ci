/* mpvloop FILE SECONDS [opt=val ...] : play FILE looped through libmpv's
 * software render API (what mpvpaper does with GL) and log, for every frame
 * mpv hands over, the monotonic time and the barcode frame index. */
#include <mpv/client.h>
#include <mpv/render.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int pending;
static void on_update(void *ctx) { (void)ctx; pthread_mutex_lock(&mu); pending = 1; pthread_cond_signal(&cv); pthread_mutex_unlock(&mu); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
int main(int argc, char **argv) {
	mpv_handle *m = mpv_create();
	mpv_set_option_string(m, "vo", "libmpv");
	mpv_set_option_string(m, "audio", "no");
	mpv_set_option_string(m, "loop-file", "inf");
	mpv_set_option_string(m, "hwdec", "no");
	mpv_set_option_string(m, "terminal", "no");
	for (int i = 3; i < argc; i++) {
		char *e = strchr(argv[i], '='); *e = 0;
		if (mpv_set_option_string(m, argv[i], e + 1) < 0) fprintf(stderr, "bad option %s\n", argv[i]);
	}
	if (mpv_initialize(m) < 0) return 1;
	mpv_render_param p[] = {{MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW}, {0}};
	mpv_render_context *rc;
	if (mpv_render_context_create(&rc, m, p) < 0) { fprintf(stderr, "no sw render\n"); return 1; }
	mpv_render_context_set_update_callback(rc, on_update, NULL);
	const char *cmd[] = {"loadfile", argv[1], NULL};
	mpv_command(m, cmd);
	int sz[2] = {480, 270}; size_t stride = 480 * 4;
	unsigned char *buf = malloc(stride * 270);
	double t0 = now(), dur = atof(argv[2]);
	while (now() - t0 < dur) {
		pthread_mutex_lock(&mu);
		while (!pending) pthread_cond_wait(&cv, &mu);
		pending = 0;
		pthread_mutex_unlock(&mu);
		while (mpv_wait_event(m, 0)->event_id != MPV_EVENT_NONE) ;
		if (!(mpv_render_context_update(rc) & MPV_RENDER_UPDATE_FRAME)) continue;
		mpv_render_param r[] = {{MPV_RENDER_PARAM_SW_SIZE, sz}, {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
			{MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, buf}, {0}};
		mpv_render_context_render(rc, r);
		double t = now();
		mpv_render_context_report_swap(rc);
		int n = 0; /* barcode: blocks are 6 px at 1/4 scale, sample at the centre */
		for (int b = 0; b < 16; b++) if (buf[3 * stride + (b * 6 + 3) * 4 + 1] > 128) n |= 1 << b;
		printf("%.6f %d\n", t - t0, n);
	}
	int64_t drops = 0, delayed = 0;
	mpv_get_property(m, "frame-drop-count", MPV_FORMAT_INT64, &drops);
	mpv_get_property(m, "vo-delayed-frame-count", MPV_FORMAT_INT64, &delayed);
	fprintf(stderr, "frame-drop-count %ld vo-delayed-frame-count %ld\n", (long)drops, (long)delayed);
	mpv_render_context_free(rc);
	mpv_terminate_destroy(m);
	return 0;
}
