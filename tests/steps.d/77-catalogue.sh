#!/bin/sh
# The Catalogue (srcpkgs/ribbon-desktop/files/apps/catalogue; boards design/mockups/Catalogue-1..8): its
# Tcl is complete, it is a drop-in app with its command and launcher entry, and .flatpakref files open in
# it (application/vnd.flatpak.ref). tests/catalogue-source.tcl: its model without Tk (flatpak's outputs,
# a Flatpak's requests, a .flatpakref, search across both sources) and Flathub end to end against a
# stand-in flatpak (remote-add, remote-ls, remote-info, install with progress, a failure, Cancel,
# install --from, run). Under xvfb each board's state is drawn and compared with the board
# (tests/catalogue-boards: the window's 1100 x 720, both blurred, RMSE < 0.05). tests/catalogue-kit.tcl,
# with Mk4tcl (KITFMT_MK4TCL) and minisign: kitq.tcl against a real signed test repository (apps, info,
# grab answered no and yes, its progress) and the real window driven through search, a kit's page,
# kit's prompt as the sheet, the download and Open (tests/catalogue-flow.tcl).
# NOT covered: the real flatpak and Flathub (no network here); its progress output is read for "N%".
set -u
cd "$(dirname "$0")/../.." || exit 1
D=srcpkgs/ribbon-desktop/files
A=$D/apps/catalogue
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
status=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; status=1; }
for f in "$A"/*.tcl tests/catalogue-*.tcl; do
	tclsh8.6 /dev/stdin "$f" <<'TCL' || fail "$f: incomplete Tcl"
set fh [open [lindex $argv 0]]; fconfigure $fh -encoding utf-8; set src [read $fh]; close $fh
exit [expr {[info complete $src] ? 0 : 1}]
TCL
done
sh -n "$A/bin/ribbon-catalogue" && ok "ribbon-catalogue is a shell script that parses" || fail "ribbon-catalogue does not parse"
grep -qx 'MimeType=application/vnd.flatpak.ref;' "$A/applications/ribbon-catalogue.desktop" && grep -qx 'Exec=ribbon-catalogue %f' "$A/applications/ribbon-catalogue.desktop" \
	&& ok "its launcher entry takes a .flatpakref" || fail "the launcher entry does not take .flatpakref files"
if grep -qx 'application/vnd.flatpak.ref=ribbon-catalogue.desktop' "$D/xdg/mimeapps.list"; then ok "a .flatpakref opens in the Catalogue (mimeapps.list)"
else echo "  skip a .flatpakref opening in the Catalogue: mimeapps.list has no application/vnd.flatpak.ref line yet (integration request)"; fi
timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/catalogue-source.tcl || { echo "  FAIL the Catalogue's model (tests/catalogue-source.tcl)"; status=1; }
if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1 && command -v import >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
	mkdir -p "$T/home"
	for scene in browse search kit sheet installing installed flathub flatpakref; do
		rm -f "$T/shot.png"
		env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_CATALOGUE_SCENE=tests/catalogue-scene.tcl \
			RIBBON_SCENE=$scene RIBBON_CATALOGUE_SHOT="$T/shot.png" \
			timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$A/main.tcl" >"$T/out" 2>&1
		r=""
		if [ -s "$T/shot.png" ]; then
			convert "$T/shot.png" -crop 1100x720+170+104 +repage -blur 0x2 "$T/a.png"; convert "tests/catalogue-boards/$scene.png" -blur 0x2 "$T/b.png"
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		fi
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then ok "$scene matches its board (blurred RMSE $r)"
		else fail "$scene against its board: RMSE ${r:-?}"; sed 's/^/       /' "$T/out"; fi
	done
	env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_CATALOGUE_SCENE=tests/catalogue-footer.tcl \
		timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$A/main.tcl" || { echo "  FAIL the app page's footer while another app installs (tests/catalogue-footer.tcl)"; status=1; }
else
	echo "  skip the boards (no xvfb-run / wish8.6 / ImageMagick)"
fi
if [ -n "${KITFMT_MK4TCL:-}" ] && command -v minisign >/dev/null 2>&1; then
	timeout -k 5 900 tclsh8.6 -encoding utf-8 tests/catalogue-kit.tcl || { echo "  FAIL the Catalogue's kit side (tests/catalogue-kit.tcl)"; status=1; }
else
	echo "  skip the Catalogue's kit side (needs KITFMT_MK4TCL and minisign)"
fi
exit $status
