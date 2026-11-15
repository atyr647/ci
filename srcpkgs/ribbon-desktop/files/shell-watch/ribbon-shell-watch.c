/*
 * ribbon-shell-watch - the Ribbon shell's window to the compositor.
 *
 * The Ribbon shell is written in Tcl/Tk. Tcl can't speak Wayland (the
 * protocol runs over a Unix socket and passes file descriptors), so this
 * small helper does it and talks to the shell over plain text pipes.
 *
 * It follows the compositor's windows (wlr-foreign-toplevel-management) and
 * workspaces (ext-workspace-v1; labwc implements both) and prints:
 *
 *   T+ ID                 a new window
 *   T ID app APP_ID
 *   T ID title TITLE      (rest of the line; tabs/newlines become spaces)
 *   T ID state FLAGS      comma list of max,act,min,full, or -
 *   T ID mru N            the window was just activated; N orders windows
 *                         most-recently-used first (larger = more recent)
 *   T ID done             the window's details above are complete
 *   T- ID                 the window closed
 *   W+ ID                 a new workspace
 *   W ID name NAME
 *   W ID state active|-
 *   W- ID                 the workspace went away
 *   W done                workspace details are complete
 *   ready                 the initial lists have been sent
 *
 * and reads commands, one per line, on stdin:
 *
 *   activate ID | minimize ID | unminimize ID | close ID
 *   maximize ID | unmaximize ID | ws ID   (switch to workspace)
 *   key CHORD     press and release a key on a resident virtual keyboard
 *                 (zwp_virtual_keyboard_v1), e.g. A-1, C-A-S-W-F12. Modifier
 *                 prefixes: C ctrl, A alt, S shift, W logo (each followed by -).
 *                 The key is an xkb keysym name (F12, 1, Tab, Left, ...).
 *
 * Exits when the compositor or stdin goes away. Copyright 2026 Ribbon OS
 * contributors, MIT licence.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>
#include <linux/input-event-codes.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "ext-workspace-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"

struct toplevel {
	struct wl_list link;
	unsigned id;
	struct zwlr_foreign_toplevel_handle_v1 *handle;
	bool act;               /* activated as of the last state event */
	unsigned long mru;      /* activation serial, 0 until first activated */
};

struct workspace {
	struct wl_list link;
	unsigned id;
	struct ext_workspace_handle_v1 *handle;
};

static struct wl_list toplevels, workspaces;
static unsigned next_toplevel = 1, next_workspace = 1;
static unsigned long mru_serial;
static struct wl_seat *seat;
static struct zwlr_foreign_toplevel_manager_v1 *tl_manager;
static struct ext_workspace_manager_v1 *ws_manager;
static struct wl_display *display;
static struct zwp_virtual_keyboard_manager_v1 *vk_manager;
static struct zwp_virtual_keyboard_v1 *vk;
static struct xkb_keymap *vk_keymap;

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void out(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
	fflush(stdout);
}

static char *clean(const char *s)
{
	char *c = strdup(s ? s : "");
	for (char *p = c; c && *p; p++)
		if (*p == '\n' || *p == '\t' || *p == '\r')
			*p = ' ';
	return c;
}

/* ---- toplevels ---------------------------------------------------- */

static void tl_title(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, const char *title)
{
	(void)h;
	struct toplevel *t = data;
	char *c = clean(title);
	out("T %u title %s", t->id, c ? c : "");
	free(c);
}

static void tl_app_id(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, const char *app_id)
{
	(void)h;
	struct toplevel *t = data;
	char *c = clean(app_id);
	out("T %u app %s", t->id, c ? c : "");
	free(c);
}

static void tl_output_enter(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o)
{
	(void)data; (void)h; (void)o;
}

static void tl_output_leave(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_output *o)
{
	(void)data; (void)h; (void)o;
}

