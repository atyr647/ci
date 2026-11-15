/* rpk-keys.c - ribbon-polkit-keys: the password prompt's keyboard, as a native Wayland client.
 *
 * The card stays Tk (docs/POLKIT-WAYLAND.md, option 1). This process owns the keyboard
 * while the prompt is up: a 1x1 transparent layer-shell surface on the overlay layer with
 * exclusive keyboard interactivity and an empty input region. The compositor then sends every
 * key to this process and to no other client, XWayland included, so no X11 client can read
 * the password with XInput2 raw events, XQueryKeymap or RECORD.
 *
 * The password never reaches the agent's Tcl: it goes from here to a descriptor the agent
 * passed (SCM_RIGHTS), which is the write end of the pipe that is polkit-agent-helper-1's stdin.
 *
 * Two ways to run it:
 *   --socket      (the agent): fd 0 is a connected AF_UNIX stream socket. Events go out on it, commands
 *                 come in on it, and the secret's descriptor arrives on it with the command "secret".
 *   (default)     (the tests): commands on stdin, events on stdout, the secret to --secret-fd (3).
 *
 * Events, one line each. Never a character, except "t" in echo mode (a prompt PAM marked as not secret):
 *     ready      keyboard focus is ours (do not show the field before this)
 *     lost       focus left us, or the surface was closed: keys are NOT safe
 *     n COUNT    characters typed so far (the card draws that many dots)
 *     t TEXT     echo mode only: the text typed so far
 *     enter esc tab btab up down   the key; Return does NOT write the secret, the card decides what it means
 *     space      nav mode only (in the other modes a space is a character)
 * Commands:
 *     mode text|echo|nav   text: characters are collected hidden (default); echo: collected and shown with "t";
 *                          nav: no collecting, Space is an event (focus is not in the field)
 *     submit     write the collected text and a newline to the secret descriptor, then wipe
 *     clear      empty the buffer
 *     secret     (with a descriptor) the pipe to write the next answer to; replaces the last one
 *     quit
 *
 * Characters go through the session's Compose table (xkbcommon-compose: XCOMPOSEFILE, ~/.XCompose, or the
 * locale's), so dead keys and Multi_key sequences type what they type everywhere else: dead_acute then e is one
 * character, "é". A dead key alone adds nothing (no dot) until its sequence ends; a key that ends no sequence
 * cancels it and is dropped with it, as X11's own compose does. Backspace, Escape, Return, Tab, Ctrl+U, a mode
 * change, clear and submit all forget a half-typed sequence.
 *
 * cc -O2 -Wall -Wextra -Werror ... -lwayland-client -lxkbcommon
 * Copyright 2026 Ribbon OS contributors, MIT licence. */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/timerfd.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-compose.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#define MAXPW 512

static struct wl_display *dpy;
static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct zwlr_layer_shell_v1 *lshell;
static struct wl_surface *surf;
static struct zwlr_layer_surface_v1 *ls;
static struct wl_keyboard *kbd;
static struct xkb_context *xctx;
static struct xkb_keymap *xmap;
static struct xkb_state *xst;
static struct xkb_compose_table *ctab;
static struct xkb_compose_state *cst;   /* NULL: no Compose table for this locale, keys are taken as they come */
static int secret_fd = 3, tfd = -1, sockmode, evfd = 1, mode; /* mode: 0 text, 1 echo, 2 nav */
static int have_focus, configured, quit_now;
static char pw[MAXPW + 1];
static size_t pwlen;
static int pwcount;
static int rep_delay = 400, rep_rate = 25; /* ms, per second */
static uint32_t rep_key;                   /* evdev code being repeated, 0: none */

