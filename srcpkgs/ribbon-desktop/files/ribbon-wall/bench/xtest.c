/* xtest argb|shape|alpha WID : XWayland transparency probes.
 *  argb  - 32-bit ARGB override-redirect window 600x200 at 100,300: left third
 *          alpha 0, middle third 50% green (premultiplied), right opaque blue
 *  shape - 24-bit window 600x200 at 100,300 filled blue, bounding shape =
 *          two 200x100 rectangles (holes elsewhere)
 *  alpha WID - read back the window's pixels: the alpha byte Tk wrote */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
	Display *d = XOpenDisplay(NULL); int s = DefaultScreen(d);
	if (!strcmp(argv[1], "alpha")) {
		Window w = strtoul(argv[2], 0, 0); XWindowAttributes a; XGetWindowAttributes(d, w, &a);
		XImage *im = XGetImage(d, w, 0, 0, a.width, a.height, ~0UL, ZPixmap);
		printf("depth %d; pixels:", a.depth);
		for (int i = 0; i < 4; i++) printf(" %08lx", XGetPixel(im, i * a.width / 4 + 5, a.height / 2));
		printf("\n"); return 0;
	}
	XSetWindowAttributes at = {0}; at.override_redirect = True;
	Window w; GC gc;
	if (!strcmp(argv[1], "argb")) {
		XVisualInfo vi; XMatchVisualInfo(d, s, 32, TrueColor, &vi);
		at.colormap = XCreateColormap(d, RootWindow(d, s), vi.visual, AllocNone);
		at.border_pixel = 0; at.background_pixel = 0;
		w = XCreateWindow(d, RootWindow(d, s), 100, 300, 600, 200, 0, 32, InputOutput, vi.visual,
			CWOverrideRedirect | CWColormap | CWBorderPixel | CWBackPixel, &at);
		XMapWindow(d, w); XSync(d, 0); usleep(200000);
		gc = XCreateGC(d, w, 0, 0);
		XSetForeground(d, gc, 0x00000000); XFillRectangle(d, w, gc, 0, 0, 200, 200);
		XSetForeground(d, gc, 0x80008000); XFillRectangle(d, w, gc, 200, 0, 200, 200);
		XSetForeground(d, gc, 0xff0000ff); XFillRectangle(d, w, gc, 400, 0, 200, 200);
	} else {
		w = XCreateWindow(d, RootWindow(d, s), 100, 300, 600, 200, 0, CopyFromParent, InputOutput, CopyFromParent, CWOverrideRedirect, &at);
		XRectangle r[2] = {{0, 0, 200, 100}, {300, 100, 200, 100}};
		XShapeCombineRectangles(d, w, ShapeBounding, 0, 0, r, 2, ShapeSet, Unsorted);
		XMapWindow(d, w); XSync(d, 0); usleep(200000);
		gc = XCreateGC(d, w, 0, 0);
		XSetForeground(d, gc, 0x0000ff); XFillRectangle(d, w, gc, 0, 0, 600, 200);
	}
	XFlush(d); sleep(3); return 0;
}
