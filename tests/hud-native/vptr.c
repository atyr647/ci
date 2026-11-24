/* vptr.c - TEST TOOL (U23): a virtual pointer through Wayland (wlr-virtual-pointer), so clicks really go through the
 * compositor's hit test. stdin: "size W H" (the output, default 1280 720), "move X Y", "click". Prints "ok" after each. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *seat; static struct zwlr_virtual_pointer_manager_v1 *pmgr;
static void g_add(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v)
{
	(void)d; (void)v;
	if (!strcmp(i, "wl_seat") && !seat) seat = wl_registry_bind(r, n, &wl_seat_interface, 1);
	else if (!strcmp(i, "zwlr_virtual_pointer_manager_v1")) pmgr = wl_registry_bind(r, n, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void g_del(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener gl = { g_add, g_del };
static uint32_t ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000); }

int main(void)
{
	struct wl_display *d = wl_display_connect(NULL);
	if (!d) return 2;
	wl_registry_add_listener(wl_display_get_registry(d), &gl, NULL);
	wl_display_roundtrip(d);
	if (!seat || !pmgr) { fprintf(stderr, "vptr: no virtual pointer\n"); return 2; }
	struct zwlr_virtual_pointer_v1 *vp = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pmgr, seat);
	unsigned W = 1280, H = 720;
	char line[256];
	while (fgets(line, sizeof line, stdin)) {
		if (!strncmp(line, "size ", 5)) sscanf(line + 5, "%u %u", &W, &H);
		else if (!strncmp(line, "move ", 5)) {
			unsigned x, y; sscanf(line + 5, "%u %u", &x, &y);
			zwlr_virtual_pointer_v1_motion_absolute(vp, ms(), x, y, W, H);
			zwlr_virtual_pointer_v1_frame(vp);
		} else if (!strncmp(line, "click", 5)) {
			zwlr_virtual_pointer_v1_button(vp, ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED); zwlr_virtual_pointer_v1_frame(vp);
			wl_display_flush(d); usleep(30000);
			zwlr_virtual_pointer_v1_button(vp, ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED); zwlr_virtual_pointer_v1_frame(vp);
		}
		wl_display_roundtrip(d);
		puts("ok"); fflush(stdout);
	}
	return 0;
}
