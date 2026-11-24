#!/bin/sh
# Ribbon Terminal (foot + the Tk tab strip in the shell): tests/term/run.sh. TERM_ROOT=<test root> runs it against
# that root's labwc (0.20.3: placing, rebinds, SendToDesktop too); without one it uses the host's labwc and checks what
# labwc 0.7 can do (the virtual keyboard, tabs, switching, Alt+number, the mark, the dock), and skips under 0.7.
set -u
cd "$(dirname "$0")/../.." || exit 1
for t in pkg-config wayland-scanner wish8.6 grim convert foot; do
	command -v $t >/dev/null 2>&1 || [ -n "${TERM_ROOT:-}" ] || { echo "  skip term (no $t)"; exit 0; }
done
pkg-config --exists wayland-client xkbcommon wayland-protocols || { echo "  skip term (no wayland-client / xkbcommon / wayland-protocols)"; exit 0; }
sh tests/term/run.sh ${TERM_ROOT:-}