static void tl_state(void *data, struct zwlr_foreign_toplevel_handle_v1 *h, struct wl_array *state)
{
	(void)h;
	struct toplevel *t = data;
	char buf[64] = "";
	uint32_t *s;
	/* MAXIMIZED is 0 in the protocol enum, so compare explicitly. */
	wl_array_for_each(s, state) {
		const char *n = NULL;
		switch (*s) {
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED: n = "max"; break;
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED: n = "act"; break;
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED: n = "min"; break;
		case ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN: n = "full"; break;
		}
		if (n && strlen(buf) + strlen(n) + 2 < sizeof(buf)) {
			if (buf[0])
				strcat(buf, ",");
			strcat(buf, n);
		}
	}
	out("T %u state %s", t->id, buf[0] ? buf : "-");
	/* the MRU order is the order of activations, so a window that gains
	 * the activated state takes the next serial */
	bool now = false;
	wl_array_for_each(s, state)
		if (*s == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED)
			now = true;
	if (now && !t->act) {
		t->mru = ++mru_serial;
		out("T %u mru %lu", t->id, t->mru);
	}
	t->act = now;
}

static void tl_done(void *data, struct zwlr_foreign_toplevel_handle_v1 *h)
{
	(void)h;
	struct toplevel *t = data;
	out("T %u done", t->id);
}

static void tl_closed(void *data, struct zwlr_foreign_toplevel_handle_v1 *h)
{
	struct toplevel *t = data;
	out("T- %u", t->id);
	wl_list_remove(&t->link);
	zwlr_foreign_toplevel_handle_v1_destroy(h);
	free(t);
}

static void tl_parent(void *data, struct zwlr_foreign_toplevel_handle_v1 *h,
	struct zwlr_foreign_toplevel_handle_v1 *parent)
{
	(void)data; (void)h; (void)parent;
}

static const struct zwlr_foreign_toplevel_handle_v1_listener tl_listener = {
	.title = tl_title,
	.app_id = tl_app_id,
	.output_enter = tl_output_enter,
	.output_leave = tl_output_leave,
	.state = tl_state,
	.done = tl_done,
	.closed = tl_closed,
	.parent = tl_parent,
};

static void tlm_toplevel(void *data, struct zwlr_foreign_toplevel_manager_v1 *m,
	struct zwlr_foreign_toplevel_handle_v1 *handle)
{
	(void)data; (void)m;
	struct toplevel *t = calloc(1, sizeof(*t));
	if (!t)
		return;
	t->id = next_toplevel++;
	t->handle = handle;
	wl_list_insert(toplevels.prev, &t->link);
	out("T+ %u", t->id);
	zwlr_foreign_toplevel_handle_v1_add_listener(handle, &tl_listener, t);
}

static void tlm_finished(void *data, struct zwlr_foreign_toplevel_manager_v1 *m)
{
	(void)data; (void)m;
	exit(0);
}

static const struct zwlr_foreign_toplevel_manager_v1_listener tlm_listener = {
	.toplevel = tlm_toplevel,
	.finished = tlm_finished,
};

/* ---- workspaces --------------------------------------------------- */

static void ws_id(void *data, struct ext_workspace_handle_v1 *h, const char *id)
{
	(void)data; (void)h; (void)id;
}

static void ws_name(void *data, struct ext_workspace_handle_v1 *h, const char *name)
{
	(void)h;
	struct workspace *w = data;
	char *c = clean(name);
	out("W %u name %s", w->id, c ? c : "");
	free(c);
}

static void ws_coordinates(void *data, struct ext_workspace_handle_v1 *h, struct wl_array *coords)
{
	(void)data; (void)h; (void)coords;
}

static void ws_state(void *data, struct ext_workspace_handle_v1 *h, uint32_t state)
{
	(void)h;
	struct workspace *w = data;
	out("W %u state %s", w->id, (state & EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE) ? "active" : "-");
}

static void ws_capabilities(void *data, struct ext_workspace_handle_v1 *h, uint32_t caps)
{
	(void)data; (void)h; (void)caps;
}

