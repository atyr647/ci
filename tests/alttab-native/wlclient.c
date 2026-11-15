/* wlclient.c - TEST TOOL (U19): a plain-colour Wayland client.
 *   wlclient bar RRGGBB H      layer-shell TOP strip, H tall, full width, anchored to the top, exclusive zone H
 *   wlclient over RRGGBB H     the same on the OVERLAY layer
 *   wlclient game RRGGBB       an xdg-toplevel, fullscreen (stands in for a Wayland-native game)
 * Prints "mapped" once its first frame is committed. Runs until killed. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *comp; static struct wl_shm *shm; static struct zwlr_layer_shell_v1 *ls; static struct xdg_wm_base *wm;
static struct wl_surface *surf; static uint32_t colour, strip; static int done;

static void paint(uint32_t w, uint32_t h)
{
	size_t sz = (size_t)w * h * 4;
	int fd = memfd_create("c", 0);
	if (fd < 0 || ftruncate(fd, (off_t)sz) < 0) exit(2);
	uint32_t *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	for (size_t i = 0; i < (size_t)w * h; i++) p[i] = 0xff000000u | colour;
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)sz);
	struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, (int)w, (int)h, (int)w * 4, WL_SHM_FORMAT_XRGB8888);
	wl_surface_attach(surf, b, 0, 0); wl_surface_damage(surf, 0, 0, (int)w, (int)h); wl_surface_commit(surf);
	if (!done) { done = 1; puts("mapped"); fflush(stdout); }
}
static void l_conf(void *d, struct zwlr_layer_surface_v1 *l, uint32_t s, uint32_t w, uint32_t h)
{ (void)d; zwlr_layer_surface_v1_ack_configure(l, s); paint(w ? w : 1280, h ? h : strip); }
static void l_closed(void *d, struct zwlr_layer_surface_v1 *l) { (void)d; (void)l; exit(0); }
static const struct zwlr_layer_surface_v1_listener lsl = { l_conf, l_closed };
static void x_conf(void *d, struct xdg_surface *x, uint32_t s) { (void)d; xdg_surface_ack_configure(x, s); paint(1280, 720); }
static const struct xdg_surface_listener xsl = { x_conf };
static void t_conf(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) { (void)d; (void)t; (void)w; (void)h; (void)s; }
static void t_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener tl = { t_conf, t_close, NULL, NULL };
static void p_ping(void *d, struct xdg_wm_base *w, uint32_t s) { (void)d; xdg_wm_base_pong(w, s); }
static const struct xdg_wm_base_listener pl = { p_ping };
static void g_add(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v)
{
	(void)d; (void)v;
	if (!strcmp(i, "wl_compositor")) comp = wl_registry_bind(r, n, &wl_compositor_interface, 4);
	else if (!strcmp(i, "wl_shm")) shm = wl_registry_bind(r, n, &wl_shm_interface, 1);
	else if (!strcmp(i, "zwlr_layer_shell_v1")) ls = wl_registry_bind(r, n, &zwlr_layer_shell_v1_interface, 1);
	else if (!strcmp(i, "xdg_wm_base")) { wm = wl_registry_bind(r, n, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm, &pl, NULL); }
}
static void g_del(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener gl = { g_add, g_del };

int main(int argc, char **argv)
{
	if (argc < 3) return 2;
	colour = (uint32_t)strtoul(argv[2], NULL, 16); strip = argc > 3 ? (uint32_t)atoi(argv[3]) : 38;
	struct wl_display *d = wl_display_connect(NULL);
	if (!d) return 2;
	wl_registry_add_listener(wl_display_get_registry(d), &gl, NULL);
	wl_display_roundtrip(d);
	surf = wl_compositor_create_surface(comp);
	if (!strcmp(argv[1], "game")) {
		struct xdg_surface *x = xdg_wm_base_get_xdg_surface(wm, surf);
		xdg_surface_add_listener(x, &xsl, NULL);
		struct xdg_toplevel *t = xdg_surface_get_toplevel(x);
		xdg_toplevel_add_listener(t, &tl, NULL);
		xdg_toplevel_set_app_id(t, "wlgame"); xdg_toplevel_set_title(t, "Game");
		xdg_toplevel_set_fullscreen(t, NULL);
	} else {
		struct zwlr_layer_surface_v1 *l = zwlr_layer_shell_v1_get_layer_surface(ls, surf, NULL,
			!strcmp(argv[1], "over") ? ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY : ZWLR_LAYER_SHELL_V1_LAYER_TOP, "wlclient");
		zwlr_layer_surface_v1_add_listener(l, &lsl, NULL);
		zwlr_layer_surface_v1_set_size(l, 0, strip);
		zwlr_layer_surface_v1_set_anchor(l, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
		zwlr_layer_surface_v1_set_exclusive_zone(l, (int)strip);
	}
	wl_surface_commit(surf);
	while (wl_display_dispatch(d) >= 0) ;
	return 0;
}
