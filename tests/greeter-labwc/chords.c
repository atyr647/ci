/* chords.c - TEST TOOL (tests/test-greeter-labwc.sh): types key chords on a virtual keyboard of the compositor, so
 * they go through labwc's keybinds like a real keyboard's. stdin: one chord per line, keysym names separated by
 * spaces ("Alt_L F4", "Super_L Return"): pressed in order, released in reverse, with the modifier state a real
 * keyboard reports (Shift, Control, Alt = Mod1, Super = Mod4). Prints "ok" after each chord, "bad NAME" for a name
 * the us keymap has no key for. (After tests/hud-native/vkeys.c, with any keysym instead of a fixed list.) */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
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

static struct xkb_keymap *km;
/* the evdev code of the key whose level-1 symbol is NAME, or -1; *mod gets its modifier bit */
static int code_of(const char *name, uint32_t *mod)
{
	xkb_keysym_t want = xkb_keysym_from_name(name, 0);
	*mod = 0;
	if (want == XKB_KEY_NoSymbol) return -1;
	if (want == XKB_KEY_Shift_L || want == XKB_KEY_Shift_R) *mod = 1;
	else if (want == XKB_KEY_Control_L || want == XKB_KEY_Control_R) *mod = 4;
	else if (want == XKB_KEY_Alt_L || want == XKB_KEY_Alt_R) *mod = 8;
	else if (want == XKB_KEY_Super_L || want == XKB_KEY_Super_R) *mod = 64;
	for (xkb_keycode_t k = xkb_keymap_min_keycode(km); k <= xkb_keymap_max_keycode(km); k++) {
		const xkb_keysym_t *syms;
		int n = xkb_keymap_key_get_syms_by_level(km, k, 0, 0, &syms);
		for (int i = 0; i < n; i++)
			if (syms[i] == want) return (int)k - 8;
	}
	return -1;
}

int main(void)
{
	struct wl_display *d = wl_display_connect(NULL);
	if (!d) return 2;
	wl_registry_add_listener(wl_display_get_registry(d), &gl, NULL);
	wl_display_roundtrip(d);
	if (!seat || !kmgr) { fprintf(stderr, "chords: no virtual keyboard\n"); return 2; }
	struct xkb_context *xc = xkb_context_new(0);
	struct xkb_rule_names rn = { 0, 0, "us", 0, 0 };
	km = xkb_keymap_new_from_names(xc, &rn, 0);
	if (!km) return 2;
	char *str = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
	size_t sz = strlen(str) + 1;
	int fd = memfd_create("km", 0);
	if (fd < 0 || ftruncate(fd, (off_t)sz) < 0) return 2;
	memcpy(mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), str, sz);
	struct zwp_virtual_keyboard_v1 *vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(kmgr, seat);
	zwp_virtual_keyboard_v1_keymap(vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)sz);
	wl_display_roundtrip(d);
	char line[256];
	while (fgets(line, sizeof line, stdin)) {
		int codes[8], n = 0, bad = 0;
		uint32_t mods[8], all = 0;
		for (char *t = strtok(line, " \t\n"); t && n < 8; t = strtok(NULL, " \t\n")) {
			codes[n] = code_of(t, &mods[n]);
			if (codes[n] < 0) { printf("bad %s\n", t); bad = 1; break; }
			n++;
		}
		if (bad) { fflush(stdout); continue; }
		for (int i = 0; i < n; i++) {
			zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)codes[i], 1);
			if (mods[i]) { all |= mods[i]; zwp_virtual_keyboard_v1_modifiers(vk, all, 0, 0, 0); }
			wl_display_flush(d); usleep(30000);
		}
		for (int i = n - 1; i >= 0; i--) {
			zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)codes[i], 0);
			if (mods[i]) { all &= ~mods[i]; zwp_virtual_keyboard_v1_modifiers(vk, all, 0, 0, 0); }
			wl_display_flush(d); usleep(30000);
		}
		wl_display_roundtrip(d);
		puts("ok"); fflush(stdout);
	}
	return 0;
}
