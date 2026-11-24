/* wlgame.c - TEST TOOL (U23): a fullscreen Wayland "game" that reports its input.
 *   wlgame RRGGBB|bars [APP_ID [TITLE]]   solid colour, or vertical stripes 40 px wide; xdg-toplevel, fullscreen;
 *                                         APP_ID (default wlgame) is what a game's window carries, e.g. steam_app_620
 * Prints "mapped" after the first frame, then one line per event it receives:
 *   ptr-enter X Y, ptr-leave, click X Y (button press), kbd-enter, kbd-leave, key CODE
 * The HUD must take none of these from the game: clicks over the HUD arrive here, the keyboard stays here. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *comp; static struct wl_shm *shm; static struct xdg_wm_base *wm; static struct wl_seat *seat;
static struct wl_surface *surf; static uint32_t colour; static int done, bar; static int px, py;

static void paint(uint32_t w, uint32_t h)
{
	size_t sz = (size_t)w * h * 4;
	int fd = memfd_create("c", 0);
	if (fd < 0 || ftruncate(fd, (off_t)sz) < 0) exit(2);
	uint32_t *p = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	/* "bars": vertical stripes 40 px wide, so a see-through HUD shows a different colour behind each part */
	static const uint32_t bars[4] = { 0xc0392b, 0x27ae60, 0x2980b9, 0xf1c40f };
	for (size_t i = 0; i < (size_t)w * h; i++) p[i] = 0xff000000u | (bar ? bars[(i % w / 40) % 4] : colour);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)sz);
	struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, (int)w, (int)h, (int)w * 4, WL_SHM_FORMAT_XRGB8888);
	wl_surface_attach(surf, b, 0, 0); wl_surface_damage(surf, 0, 0, (int)w, (int)h); wl_surface_commit(surf);
	if (!done) { done = 1; puts("mapped"); fflush(stdout); }
}
static int cw = 1280, ch = 720;
static void x_conf(void *d, struct xdg_surface *x, uint32_t s) { (void)d; xdg_surface_ack_configure(x, s); paint((uint32_t)cw, (uint32_t)ch); }
static const struct xdg_surface_listener xsl = { x_conf };
static void t_conf(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) { (void)d; (void)t; (void)s; if (w > 0) cw = w; if (h > 0) ch = h; }
static void t_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; exit(0); }
static const struct xdg_toplevel_listener tl = { t_conf, t_close, NULL, NULL };
static void p_ping(void *d, struct xdg_wm_base *w, uint32_t s) { (void)d; xdg_wm_base_pong(w, s); }
static const struct xdg_wm_base_listener pl = { p_ping };

static void po_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *f, wl_fixed_t x, wl_fixed_t y)
{ (void)d; (void)p; (void)s; (void)f; px = wl_fixed_to_int(x); py = wl_fixed_to_int(y); printf("ptr-enter %d %d\n", px, py); fflush(stdout); }
static void po_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *f) { (void)d; (void)p; (void)s; (void)f; puts("ptr-leave"); fflush(stdout); }
static void po_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) { (void)d; (void)p; (void)t; px = wl_fixed_to_int(x); py = wl_fixed_to_int(y); }
static void po_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t st)
{ (void)d; (void)p; (void)s; (void)t; (void)b; if (st == WL_POINTER_BUTTON_STATE_PRESSED) { printf("click %d %d\n", px, py); fflush(stdout); } }
static void po_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) { (void)d; (void)p; (void)t; (void)a; (void)v; }
static const struct wl_pointer_listener pol = { .enter = po_enter, .leave = po_leave, .motion = po_motion, .button = po_button, .axis = po_axis };
static void k_keymap(void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t sz) { (void)d; (void)k; (void)f; (void)sz; close(fd); }
static void k_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *f, struct wl_array *a) { (void)d; (void)k; (void)s; (void)f; (void)a; puts("kbd-enter"); fflush(stdout); }
static void k_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *f) { (void)d; (void)k; (void)s; (void)f; puts("kbd-leave"); fflush(stdout); }
static void k_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t st)
{ (void)d; (void)k; (void)s; (void)t; if (st == WL_KEYBOARD_KEY_STATE_PRESSED) { printf("key %u\n", key); fflush(stdout); } }
static void k_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g) { (void)d; (void)k; (void)s; (void)a; (void)b; (void)c; (void)g; }
static const struct wl_keyboard_listener kl = { .keymap = k_keymap, .enter = k_enter, .leave = k_leave, .key = k_key, .modifiers = k_mods };
static void s_caps(void *d, struct wl_seat *s, uint32_t c)
{
	(void)d;
	if (c & WL_SEAT_CAPABILITY_POINTER) wl_pointer_add_listener(wl_seat_get_pointer(s), &pol, NULL);
	if (c & WL_SEAT_CAPABILITY_KEYBOARD) wl_keyboard_add_listener(wl_seat_get_keyboard(s), &kl, NULL);
}
static void s_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener sl = { s_caps, s_name };
static void g_add(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v)
{
	(void)d; (void)v;
	if (!strcmp(i, "wl_compositor")) comp = wl_registry_bind(r, n, &wl_compositor_interface, 4);
	else if (!strcmp(i, "wl_shm")) shm = wl_registry_bind(r, n, &wl_shm_interface, 1);
	else if (!strcmp(i, "wl_seat") && !seat) { seat = wl_registry_bind(r, n, &wl_seat_interface, 1); wl_seat_add_listener(seat, &sl, NULL); }
	else if (!strcmp(i, "xdg_wm_base")) { wm = wl_registry_bind(r, n, &xdg_wm_base_interface, 1); xdg_wm_base_add_listener(wm, &pl, NULL); }
}
static void g_del(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener gl = { g_add, g_del };

int main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "bars")) bar = 1;
	colour = argc > 1 && !bar ? (uint32_t)strtoul(argv[1], NULL, 16) : 0x1a3a5c;
	struct wl_display *d = wl_display_connect(NULL);
	if (!d) return 2;
	wl_registry_add_listener(wl_display_get_registry(d), &gl, NULL);
	wl_display_roundtrip(d);
	surf = wl_compositor_create_surface(comp);
	struct xdg_surface *x = xdg_wm_base_get_xdg_surface(wm, surf);
	xdg_surface_add_listener(x, &xsl, NULL);
	struct xdg_toplevel *t = xdg_surface_get_toplevel(x);
	xdg_toplevel_add_listener(t, &tl, NULL);
	xdg_toplevel_set_app_id(t, argc > 2 ? argv[2] : "wlgame"); xdg_toplevel_set_title(t, argc > 3 ? argv[3] : "Game");
	xdg_toplevel_set_fullscreen(t, NULL);
	wl_surface_commit(surf);
	while (wl_display_dispatch(d) >= 0) ;
	return 0;
}
