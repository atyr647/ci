#!/bin/sh
# Ribbon OS checks that run on any Linux host (no Void needed).
set -u
cd "$(dirname "$0")/.." || exit 1
status=0
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() { "$@" || status=1; }
# which base the build is for (tests/base.sh): the runit compatibility and Void's package names are Void's
. tests/base.sh

step "Shell syntax"
for f in $(grep -rlE '^#!/bin/(ba)?sh' srcpkgs build tests --include='*' 2>/dev/null | grep -v '/fixtures/'); do
	case "$(head -n1 "$f")" in
		*bash*) bash -n "$f" || { echo "syntax error: $f"; status=1; } ;;
		*) sh -n "$f" || { echo "syntax error: $f"; status=1; } ;;
	esac
done
echo "checked $(grep -rlE '^#!/bin/(ba)?sh' srcpkgs build tests 2>/dev/null | grep -vc '/fixtures/') scripts"

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
	if sh -c 'grep -rlE "^#!/bin/(ba)?sh" srcpkgs build tests | grep -v /fixtures/ | xargs shellcheck -S warning -e SC1090,SC1091,SC2034,SC2154'; then
		echo "  ok   shellcheck clean"
	else
		echo "  FAIL shellcheck (the warnings are above)"; status=1
	fi
else
	echo "shellcheck not installed; skipped"
fi

step "dinit service lint"
run python3 tests/lint-dinit.py \
	srcpkgs/ribbon-dinit/files/services srcpkgs/ribbon-tools/files/services \
	srcpkgs/ribbon-desktop/files/services
run python3 tests/lint-dinit.py \
	srcpkgs/ribbon-dinit/files/user-services srcpkgs/ribbon-kit/files/services
# the dinit files other packages put in /etc/dinit.d, where dinit looks before Ribbon's: what they depend on must exist
run python3 tests/lint-dinit.py tests/fixtures/dinit-upstream srcpkgs/ribbon-dinit/files/services

step "runit -> dinit generator"
if base_only void "the runit -> dinit generator"; then run sh tests/test-sv2dinit.sh; fi

step "Limine boot menu (ribbon-limine on a fake root)"
run bash tests/test-limine.sh