static void out(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void out(const char *fmt, ...)
{
	char b[MAXPW * 2 + 32];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(b, sizeof b, fmt, ap);
	va_end(ap);
	if (n < 0 || (size_t)n >= sizeof b) return;
	if (write(evfd, b, (size_t)n) < 0 && errno != EINTR) quit_now = 1; /* the card is gone: so are we */
}

static void compose_reset(void) { if (cst) xkb_compose_state_reset(cst); }
static void wipe(void) { explicit_bzero(pw, sizeof pw); pwlen = 0; pwcount = 0; compose_reset(); }

/* the card learns the count, and in echo mode the text (a prompt PAM says is not secret) */
static void changed(void)
{
	out("n %d\n", pwcount);
	if (mode == 1) out("t %s\n", pw);
}
static void clear_all(void) { wipe(); changed(); }

static void backspace(void)
{
	if (!pwlen) return;
	do pwlen--; while (pwlen && (pw[pwlen] & 0xC0) == 0x80); /* drop one UTF-8 character */
	explicit_bzero(pw + pwlen, sizeof pw - pwlen);
	pwcount--;
	compose_reset();
	changed();
}

static void arm(int ms, int every_ms)
{
	struct itimerspec t = { { every_ms / 1000, (every_ms % 1000) * 1000000L }, { ms / 1000, (ms % 1000) * 1000000L } };
	timerfd_settime(tfd, 0, &t, NULL);
}

/* The answer goes to the descriptor the agent passed: polkit-agent-helper-1's stdin. One write, so a
 * line is never split. No descriptor, or a pipe whose reader is gone (EPIPE): nothing to do, the agent
 * sees the polkit helper end. "lost" is only ever about the keyboard. */
static void submit(void)
{
	char line[MAXPW + 2];
	memcpy(line, pw, pwlen);
	line[pwlen] = '\n';
	if (secret_fd >= 0) { ssize_t w = write(secret_fd, line, pwlen + 1); (void)w; }
	explicit_bzero(line, sizeof line);
	wipe();
	changed();
}

static int ctrl_active(void) { return xkb_state_mod_name_is_active(xst, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE); }

static void press(uint32_t code, int is_repeat)
{
	xkb_keycode_t kc = code + 8;
	xkb_keysym_t sym = xkb_state_key_get_one_sym(xst, kc);
	if (!have_focus) return;
	switch (sym) {
	case XKB_KEY_BackSpace:
		if (mode == 2) return;
		if (ctrl_active()) { clear_all(); return; } /* the dead key goes with the rest */
		if (cst && xkb_compose_state_get_status(cst) == XKB_COMPOSE_COMPOSING) { compose_reset(); return; } /* forget the dead key */
		backspace();
		return;
	case XKB_KEY_Return: case XKB_KEY_KP_Enter:
		compose_reset();
		if (!is_repeat) out("enter\n");
		return;
	case XKB_KEY_Escape: if (!is_repeat) { wipe(); out("esc\n"); } return;
	case XKB_KEY_Tab: compose_reset(); if (!is_repeat) out(xkb_state_mod_name_is_active(xst, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) ? "btab\n" : "tab\n"); return;
	case XKB_KEY_ISO_Left_Tab: compose_reset(); if (!is_repeat) out("btab\n"); return;
	case XKB_KEY_Up: case XKB_KEY_KP_Up: out("up\n"); return;
	case XKB_KEY_Down: case XKB_KEY_KP_Down: out("down\n"); return;
	case XKB_KEY_space:
		if (mode == 2) { if (!is_repeat) out("space\n"); return; }
		break;
	case XKB_KEY_u:
		if (mode != 2 && ctrl_active()) { clear_all(); return; }
		break;
	}
	if (mode == 2) return;
	if (ctrl_active() ||
	    xkb_state_mod_name_is_active(xst, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) ||
	    xkb_state_mod_name_is_active(xst, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE))
		return;
	char u[64];
	int n;
	/* Compose: a modifier key changes nothing (feed ignores it); a dead key or Multi_key starts or continues a
	 * sequence and types nothing yet; the sequence's last key types its result. */
	enum xkb_compose_feed_result fr = cst ? xkb_compose_state_feed(cst, sym) : XKB_COMPOSE_FEED_IGNORED;
	switch (fr == XKB_COMPOSE_FEED_ACCEPTED ? xkb_compose_state_get_status(cst) : XKB_COMPOSE_NOTHING) {
	case XKB_COMPOSE_COMPOSING: return;
	case XKB_COMPOSE_CANCELLED: compose_reset(); return;
	case XKB_COMPOSE_COMPOSED:
		n = xkb_compose_state_get_utf8(cst, u, sizeof u);
		if (n <= 0) n = xkb_keysym_to_utf8(xkb_compose_state_get_one_sym(cst), u, sizeof u) - 1; /* counts the NUL */
		compose_reset();
		break;
	default:
		n = xkb_state_key_get_utf8(xst, kc, u, sizeof u);
	}
	if (n <= 0 || (size_t)n >= sizeof u || (unsigned char)u[0] < 0x20 || u[0] == 0x7f) { explicit_bzero(u, sizeof u); return; } /* not text */
	if (pwlen + (size_t)n > MAXPW) { explicit_bzero(u, sizeof u); return; }
	memcpy(pw + pwlen, u, (size_t)n);
	pwlen += (size_t)n;
	pwcount++;
	explicit_bzero(u, sizeof u);
	changed();
}

/* ---- wl_keyboard -------------------------------------------------------- */
static void k_keymap(void *d, struct wl_keyboard *k, uint32_t fmt, int fd, uint32_t size)
{
	(void)d; (void)k;
	if (fmt == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
		char *m = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
		if (m != MAP_FAILED) {
			struct xkb_keymap *nm = xkb_keymap_new_from_string(xctx, m, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
			munmap(m, size);
			if (nm) {
				xkb_state_unref(xst); xkb_keymap_unref(xmap);
				xmap = nm; xst = xkb_state_new(xmap);
			}
		}
	}
	close(fd);
}
static void k_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf, struct wl_array *keys)
{
	(void)d; (void)k; (void)s; (void)keys;
	if (sf == surf) { have_focus = 1; out("ready\n"); }
}
static void k_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *sf)
{
	(void)d; (void)k; (void)s;
	if (sf != surf) return;
	have_focus = 0; rep_key = 0; arm(0, 0);
	out("lost\n");
}
static void k_key(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t state)
{
	(void)d; (void)k; (void)s; (void)t;
	if (!xst) return;
	if (state == WL_KEYBOARD_KEY_STATE_PRESSED) {
		press(key, 0);
		if (xmap && xkb_keymap_key_repeats(xmap, key + 8)) { rep_key = key; arm(rep_delay, 1000 / (rep_rate ? rep_rate : 1)); }
	} else if (key == rep_key) { rep_key = 0; arm(0, 0); }
}
static void k_mods(void *d, struct wl_keyboard *k, uint32_t s, uint32_t dep, uint32_t lat, uint32_t lock, uint32_t grp)
{
	(void)d; (void)k; (void)s;
	if (xst) xkb_state_update_mask(xst, dep, lat, lock, 0, 0, grp);
}
static void k_repeat(void *d, struct wl_keyboard *k, int32_t rate, int32_t delay)
{
	(void)d; (void)k;
	rep_rate = rate; rep_delay = delay;
}
static const struct wl_keyboard_listener kl = { k_keymap, k_enter, k_leave, k_key, k_mods, k_repeat };

