/* vkeys.c - TEST TOOL (U23, from U19's altkeys.c): presses and releases named keys on a virtual keyboard of the compositor,
 * with the modifier state a real keyboard would report (Super = Mod4, Alt = Mod1, Shift), so Super+F12 is typed through
 * Wayland and goes through labwc's keybinds.
 * stdin: "down NAME", "up NAME", "tap NAME", "sleep MS". NAME: Super Alt Shift F12 a b Return Esc.
 * Prints "ok" after each command. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *kmgr;
static void g_add(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v)
{
	(void)d; (void)v;
	if (!strcmp(i, "wl_seat") && !seat) seat = wl_registry_bind(r, n, &wl_seat_interface, 1);
	else if (!strcmp(i, "zwp_virtual_keyboard_manager_v1")) kmgr = wl_registry_bind(r, n, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void g_del(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener gl = { g_add, g_del };
static uint32_t ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000); }

static int code_of(const char *n, uint32_t *mod)
{
	*mod = 0;
	if (!strcmp(n, "Super")) { *mod = 64; return KEY_LEFTMETA; }
	if (!strcmp(n, "F12")) return KEY_F12;
	if (!strcmp(n, "Alt")) { *mod = 8; return KEY_LEFTALT; }
	if (!strcmp(n, "Shift")) { *mod = 1; return KEY_LEFTSHIFT; }
	if (!strcmp(n, "Tab")) return KEY_TAB;
	if (!strcmp(n, "grave")) return KEY_GRAVE;
	if (!strcmp(n, "Left")) return KEY_LEFT;
	if (!strcmp(n, "Right")) return KEY_RIGHT;
	if (!strcmp(n, "Up")) return KEY_UP;
	if (!strcmp(n, "Down")) return KEY_DOWN;
	if (!strcmp(n, "Esc")) return KEY_ESC;
	if (!strcmp(n, "Return")) return KEY_ENTER;
	if (!strcmp(n, "w")) return KEY_W;
	if (!strcmp(n, "q")) return KEY_Q;
	if (!strcmp(n, "a")) return KEY_A;
	return -1;
}

int main(void)
{
	struct wl_display *d = wl_display_connect(NULL);
	if (!d) return 2;
	wl_registry_add_listener(wl_display_get_registry(d), &gl, NULL);
	wl_display_roundtrip(d);
	if (!seat || !kmgr) { fprintf(stderr, "altkeys: no virtual keyboard\n"); return 2; }
	struct xkb_context *xc = xkb_context_new(0);
	struct xkb_rule_names rn = { 0, 0, "us", 0, 0 };
	struct xkb_keymap *km = xkb_keymap_new_from_names(xc, &rn, 0);
	char *str = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
	size_t sz = strlen(str) + 1;
	int fd = memfd_create("km", 0);
	if (ftruncate(fd, (off_t)sz) < 0) return 2;
	memcpy(mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), str, sz);
	struct zwp_virtual_keyboard_v1 *vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(kmgr, seat);
	zwp_virtual_keyboard_v1_keymap(vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)sz);
	wl_display_roundtrip(d);
	uint32_t mods = 0;
	char line[128];
	while (fgets(line, sizeof line, stdin)) {
		line[strcspn(line, "\n")] = 0;
		char verb[16] = "", name[16] = "";
		int arg = 0;
		sscanf(line, "%15s %15s", verb, name);
		if (!strcmp(verb, "sleep")) { arg = atoi(name); wl_display_flush(d); usleep((useconds_t)arg * 1000); }
		else {
			uint32_t m; int c = code_of(name, &m);
			if (c < 0) { puts("bad"); fflush(stdout); continue; }
			int down = !strcmp(verb, "down") || !strcmp(verb, "tap");
			int up = !strcmp(verb, "up") || !strcmp(verb, "tap");
			if (down) {
				if (m) { mods |= m; zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)c, 1); zwp_virtual_keyboard_v1_modifiers(vk, mods, 0, 0, 0); }
				else zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)c, 1);
				wl_display_flush(d); usleep(20000);
			}
			if (up) {
				if (m) { mods &= ~m; zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)c, 0); zwp_virtual_keyboard_v1_modifiers(vk, mods, 0, 0, 0); }
				else zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)c, 0);
				wl_display_flush(d); usleep(20000);
			}
		}
		wl_display_roundtrip(d);
		puts("ok"); fflush(stdout);
	}
	return 0;
}