static void ws_removed(void *data, struct ext_workspace_handle_v1 *h)
{
	struct workspace *w = data;
	out("W- %u", w->id);
	wl_list_remove(&w->link);
	ext_workspace_handle_v1_destroy(h);
	free(w);
}

static const struct ext_workspace_handle_v1_listener ws_listener = {
	.id = ws_id,
	.name = ws_name,
	.coordinates = ws_coordinates,
	.state = ws_state,
	.capabilities = ws_capabilities,
	.removed = ws_removed,
};

static void wsg_capabilities(void *d, struct ext_workspace_group_handle_v1 *g, uint32_t c)
{
	(void)d; (void)g; (void)c;
}
static void wsg_output_enter(void *d, struct ext_workspace_group_handle_v1 *g, struct wl_output *o)
{
	(void)d; (void)g; (void)o;
}
static void wsg_output_leave(void *d, struct ext_workspace_group_handle_v1 *g, struct wl_output *o)
{
	(void)d; (void)g; (void)o;
}
static void wsg_workspace_enter(void *d, struct ext_workspace_group_handle_v1 *g, struct ext_workspace_handle_v1 *w)
{
	(void)d; (void)g; (void)w;
}
static void wsg_workspace_leave(void *d, struct ext_workspace_group_handle_v1 *g, struct ext_workspace_handle_v1 *w)
{
	(void)d; (void)g; (void)w;
}
static void wsg_removed(void *d, struct ext_workspace_group_handle_v1 *g)
{
	(void)d;
	ext_workspace_group_handle_v1_destroy(g);
}

static const struct ext_workspace_group_handle_v1_listener wsg_listener = {
	.capabilities = wsg_capabilities,
	.output_enter = wsg_output_enter,
	.output_leave = wsg_output_leave,
	.workspace_enter = wsg_workspace_enter,
	.workspace_leave = wsg_workspace_leave,
	.removed = wsg_removed,
};

static void wsm_workspace_group(void *data, struct ext_workspace_manager_v1 *m,
	struct ext_workspace_group_handle_v1 *g)
{
	(void)data; (void)m;
	ext_workspace_group_handle_v1_add_listener(g, &wsg_listener, NULL);
}

static void wsm_workspace(void *data, struct ext_workspace_manager_v1 *m,
	struct ext_workspace_handle_v1 *handle)
{
	(void)data; (void)m;
	struct workspace *w = calloc(1, sizeof(*w));
	if (!w)
		return;
	w->id = next_workspace++;
	w->handle = handle;
	wl_list_insert(workspaces.prev, &w->link);
	out("W+ %u", w->id);
	ext_workspace_handle_v1_add_listener(handle, &ws_listener, w);
}

static void wsm_done(void *data, struct ext_workspace_manager_v1 *m)
{
	(void)data; (void)m;
	out("W done");
}

static void wsm_finished(void *data, struct ext_workspace_manager_v1 *m)
{
	(void)data;
	ext_workspace_manager_v1_destroy(m);
	ws_manager = NULL;
}

static const struct ext_workspace_manager_v1_listener wsm_listener = {
	.workspace_group = wsm_workspace_group,
	.workspace = wsm_workspace,
	.done = wsm_done,
	.finished = wsm_finished,
};

/* ---- registry ----------------------------------------------------- */

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
	const char *iface, uint32_t version)
{
	(void)data;
	if (strcmp(iface, zwlr_foreign_toplevel_manager_v1_interface.name) == 0) {
		uint32_t v = version < 3 ? version : 3;
		tl_manager = wl_registry_bind(reg, name, &zwlr_foreign_toplevel_manager_v1_interface, v);
		zwlr_foreign_toplevel_manager_v1_add_listener(tl_manager, &tlm_listener, NULL);
	} else if (strcmp(iface, ext_workspace_manager_v1_interface.name) == 0) {
		ws_manager = wl_registry_bind(reg, name, &ext_workspace_manager_v1_interface, 1);
		ext_workspace_manager_v1_add_listener(ws_manager, &wsm_listener, NULL);
	} else if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
		vk_manager = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
	} else if (strcmp(iface, wl_seat_interface.name) == 0 && !seat) {
		seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
	}
}