static void s_caps(void *d, struct wl_seat *s, uint32_t caps)
{
	(void)d;
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !kbd) { kbd = wl_seat_get_keyboard(s); wl_keyboard_add_listener(kbd, &kl, NULL); }
	else if (!(caps & WL_SEAT_CAPABILITY_KEYBOARD) && kbd) { wl_keyboard_release(kbd); kbd = NULL; }
}
static void s_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener sl = { s_caps, s_name };

/* ---- the surface ---------------------------------------------------------- */
static void l_conf(void *d, struct zwlr_layer_surface_v1 *l, uint32_t serial, uint32_t w, uint32_t h)
{
	(void)d; (void)w; (void)h;
	zwlr_layer_surface_v1_ack_configure(l, serial);
	if (configured) return;
	configured = 1;
	/* one transparent ARGB pixel, so the surface is mapped and the compositor can focus it */
	int fd = memfd_create("rpk", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, 4) < 0) { fprintf(stderr, "rpk-keys: no memfd\n"); quit_now = 1; return; }
	struct wl_shm_pool *p = wl_shm_create_pool(shm, fd, 4);
	struct wl_buffer *b = wl_shm_pool_create_buffer(p, 0, 1, 1, 4, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(p);
	close(fd);
	wl_surface_attach(surf, b, 0, 0);
	wl_surface_commit(surf);
}
static void l_closed(void *d, struct zwlr_layer_surface_v1 *l) { (void)d; (void)l; out("lost\n"); quit_now = 1; }
static const struct zwlr_layer_surface_v1_listener lsl = { l_conf, l_closed };

