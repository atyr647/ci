/* vkbd.c - TEST TOOL: types on a virtual keyboard and clicks on a virtual pointer of the compositor,
 * so keys really go through Wayland (xdotool's XTEST would bypass it and prove nothing).
 * stdin commands: "type TEXT", "key BackSpace|CtrlBackSpace|Return|Escape", "move X Y", "click", "keymap LAYOUT [VARIANT]" (a new
 * keymap for the keyboard, e.g. "keymap us intl" for dead keys), "sym KEYSYM" (the key, Shift if needed, that gives
 * that keysym, e.g. "sym dead_acute"). Prints "ok" after each. */
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
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *kmgr;
static struct zwlr_virtual_pointer_manager_v1 *pmgr;
static void g_add(void *d, struct wl_registry *r, uint32_t n, const char *i, uint32_t v)
{
	(void)d; (void)v;
	if (!strcmp(i, "wl_seat") && !seat) seat = wl_registry_bind(r, n, &wl_seat_interface, 1);
	else if (!strcmp(i, "zwp_virtual_keyboard_manager_v1")) kmgr = wl_registry_bind(r, n, &zwp_virtual_keyboard_manager_v1_interface, 1);
	else if (!strcmp(i, "zwlr_virtual_pointer_manager_v1")) pmgr = wl_registry_bind(r, n, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void g_del(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener gl = { g_add, g_del };

static struct xkb_context *xc;
static struct xkb_keymap *km;
static struct xkb_state *xs;
static int code[128], shift[128];

/* build the keymap LAYOUT(VARIANT), give it to the virtual keyboard, and map ASCII to (evdev code, shift) from it */
static void keymap(struct zwp_virtual_keyboard_v1 *vk, const char *layout, const char *variant)
{
	struct xkb_rule_names rn = { 0, 0, layout, variant && *variant ? variant : 0, 0 };
	struct xkb_keymap *nk = xkb_keymap_new_from_names(xc, &rn, 0);
	if (!nk) { fprintf(stderr, "vkbd: no keymap %s(%s)\n", layout, variant ? variant : ""); return; }
	if (xs) xkb_state_unref(xs);
	if (km) xkb_keymap_unref(km);
	km = nk; xs = xkb_state_new(km);
	char *str = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
	size_t sz = strlen(str) + 1;
	int fd = memfd_create("km", 0);
	if (ftruncate(fd, (off_t)sz) < 0) exit(2);
	char *m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	memcpy(m, str, sz); munmap(m, sz); free(str);
	zwp_virtual_keyboard_v1_keymap(vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)sz);
	close(fd);
	memset(code, 0, sizeof code); memset(shift, 0, sizeof shift);
	for (xkb_keycode_t k = xkb_keymap_min_keycode(km); k <= xkb_keymap_max_keycode(km); k++)
		for (int s = 0; s < 2; s++) {
			xkb_state_update_mask(xs, s ? 1 : 0, 0, 0, 0, 0, 0);
			char u[8];
			if (xkb_state_key_get_utf8(xs, k, u, sizeof u) == 1 && (unsigned char)u[0] > 0x20 && (unsigned char)u[0] < 0x7f && !code[(int)u[0]])
				{ code[(int)u[0]] = (int)k - 8; shift[(int)u[0]] = s; }
		}
	code[' '] = KEY_SPACE;
}

static uint32_t ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000); }