static void registry_remove(void *data, struct wl_registry *reg, uint32_t name)
{
	(void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_remove,
};

/* ---- commands ----------------------------------------------------- */

static struct toplevel *find_toplevel(unsigned id)
{
	struct toplevel *t;
	wl_list_for_each(t, &toplevels, link)
		if (t->id == id)
			return t;
	return NULL;
}

static struct workspace *find_workspace(unsigned id)
{
	struct workspace *w;
	wl_list_for_each(w, &workspaces, link)
		if (w->id == id)
			return w;
	return NULL;
}

/* ---- virtual keyboard (the `key` command) -------------------------- */

static uint32_t now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

/* Made on first use, then kept: the keymap is sent once. */
static bool vk_init(void)
{
	if (vk)
		return true;
	if (!vk_manager || !seat)
		return false;
	struct xkb_context *xc = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_rule_names rn = { .layout = "us" };
	vk_keymap = xc ? xkb_keymap_new_from_names(xc, &rn, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
	char *str = vk_keymap ? xkb_keymap_get_as_string(vk_keymap, XKB_KEYMAP_FORMAT_TEXT_V1) : NULL;
	if (!str)
		return false;
	size_t sz = strlen(str) + 1;
	int fd = memfd_create("ribbon-vk", 0);
	if (fd < 0 || ftruncate(fd, (off_t)sz) < 0)
		return false;
	void *m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED)
		return false;
	memcpy(m, str, sz);
	munmap(m, sz);
	free(str);
	vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vk_manager, seat);
	zwp_virtual_keyboard_v1_keymap(vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)sz);
	close(fd);
	return true;
}

static xkb_keysym_t want_sym;
static xkb_keycode_t found_key;
static void find_key(struct xkb_keymap *km, xkb_keycode_t k, void *d)
{
	(void)d;
	const xkb_keysym_t *syms;
	if (!found_key && xkb_keymap_key_get_syms_by_level(km, k, 0, 0, &syms) == 1 && syms[0] == want_sym)
		found_key = k;
}

/* CHORD: modifier letters each followed by '-', then a keysym name. */
static void press_chord(const char *chord)
{
	static const struct { char c; uint32_t mask; int code; } mods[] = {
		{ 'C', 4, KEY_LEFTCTRL }, { 'A', 8, KEY_LEFTALT }, { 'S', 1, KEY_LEFTSHIFT }, { 'W', 0x40, KEY_LEFTMETA },
	};
	uint32_t mask = 0;
	int held[4], nheld = 0;
	while (chord[0] && chord[1] == '-' && chord[2]) {
		for (unsigned i = 0; i < 4; i++)
			if (mods[i].c == chord[0]) {
				mask |= mods[i].mask;
				held[nheld++] = mods[i].code;
			}
		chord += 2;
	}
	if (!vk_init())
		return;
	want_sym = xkb_keysym_from_name(chord, XKB_KEYSYM_CASE_INSENSITIVE);
	found_key = 0;
	if (want_sym != XKB_KEY_NoSymbol)
		xkb_keymap_key_for_each(vk_keymap, find_key, NULL);
	if (!found_key)
		return;
	uint32_t code = found_key - 8;
	for (int i = 0; i < nheld; i++)
		zwp_virtual_keyboard_v1_key(vk, now_ms(), (uint32_t)held[i], 1);
	zwp_virtual_keyboard_v1_modifiers(vk, mask, 0, 0, 0);
	zwp_virtual_keyboard_v1_key(vk, now_ms(), code, 1);
	zwp_virtual_keyboard_v1_key(vk, now_ms(), code, 0);
	for (int i = nheld - 1; i >= 0; i--)
		zwp_virtual_keyboard_v1_key(vk, now_ms(), (uint32_t)held[i], 0);
	zwp_virtual_keyboard_v1_modifiers(vk, 0, 0, 0, 0);
	wl_display_flush(display);
}