static void g_add(void *d, struct wl_registry *r, uint32_t name, const char *ifc, uint32_t ver)
{
	(void)d;
	if (!strcmp(ifc, "wl_compositor")) comp = wl_registry_bind(r, name, &wl_compositor_interface, 4);
	else if (!strcmp(ifc, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
	else if (!strcmp(ifc, "wl_seat") && !seat) { seat = wl_registry_bind(r, name, &wl_seat_interface, ver < 5 ? ver : 5); wl_seat_add_listener(seat, &sl, NULL); }
	else if (!strcmp(ifc, "zwlr_layer_shell_v1")) lshell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, 1);
}
static void g_del(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener gl = { g_add, g_del };

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--secret-fd") && i + 1 < argc) secret_fd = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--socket")) { sockmode = 1; evfd = 0; secret_fd = -1; }
	}
	signal(SIGPIPE, SIG_IGN);
	prctl(PR_SET_DUMPABLE, 0);   /* no core file, no ptrace by same-uid peers (Yama aside) */
	mlock(pw, sizeof pw);        /* best effort: keep the buffer out of swap */
	dpy = wl_display_connect(NULL);
	if (!dpy) { fprintf(stderr, "rpk-keys: no Wayland display\n"); return 2; }
	wl_registry_add_listener(wl_display_get_registry(dpy), &gl, NULL);
	wl_display_roundtrip(dpy);
	if (!comp || !shm || !seat || !lshell) { fprintf(stderr, "rpk-keys: compositor lacks wl_compositor/wl_shm/wl_seat/wlr-layer-shell\n"); return 2; }
	xctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	/* the locale's Compose table, the way every xkbcommon client finds it (LC_ALL, LC_CTYPE, LANG; "C" is UTF-8's) */
	const char *loc = getenv("LC_ALL");
	if (!loc || !*loc) loc = getenv("LC_CTYPE");
	if (!loc || !*loc) loc = getenv("LANG");
	if (!loc || !*loc) loc = "C";
	if (xctx) ctab = xkb_compose_table_new_from_locale(xctx, loc, XKB_COMPOSE_COMPILE_NO_FLAGS);
	if (ctab) cst = xkb_compose_state_new(ctab, XKB_COMPOSE_STATE_NO_FLAGS);
	surf = wl_compositor_create_surface(comp);
	struct wl_region *empty = wl_compositor_create_region(comp); /* no input region: pointer goes through */
	wl_surface_set_input_region(surf, empty);
	wl_region_destroy(empty);
	ls = zwlr_layer_shell_v1_get_layer_surface(lshell, surf, NULL, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "ribbon-polkit-keys");
	zwlr_layer_surface_v1_add_listener(ls, &lsl, NULL);
	zwlr_layer_surface_v1_set_size(ls, 1, 1);
	zwlr_layer_surface_v1_set_exclusive_zone(ls, -1);
	zwlr_layer_surface_v1_set_keyboard_interactivity(ls, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
	wl_surface_commit(surf);
	tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);

	char cmd[64]; size_t cl = 0;
	while (!quit_now) {
		wl_display_flush(dpy);
		struct pollfd p[3] = { { wl_display_get_fd(dpy), POLLIN, 0 }, { 0, POLLIN, 0 }, { tfd, POLLIN, 0 } };
		while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
		wl_display_flush(dpy);
		if (poll(p, 3, -1) < 0 && errno != EINTR) { wl_display_cancel_read(dpy); break; }
		if (p[0].revents & POLLIN) { if (wl_display_read_events(dpy) < 0) break; } else wl_display_cancel_read(dpy);
		if (wl_display_dispatch_pending(dpy) < 0) break;
		if (p[2].revents & POLLIN) { uint64_t x; if (read(tfd, &x, sizeof x) > 0 && rep_key) press(rep_key, 1); }
		if (p[1].revents & (POLLIN | POLLHUP)) {
			char buf[64], ctl[CMSG_SPACE(sizeof(int) * 4)];
			struct iovec iov = { buf, sizeof buf };
			struct msghdr mh = { 0 };
			mh.msg_iov = &iov; mh.msg_iovlen = 1; mh.msg_control = ctl; mh.msg_controllen = sizeof ctl;
			ssize_t r = sockmode ? recvmsg(0, &mh, MSG_CMSG_CLOEXEC) : read(0, buf, sizeof buf);
			if (r <= 0) break;                          /* the agent is gone */
			if (sockmode) {
				/* a descriptor is the next answer's pipe; the last one is closed */
				for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c; c = CMSG_NXTHDR(&mh, c)) {
					if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
					int n = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
					int *fds = (int *)(void *)CMSG_DATA(c);
					for (int i = 0; i < n; i++) {
						if (i == n - 1) { if (secret_fd >= 0) close(secret_fd); secret_fd = fds[i]; }
						else close(fds[i]);
					}
				}
			}
			for (ssize_t i = 0; i < r; i++) {
				char c = buf[i];
				if (c != '\n') { if (cl < sizeof cmd - 1) cmd[cl++] = c; continue; }
				cmd[cl] = 0; cl = 0;
				if (!strcmp(cmd, "clear")) clear_all();
				else if (!strcmp(cmd, "submit")) { if (have_focus) submit(); }
				else if (!strcmp(cmd, "mode text") || !strcmp(cmd, "mode echo") || !strcmp(cmd, "mode nav")) {
					int m = cmd[5] == 't' ? 0 : cmd[5] == 'e' ? 1 : 2;
					if (m != mode) { wipe(); mode = m; out("n 0\n"); }
				}
				else if (!strcmp(cmd, "quit")) quit_now = 1;
			}
		}
	}
	wipe();
	return 0;
}
