/* gstloop FILE SECONDS MODE : loop FILE with GStreamer, logging each frame's
 * arrival at a clock-synced appsink and its barcode index.
 *   MODE flush   : on EOS, a flushing seek back to 0 (what simple players do)
 *   MODE segment : segment seeks; on SEGMENT_DONE a non-flushing seek to 0 */
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <stdio.h>
#include <string.h>
static GstElement *pipe;
static int segment;
static gint64 t0;
static GstFlowReturn on_sample(GstAppSink *s, gpointer u) {
	(void)u;
	GstSample *sm = gst_app_sink_pull_sample(s);
	GstBuffer *b = gst_sample_get_buffer(sm);
	GstMapInfo mi; gst_buffer_map(b, &mi, GST_MAP_READ);
	int n = 0;
	for (int k = 0; k < 16; k++) if (mi.data[3 * 480 + k * 6 + 3] > 128) n |= 1 << k;
	gst_buffer_unmap(b, &mi);
	printf("%.6f %d\n", (g_get_monotonic_time() - t0) / 1e6, n);
	gst_sample_unref(sm);
	return GST_FLOW_OK;
}
static gboolean on_bus(GstBus *bus, GstMessage *m, gpointer loop) {
	(void)bus;
	switch (GST_MESSAGE_TYPE(m)) {
	case GST_MESSAGE_SEGMENT_DONE:
		gst_element_seek(pipe, 1.0, GST_FORMAT_TIME, GST_SEEK_FLAG_SEGMENT, GST_SEEK_TYPE_SET, 0, GST_SEEK_TYPE_NONE, -1);
		break;
	case GST_MESSAGE_EOS:
		gst_element_seek_simple(pipe, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH, 0);
		break;
	case GST_MESSAGE_ASYNC_DONE:
		if (segment == 1) { segment = 2;
			gst_element_seek(pipe, 1.0, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_SEGMENT, GST_SEEK_TYPE_SET, 0, GST_SEEK_TYPE_NONE, -1); }
		break;
	case GST_MESSAGE_ERROR: { GError *e; gst_message_parse_error(m, &e, NULL); fprintf(stderr, "%s\n", e->message); g_main_loop_quit(loop); break; }
	default: break;
	}
	return TRUE;
}
static gboolean stop(gpointer loop) { g_main_loop_quit(loop); return FALSE; }
int main(int argc, char **argv) {
	gst_init(&argc, &argv);
	segment = !strcmp(argv[3], "segment");
	char d[1024];
	snprintf(d, sizeof d, "filesrc location=%s ! decodebin ! videoconvert ! videoscale ! video/x-raw,format=GRAY8,width=480,height=270 ! appsink name=s sync=true emit-signals=true", argv[1]);
	pipe = gst_parse_launch(d, NULL);
	GstElement *s = gst_bin_get_by_name(GST_BIN(pipe), "s");
	g_signal_connect(s, "new-sample", G_CALLBACK(on_sample), NULL);
	GMainLoop *loop = g_main_loop_new(NULL, FALSE);
	gst_bus_add_watch(gst_element_get_bus(pipe), on_bus, loop);
	t0 = g_get_monotonic_time();
	gst_element_set_state(pipe, GST_STATE_PLAYING);
	g_timeout_add(atoi(argv[2]) * 1000, stop, loop);
	g_main_loop_run(loop);
	gst_element_set_state(pipe, GST_STATE_NULL);
	return 0;
}