int main(void)
{
	struct wl_display *d = wl_display_connect(NULL);
	if (!d) return 2;
	wl_registry_add_listener(wl_display_get_registry(d), &gl, NULL);
	wl_display_roundtrip(d);
	if (!seat || !kmgr) { fprintf(stderr, "vkbd: no virtual keyboard\n"); return 2; }
	xc = xkb_context_new(0);
	struct zwp_virtual_keyboard_v1 *vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(kmgr, seat);
	keymap(vk, "us", NULL);
	struct zwlr_virtual_pointer_v1 *vp = pmgr ? zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pmgr, seat) : NULL;
	wl_display_roundtrip(d);


	char line[512];
	while (fgets(line, sizeof line, stdin)) {
		line[strcspn(line, "\n")] = 0;
		if (!strncmp(line, "type ", 5)) {
			for (char *c = line + 5; *c; c++) {
				if (!code[(int)*c]) continue;
				if (shift[(int)*c]) zwp_virtual_keyboard_v1_modifiers(vk, 1, 0, 0, 0);
				zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)code[(int)*c], 1);
				wl_display_flush(d); usleep(15000);
				zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)code[(int)*c], 0);
				if (shift[(int)*c]) zwp_virtual_keyboard_v1_modifiers(vk, 0, 0, 0, 0);
				wl_display_flush(d); usleep(15000);
			}
		} else if (!strncmp(line, "keymap ", 7)) {
			char lay[64] = "", var[64] = "";
			sscanf(line + 7, "%63s %63s", lay, var);
			keymap(vk, lay, var);
		} else if (!strncmp(line, "sym ", 4)) {
			xkb_keysym_t want = xkb_keysym_from_name(line + 4, XKB_KEYSYM_NO_FLAGS);
			int kc = 0, sh = 0;
			for (xkb_keycode_t k = xkb_keymap_min_keycode(km); k <= xkb_keymap_max_keycode(km) && !kc && want; k++)
				for (int s = 0; s < 2 && !kc; s++) {
					xkb_state_update_mask(xs, s ? 1 : 0, 0, 0, 0, 0, 0);
					if (xkb_state_key_get_one_sym(xs, k) == want) { kc = (int)k - 8; sh = s; }
				}
			if (!kc) fprintf(stderr, "vkbd: no key gives %s\n", line + 4);
			else {
				if (sh) zwp_virtual_keyboard_v1_modifiers(vk, 1, 0, 0, 0);
				zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)kc, 1); wl_display_flush(d); usleep(15000);
				zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)kc, 0);
				if (sh) zwp_virtual_keyboard_v1_modifiers(vk, 0, 0, 0, 0);
				wl_display_flush(d); usleep(15000);
			}
		} else if (!strncmp(line, "hold ", 5)) {   /* hold CHAR MS: press, wait, release (key repeat) */
			int ch = (unsigned char)line[5], hold = atoi(line + 7);
			if (code[ch]) {
				zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)code[ch], 1); wl_display_flush(d);
				usleep((useconds_t)hold * 1000);
				zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)code[ch], 0);
			}
		} else if (!strncmp(line, "key ", 4)) {
			const char *nm = line + 4;
			int sh = !strcmp(nm, "ShiftTab"), ct = !strcmp(nm, "CtrlBackSpace");
			int k = (ct || !strcmp(nm, "BackSpace")) ? KEY_BACKSPACE : !strcmp(nm, "Return") ? KEY_ENTER :
				(sh || !strcmp(nm, "Tab")) ? KEY_TAB : !strcmp(nm, "Up") ? KEY_UP : !strcmp(nm, "Down") ? KEY_DOWN : KEY_ESC;
			if (sh || ct) zwp_virtual_keyboard_v1_modifiers(vk, sh ? 1 : 4, 0, 0, 0); /* Shift, Control */
			zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)k, 1); wl_display_flush(d); usleep(15000);
			zwp_virtual_keyboard_v1_key(vk, ms(), (uint32_t)k, 0); wl_display_flush(d); usleep(15000);
			if (sh || ct) zwp_virtual_keyboard_v1_modifiers(vk, 0, 0, 0, 0);
		} else if (!strncmp(line, "move ", 5) && vp) {
			unsigned x, y; sscanf(line + 5, "%u %u", &x, &y);
			zwlr_virtual_pointer_v1_motion_absolute(vp, ms(), x, y, 1280, 720);
			zwlr_virtual_pointer_v1_frame(vp);
		} else if (!strcmp(line, "click") && vp) {
			zwlr_virtual_pointer_v1_button(vp, ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED); zwlr_virtual_pointer_v1_frame(vp);
			wl_display_flush(d); usleep(30000);
			zwlr_virtual_pointer_v1_button(vp, ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED); zwlr_virtual_pointer_v1_frame(vp);
		}
		wl_display_roundtrip(d);
		puts("ok"); fflush(stdout);
	}
	return 0;
}