static void command(char *line)
{
	char verb[32];
	unsigned id;
	if (strncmp(line, "key ", 4) == 0) {
		char chord[64];
		if (sscanf(line + 4, "%63s", chord) == 1)
			press_chord(chord);
		return;
	}
	if (sscanf(line, "%31s %u", verb, &id) != 2)
		return;
	if (strcmp(verb, "ws") == 0) {
		struct workspace *w = find_workspace(id);
		if (w && ws_manager) {
			ext_workspace_handle_v1_activate(w->handle);
			ext_workspace_manager_v1_commit(ws_manager);
		}
		return;
	}
	struct toplevel *t = find_toplevel(id);
	if (!t)
		return;
	if (strcmp(verb, "activate") == 0 && seat)
		zwlr_foreign_toplevel_handle_v1_activate(t->handle, seat);
	else if (strcmp(verb, "minimize") == 0)
		zwlr_foreign_toplevel_handle_v1_set_minimized(t->handle);
	else if (strcmp(verb, "unminimize") == 0)
		zwlr_foreign_toplevel_handle_v1_unset_minimized(t->handle);
	else if (strcmp(verb, "maximize") == 0)
		zwlr_foreign_toplevel_handle_v1_set_maximized(t->handle);
	else if (strcmp(verb, "unmaximize") == 0)
		zwlr_foreign_toplevel_handle_v1_unset_maximized(t->handle);
	else if (strcmp(verb, "close") == 0)
		zwlr_foreign_toplevel_handle_v1_close(t->handle);
}

static void read_commands(void)
{
	static char buf[4096];
	static size_t len;
	ssize_t n = read(STDIN_FILENO, buf + len, sizeof(buf) - 1 - len);
	if (n <= 0)
		exit(0);
	len += (size_t)n;
	buf[len] = '\0';
	char *start = buf, *nl;
	while ((nl = strchr(start, '\n'))) {
		*nl = '\0';
		command(start);
		start = nl + 1;
	}
	len = strlen(start);
	memmove(buf, start, len + 1);
	if (len >= sizeof(buf) - 1)
		len = 0;
}

int main(int argc, char **argv)
{
	(void)argv;
	if (argc > 1) {
		fprintf(stderr, "usage: ribbon-shell-watch (talks to the Ribbon shell over stdin/stdout)\n");
		return 2;
	}
	wl_list_init(&toplevels);
	wl_list_init(&workspaces);
	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "ribbon-shell-watch: no Wayland display\n");
		return 1;
	}
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	wl_display_roundtrip(display);
	if (!tl_manager) {
		fprintf(stderr, "ribbon-shell-watch: compositor lacks wlr-foreign-toplevel-management\n");
		return 1;
	}
	wl_display_roundtrip(display);
	wl_display_roundtrip(display);
	out("ready");

	struct pollfd fds[2] = {
		{ .fd = wl_display_get_fd(display), .events = POLLIN },
		{ .fd = STDIN_FILENO, .events = POLLIN },
	};
	for (;;) {
		while (wl_display_prepare_read(display) != 0)
			wl_display_dispatch_pending(display);
		wl_display_flush(display);
		if (poll(fds, 2, -1) < 0) {
			wl_display_cancel_read(display);
			if (errno == EINTR)
				continue;
			return 1;
		}
		if (fds[0].revents & POLLIN) {
			if (wl_display_read_events(display) < 0)
				return 0;
		} else {
			wl_display_cancel_read(display);
		}
		if (fds[0].revents & (POLLERR | POLLHUP))
			return 0;
		wl_display_dispatch_pending(display);
		if (fds[1].revents & (POLLIN | POLLHUP))
			read_commands();
		wl_display_flush(display);
	}
}
