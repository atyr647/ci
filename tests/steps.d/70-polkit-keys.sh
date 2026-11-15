#!/bin/sh
# ribbon-polkit-keys, the native keyboard helper of the password prompt (apps/polkit/native), against a real compositor:
# native/test/run.sh starts a headless labwc, a Tk window on XWayland that stands in for the card, an X11 "keylogger"
# (XInput2 raw events and XQueryKeymap) and a virtual keyboard, and checks that while the helper holds the keyboard the
# X11 clients see none of the keys (and that they do without it), the exact answer reaches the secret descriptor, Return
# alone writes nothing, Tab/arrows/Space come as events only in nav mode, echo mode is the only one that sends text,
# key repeat, and "lost" when another client takes the keyboard. Skips without labwc, Xwayland, a C compiler,
# wayland-scanner, wayland-client and xkbcommon headers, libX11/libXi headers, wish8.6 or the tools it uses.
set -u
cd "$(dirname "$0")/../.." || exit 1
miss=
for c in labwc Xwayland wayland-scanner pkg-config cc wish8.6 timeout; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
if [ -z "$miss" ]; then
	pkg-config --exists wayland-client xkbcommon wayland-protocols x11 xi 2>/dev/null || miss="$miss (wayland-client/xkbcommon/wayland-protocols/x11/xi headers)"
fi
if [ -n "$miss" ]; then
	echo "  skip ribbon-polkit-keys under labwc (missing:$miss)"
	exit 0
fi
out=$(mktemp)
trap 'rm -f "$out"' EXIT
if timeout -k 10 240 sh srcpkgs/ribbon-desktop/files/apps/polkit/native/test/run.sh >"$out" 2>&1; then
	echo "  ok   ribbon-polkit-keys: $(grep -c '^  ok ' "$out") checks under $(sed -n 's/^compositor: \(.*\), socket.*/\1/p' "$out")"
else
	sed 's/^/       /' "$out"
	echo "  FAIL ribbon-polkit-keys under labwc"
	exit 1
fi