step "Theme rendering"
tmp=$(mktemp -d)
for p in srcpkgs/ribbon-desktop/files/themes/palettes/*.conf; do
	n=$(basename "$p" .conf)
	bash srcpkgs/ribbon-desktop/files/bin/ribbon-theme render-from srcpkgs/ribbon-desktop/files/themes "$n" "$tmp/$n" || status=1
	if grep -rqE '@[A-Z0-9]+@' "$tmp/$n"; then echo "unreplaced placeholder in $n"; status=1; else echo "  ok   $n"; fi
done
python3 -c "import sys,xml.dom.minidom as m; [m.parse(f) for f in sys.argv[1:]]" \
	"$tmp"/*/wallpaper.svg srcpkgs/ribbon-desktop/files/xdg/labwc/rc.xml srcpkgs/ribbon-desktop/files/xdg/labwc/menu.xml \
	"$tmp"/*/themes/Ribbon/openbox-3/*.svg \
	srcpkgs/ribbon-desktop/files/shell/fonts.conf && echo "  ok   XML/SVG well-formed" || status=1
rm -rf "${tmp:?}"

step "rbnalpha (Tk extension: see-through rounded windows, raster and blur in C)"
rbn_dir=$(mktemp -d)
if [ -f /usr/include/tcl8.6/tk.h ] || [ -f /usr/include/tk.h ]; then
	if make -s -C srcpkgs/ribbon-desktop/files/rbnalpha O="$rbn_dir" CFLAGS="-O2 -Werror" >/dev/null 2>&1; then
		echo "  ok   rbnalpha builds with -Wall -Wextra -Werror"
		# the shell, the login screen, the installer and the apps load it from here
		RBNALPHA_LIB=$rbn_dir/librbnalpha.so; export RBNALPHA_LIB
		if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 tests/rbnalpha.tcl || status=1
		fi
	else
		echo "  FAIL rbnalpha does not build"; status=1
	fi
else
	echo "  skip rbnalpha (no Tk headers); the shell runs with plain windows"
fi

step "Ribbon shell checks"
tmp=$(mktemp -d)
for p in srcpkgs/ribbon-desktop/files/themes/palettes/*.conf; do
	n=$(basename "$p" .conf)
	bash srcpkgs/ribbon-desktop/files/bin/ribbon-theme render-from srcpkgs/ribbon-desktop/files/themes "$n" "$tmp/$n" >/dev/null || status=1
	# gdk-pixbuf identifies SVGs by sniffing the first bytes for "<svg"
	if head -c 200 "$tmp/$n/wallpaper.svg" | grep -q '<svg'; then echo "  ok   $n wallpaper is recognisable as SVG"; else echo "  FAIL $n wallpaper: <svg not in the first 200 bytes"; status=1; fi
done
rm -rf "${tmp:?}"
# the shell's Tcl parses, and the wallpaper generator draws an exact-size SVG
if command -v tclsh8.6 >/dev/null 2>&1; then
	for f in srcpkgs/ribbon-desktop/files/shell/*.tcl tests/shell-scene.tcl tests/shell-updates.tcl tests/shell-updates-flow.tcl \
		srcpkgs/ribbon-desktop/files/greeter/*.tcl tests/greeter-*.tcl \
		srcpkgs/ribbon-desktop/files/bin/ribbon-login-theme tests/make-picture.tcl; do
		if tclsh8.6 <<TCL 2>/dev/null
set fh [open $f]; fconfigure \$fh -encoding utf-8; set src [read \$fh]; close \$fh
exit [expr {[info complete \$src] ? 0 : 1}]
TCL
		then :; else echo "  FAIL $f: incomplete Tcl"; status=1; fi
	done
	echo "  ok   shell and greeter Tcl is complete"
	svg=$(tclsh8.6 srcpkgs/ribbon-desktop/files/bin/ribbon-wallpaper srcpkgs/ribbon-desktop/files/themes/palettes/ribbon.conf 2560x1440)
	if printf '%s' "$svg" | head -c 200 | grep -q '<svg' && printf '%s' "$svg" | grep -q 'width="2560" height="1440"'; then
		echo "  ok   ribbon-wallpaper draws an exact-size SVG"
	else echo "  FAIL ribbon-wallpaper"; status=1; fi
	# draw every mockup scene headless; any Tcl error fails the run
	if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
		# each start gets its own HOME and XDG_RUNTIME_DIR: the shell keeps its start record there (fault::starts,
		# 4 starts in a minute is a crash loop) and its ribbon-shell FIFO, so the runs must not share the session's
		# a scene's output is kept and printed when it fails
		log=$(mktemp)
		for scene in idle floating launcher maximized menu files sound wifi bt power session powerhover wmenu fmenu wctl tray crowded more group gmenu tmenu traylow storage wsmid noupdates notasks; do
			if HOME=$(mktemp -d) XDG_RUNTIME_DIR=$(mktemp -d) RIBBON_SHELL_TEST=tests/shell-scene.tcl RIBBON_SCENE=$scene RIBBON_SHELL_EXIT=1500 \
				xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$log" 2>&1
			then echo "  ok   shell draws the $scene scene"; else sed 's/^/       /' "$log"; echo "  FAIL shell scene $scene"; status=1; fi
		done
		rm -f "$log"
		if HOME=$(mktemp -d) XDG_RUNTIME_DIR=$(mktemp -d) RIBBON_SHELL_TEST=tests/files-ops.tcl \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell; then :
		else echo "  FAIL Ribbon Files operations"; status=1; fi
		# the switcher's parts, the updates chip, clicks, scroll and kit's cache file (hard 60 s limit)
		if HOME=$(mktemp -d) XDG_RUNTIME_DIR=$(mktemp -d) RIBBON_SHELL_TEST=tests/shell-bar.tcl timeout 60 \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell
		then :
		else echo "  FAIL shell bar checks (tests/shell-bar.tcl)"; status=1; fi
	else
		echo "  skip shell scenes (no xvfb-run / wish8.6)"
	fi
else
	echo "  skip shell checks (no tclsh8.6)"
fi
if command -v luac >/dev/null 2>&1 || command -v luac5.4 >/dev/null 2>&1; then
	l=$(command -v luac || command -v luac5.4)
	if "$l" -p srcpkgs/ribbon-desktop/files/conky/lua/ribbon.lua; then echo "  ok   conky Lua parses"; else status=1; fi
fi
if command -v wayland-scanner >/dev/null 2>&1 && pkg-config --exists wayland-client 2>/dev/null; then
	tmp=$(mktemp -d)
	if make -s -C srcpkgs/ribbon-desktop/files/shell-watch O="$tmp" ribbon-shell-watch CFLAGS="-O2 -Werror" >/dev/null 2>&1; then
		echo "  ok   ribbon-shell-watch builds with -Wall -Wextra -Werror"
	else
		echo "  FAIL ribbon-shell-watch does not build"; status=1
	fi
	rm -rf "${tmp:?}"
else
	echo "  skip ribbon-shell-watch build (no wayland-scanner / wayland-client)"
fi

step "Login screen (greeter)"
# the mockup states drawn headless (tests/greeter-scene.tcl), then the real
# greetd conversation against a scripted fake greetd (tests/fake-greetd.py)
if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
	for scene in password wrong users session picture pictures; do
		tmp=$(mktemp -d)
		if RIBBON_GREETER_STATE=$tmp RIBBON_GREETER_ETC=$tmp RIBBON_GREETER_TEST=tests/greeter-scene.tcl \
			RIBBON_GREETER_SCENE=$scene RIBBON_GREETER_EXIT=1500 \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/greeter/main.tcl -name ribbon-greeter >"$tmp.log" 2>&1
		then echo "  ok   greeter draws the $scene scene"; else sed 's/^/       /' "$tmp.log"; echo "  FAIL greeter scene $scene"; status=1; fi
		rm -f "$tmp.log"
		rm -rf "${tmp:?}"
	done
	# the login theme: a palette and a picture installed on a fake /etc by
	# ribbon-login-theme, drawn (the picture scaled and cropped to the
	# screen), then the pattern in that palette, then a broken picture
	# (the pattern again); screenshots go to $RIBBON_SHOTS when it is set
	tmp=$(mktemp -d); mkdir -p "$tmp/etc"
	lt() { RIBBON_LOGIN_ROOT=$tmp tclsh8.6 srcpkgs/ribbon-desktop/files/bin/ribbon-login-theme "$@" >/dev/null; }
	sed -e 's/^ACCENT=.*/ACCENT=#22CC88/' -e 's/^DESK_TOP=.*/DESK_TOP=#14304A/' -e 's/^DESK_BOTTOM=.*/DESK_BOTTOM=#0A1420/' \
		-e 's/^DESK_STRIPE_ALPHA=.*/DESK_STRIPE_ALPHA=0.08/' srcpkgs/ribbon-desktop/files/themes/palettes/ribbon-fjord.conf > "$tmp/mint.conf"
	tclsh8.6 tests/make-picture.tcl bands 1440 1100 "$tmp/picture.png"
	command -v import >/dev/null 2>&1 && shots=${RIBBON_SHOTS:-$tmp} || shots=
	[ -n "$shots" ] && mkdir -p "$shots"
	for scene in picture pattern broken; do
		case $scene in
			picture) lt set-palette "$tmp/mint.conf" && lt set-background "$tmp/picture.png"; expect="picture #3060A0" ;;
			pattern) lt set-background ribbon; expect=pattern ;;
			broken) printf '\211PNG\r\n\032\nnot really' > "$tmp/etc/ribbon/login/background.png"; expect=pattern ;;
		esac
		if env RIBBON_GREETER_STATE="$tmp" RIBBON_GREETER_ETC="$tmp/etc" RIBBON_GREETER_TEST=tests/greeter-scene.tcl \
			RIBBON_GREETER_SCENE=password RIBBON_GREETER_EXIT=1500 RIBBON_GREETER_EXPECT="$expect" RIBBON_GREETER_ACCENT=#22CC88 \
			${shots:+"RIBBON_GREETER_SHOT=$shots/greeter-login-$scene.png"} \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/greeter/main.tcl -name ribbon-greeter >"$tmp/out" 2>&1
		then echo "  ok   greeter with a login palette and background: $scene"
		else sed 's/^/       /' "$tmp/out"; echo "  FAIL greeter login theme: $scene"; status=1; fi
	done
	[ -n "${RIBBON_SHOTS:-}" ] && echo "  screenshots in $RIBBON_SHOTS"
	rm -rf "${tmp:?}"
	# unix_sockets: installed, or built where UNIX_SOCKETS_DIR says
	tlp="${UNIX_SOCKETS_DIR:-} ${TCLLIBPATH:-}"
	if echo 'exit [catch {package require unix_sockets}]' | TCLLIBPATH=$tlp tclsh8.6 2>/dev/null && command -v python3 >/dev/null 2>&1; then
		tmp=$(mktemp -d)
		python3 tests/fake-greetd.py "$tmp/greetd.sock" "$tmp/requests.log" &
		fake=$!
		i=0; while [ ! -S "$tmp/greetd.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
		if GREETD_SOCK=$tmp/greetd.sock RIBBON_GREETER_FAKELOG=$tmp/requests.log RIBBON_GREETER_STATE=$tmp \
			RIBBON_GREETER_ETC=$tmp RIBBON_GREETER_TEST=tests/greeter-flow.tcl TCLLIBPATH=$tlp \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/greeter/main.tcl -name ribbon-greeter >"$tmp/out" 2>&1
		then sed 's/^/  /' "$tmp/out"; else sed 's/^/  /' "$tmp/out"; echo "  FAIL greeter conversations with greetd"; status=1; fi
		[ "$(grep -c '"start_session"' "$tmp/requests.log")" = 4 ] || { echo "  FAIL greeter: expected 4 sessions started"; status=1; }
		kill "$fake" 2>/dev/null
		rm -rf "${tmp:?}"
	else
		echo "  skip greeter conversations (no unix_sockets for Tcl: set UNIX_SOCKETS_DIR, or no python3)"
	fi
else
	echo "  skip greeter (no xvfb-run / wish8.6)"
fi

step "Login screen theme (ribbon-login-theme, ribbon-theme login)"
if command -v tclsh8.6 >/dev/null 2>&1; then run bash tests/test-login-theme.sh; else echo "  skip (no tclsh8.6)"; fi

step "Wallpaper (ribbon-wall)"
# the C engine built with -Werror, the designs at any size and aspect, design
# files refused when they try to run code, the video length rule, then in a
# headless labwc: previews, slideshow, seamless resident and streamed loops,
# pause rules, hotplug and mode/scale changes, both renderers
if command -v tclsh8.6 >/dev/null 2>&1 && pkg-config --exists wayland-client egl glesv2 libavformat libswscale tcl8.6 2>/dev/null; then
	run sh tests/test-ribbon-wall.sh
else
	echo "  skip ribbon-wall (needs tclsh8.6 and the wayland, EGL, FFmpeg and Tcl development files)"
fi

step "Appearance"
# the Theme and Colours pages drawn headless in each scheme, the whole app
# driven through saving, import/export and Apply (pkexec stubbed), the
# wallpaper settings, and the login screen's options in the greeter
if command -v tclsh8.6 >/dev/null 2>&1; then
	run bash tests/test-appearance.sh
else
	echo "  skip Appearance (no tclsh8.6)"
fi

step "Properties"
# the boards' pages (Props-A*) and the pages without boards drawn headless
# in each scheme; the app driven through rename, access, owner and opens-with
# (pkexec stubbed), a folder's count, an app's permissions into kit's grants
# file, and (with kit's library and Mk4tcl) kit's grab, mend and toss
if command -v tclsh8.6 >/dev/null 2>&1; then
	run bash tests/test-properties.sh
else
	echo "  skip Properties (no tclsh8.6)"
fi

step "Tcl extension: unix_extra"
# the companion to unix_sockets (srcpkgs/tcl-unix-extra): -Werror build and
# its tcltest suite on real sockets; the unix_sockets interop tests run when
# that package can be loaded (UNIX_SOCKETS_DIR or an installed copy)
if command -v tclsh8.6 >/dev/null 2>&1 && { [ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ]; }; then
	# the build stays until the end of this run: the Settings steps load it (ux_dir, see the steps below)
	ux_dir=$(mktemp -d)
	if make -s -C srcpkgs/tcl-unix-extra/files O="$ux_dir" CFLAGS="-O2 -Werror" >/dev/null 2>&1; then
		echo "  ok   unix_extra builds with -Wall -Wextra -Werror"
		if make -s -C srcpkgs/tcl-unix-extra/files O="$ux_dir" TCLSH=tclsh8.6 TESTFLAGS="-tmpdir $ux_dir" test >"$ux_dir/log" 2>&1; then
			echo "  ok   unix_extra tests: $(grep -o 'Total.*' "$ux_dir/log" | tr -s '[:space:]' ' ')"
		else
			cat "$ux_dir/log"; echo "  FAIL unix_extra tests"; status=1
		fi
	else
		echo "  FAIL unix_extra does not build"; status=1
	fi
else
	echo "  skip unix_extra (no tclsh8.6 / Tcl headers)"
fi

step "D-Bus client (ribbon::dbus)"
# srcpkgs/ribbon-desktop/files/dbus against private dbus-daemons: every
# type both ways (and through GDBus), calls, errors, timeouts, signals,
# names, fd passing, and a notification server driven by notify-send
if command -v tclsh8.6 >/dev/null 2>&1 && command -v dbus-daemon >/dev/null 2>&1; then
	run sh tests/test-dbus.sh
else
	echo "  skip ribbon::dbus (no tclsh8.6 / dbus-daemon)"
fi

step "mkkitfs on the PATH (kit run's FUSE checks)"
# kit run mounts kits through mkkitfs, and tests/kit-cli.tcl finds it on the PATH. It is built here from
# KIT_METAKIT_TARBALL=<the Metakit tarball> (the commit srcpkgs/mkkitfs/template names), and only when that
# file's sha256 is the template's checksum. Without it, or with another file, the kit step's FUSE checks skip.
kitfs_tmp=$(mktemp -d)
if [ -n "${KIT_METAKIT_TARBALL:-}" ] && [ -f "$KIT_METAKIT_TARBALL" ]; then
	kit_commit=$(sed -n 's/^_mkcommit=//p' srcpkgs/mkkitfs/template)
	kit_sum=$(sed -n 's/^checksum=//p' srcpkgs/mkkitfs/template)
	if [ "$(sha256sum "$KIT_METAKIT_TARBALL" | cut -d' ' -f1)" != "$kit_sum" ]; then
		echo "  skip mkkitfs: $KIT_METAKIT_TARBALL is not the tarball the template names (sha256 $kit_sum)"
	elif ! tar xzf "$KIT_METAKIT_TARBALL" -C "$kitfs_tmp" 2>/dev/null; then
		echo "  skip mkkitfs: $KIT_METAKIT_TARBALL does not unpack"
	elif make -s -C srcpkgs/mkkitfs/files METAKIT="$kitfs_tmp/metakit-$kit_commit" O="$kitfs_tmp/build" \
		CXXFLAGS="-O2 -Werror" >"$kitfs_tmp/build.log" 2>&1; then
		echo "  ok   mkkitfs built from the verified Metakit tarball, on the PATH for kit"
		PATH="$kitfs_tmp/build:$PATH"; export PATH
	else
		cat "$kitfs_tmp/build.log"; echo "  FAIL mkkitfs does not build"; status=1
	fi
else
	echo "  skip mkkitfs (no KIT_METAKIT_TARBALL: kit run's FUSE checks skip)"
fi

step "kit (the kit command)"
# every verb end to end (tests/kit-cli.tcl): kits made with kit pack, published with kittrust's
# kitindex to local mirrors (tests/kit-httpd.tcl and file://), signed with kittrust's test keys;
# install, update, check, toss, offline, pinned, expired, bad chunks, SIGKILL at every step.
# KITFMT_MK4TCL=<dir> names the Mk4tcl to use (it wins over any other copy on auto_path)
if command -v tclsh8.6 >/dev/null 2>&1; then
	for f in srcpkgs/ribbon-kit/files/lib/*.tcl srcpkgs/ribbon-kit/files/bin/kit srcpkgs/ribbon-kit/files/bin/kit-updater srcpkgs/ribbon-kit/files/bin/kitd \
		tests/kit-cli.tcl tests/kit-httpd.tcl; do
		tclsh8.6 /dev/stdin "$f" <<'TCL' || { echo "  FAIL $f: incomplete Tcl"; status=1; }
set fh [open [lindex $argv 0]]; fconfigure $fh -encoding utf-8; set src [read $fh]; close $fh
exit [expr {[info complete $src] ? 0 : 1}]
TCL
	done
	echo "  ok   kit's Tcl is complete"
	if command -v minisign >/dev/null 2>&1 &&
		echo 'exit [catch {package require Mk4tcl}]' | TCLLIBPATH="${KITFMT_MK4TCL:-}" tclsh8.6 >/dev/null 2>&1; then
		run timeout -k 5 900 tclsh8.6 -encoding utf-8 tests/kit-cli.tcl
		# the bar's updates panel: tests/steps.d/45-shell-updates.sh
	else
		echo "  skip kit end to end (needs minisign and Mk4tcl: KITFMT_MK4TCL=<dir with Mk4tcl>)"
	fi
else
	echo "  skip kit (no tclsh8.6)"
fi

step "Tk installer"
# every page of the installer drawn headless with the mockups' machine
# (tests/installer-scene.tcl, the fake backend), then the whole flow driven
# by keys and clicks to a finished (fake) install; any Tcl error fails
if command -v tclsh8.6 >/dev/null 2>&1; then
	for f in srcpkgs/ribbon-installer/files/tk/*.tcl tests/installer-scene.tcl tests/installer-flow.tcl tests/fixtures/installer/mockup-machine.tcl; do
		if tclsh8.6 <<TCL 2>/dev/null
set fh [open $f]; fconfigure \$fh -encoding utf-8; set src [read \$fh]; close \$fh
exit [expr {[info complete \$src] ? 0 : 1}]
TCL
		then :; else echo "  FAIL $f: incomplete Tcl"; status=1; fi
	done
	echo "  ok   installer Tcl is complete"
	if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
		cache=$(mktemp -d)
		for scene in welcome keyboard disk alongside manual setup hardware apps you summary progress "done" dialog error edit unsafe check planerror close noprobe hwscroll; do
			if HOME=$(mktemp -d) XDG_CACHE_HOME=$cache RIBBON_INSTALLER_SCENE=tests/installer-scene.tcl RIBBON_SCENE=$scene RIBBON_INSTALLER_EXIT=800 \
				xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-installer/files/tk/main.tcl >"$cache/scene.log" 2>&1
			then echo "  ok   installer draws the $scene page"; else sed 's/^/       /' "$cache/scene.log"; echo "  FAIL installer page $scene"; status=1; fi
		done
		if out=$(HOME=$(mktemp -d) XDG_CACHE_HOME=$cache RIBBON_INSTALLER_SCENE=tests/installer-flow.tcl \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-installer/files/tk/main.tcl 2>&1); then
			echo "  ok   installer flow: $(printf '%s\n' "$out" | grep -c '  ok ') checks, install reached Done"
		else printf '%s\n' "$out" | grep -v '  ok '; echo "  FAIL installer flow"; status=1; fi
		rm -rf "${cache:?}"
	else
		echo "  skip installer pages (no xvfb-run / wish8.6)"
	fi
else
	echo "  skip installer checks (no tclsh8.6)"
fi

step "Installer backend"
# the driver table and machine facts on a fake computer (no root needed),
# then probe, --check-answers and installs on loop-device disks (root)
if command -v tclsh8.6 >/dev/null 2>&1; then
	for f in srcpkgs/ribbon-installer/files/backend/*.tcl srcpkgs/ribbon-installer/files/bin/ribbon-install-probe; do
		tclsh8.6 /dev/stdin "$f" <<'TCL' || { echo "  FAIL $f: incomplete Tcl"; status=1; }
set fh [open [lindex $argv 0]]; set src [read $fh]; close $fh
exit [expr {[info complete $src] ? 0 : 1}]
TCL
	done
	run tclsh8.6 tests/installer-hwdb.tcl
	run bash tests/test-installer.sh
else
	echo "  skip installer backend (no tclsh8.6)"
fi

step "Kit signing (kit/kittrust)"
# the root-signed key list and its updates, kit seals, the signed index and
# kitfmt's verifier hook, with the test-only keys in tests/fixtures/kittrust
# (KITFMT_MK4TCL=<dir> adds a repository built from kits and a changed chunk)
if command -v tclsh8.6 >/dev/null 2>&1 && command -v minisign >/dev/null 2>&1; then
	run timeout -k 5 600 tclsh8.6 tests/kittrust.tcl
else
	echo "  skip kit signing (no tclsh8.6 / minisign)"
fi

step "mkkitfs (kit files through FUSE)"
# agreement with kitfmt on the golden kits, the damaged ones refused, a fuzz pass, and through
# FUSE where /dev/fuse is usable: the session server, concurrent reads, start-up, composition
run sh tests/test-mkkitfs.sh

step "Steps added by units (tests/steps.d/*.sh, in name order)"
# a unit adds its own file there: each prints its checks or a skip, exits non-zero on failure, and
# has a hard time limit here
for s in tests/steps.d/*.sh; do
	[ -e "$s" ] || continue
	echo "-- $(basename "$s")"
	# Settings pages load ribbon::dbus, which needs unix_extra on TCLLIBPATH: every step gets this run's build
	# (steps that build their own copy, such as 46, 55-network, 55-power and 70, set TCLLIBPATH themselves)
	if [ -n "${ux_dir:-}" ]; then
		TCLLIBPATH="$ux_dir${TCLLIBPATH:+ $TCLLIBPATH}" timeout -k 10 600 sh "$s" || { echo "  FAIL $(basename "$s")"; status=1; }
	elif timeout -k 10 600 sh "$s"; then :; else echo "  FAIL $(basename "$s")"; status=1; fi
done

step "Package names exist in Void"
if ! base_only void "Void's package names"; then :
elif [ "${RIBBON_OFFLINE:-}" = 1 ]; then echo "offline; skipped"; else run python3 build/tools/check-packages.py; fi

[ -n "${ux_dir:-}" ] && rm -rf "$ux_dir"
rm -rf "${kitfs_tmp:?}"
echo
[ $status -eq 0 ] && printf '\033[32mall checks passed\033[0m\n' || printf '\033[31msome checks failed\033[0m\n'
exit $status
