#!/bin/bash
# Properties: its Tcl is complete, it draws the boards' pages (Props-A*) in
# Graphite, Fjord and Moss, and
# (tests/properties-flow.tcl) it renames a file, changes its access, owner
# and app with Apply and Revert (pkexec stubbed: it logs and runs the
# command), counts a folder, and edits an app's permissions into kit's
# grants file. With kit's library, Mk4tcl (KITFMT_MK4TCL) and minisign it
# also installs, repairs and uninstalls a .kit through kit's grab, mend and
# toss. Without root or a display, parts are skipped.
set -u
cd "$(dirname "$0")/.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { local what=$1; shift; if "$@" >"$T/out" 2>&1; then ok "$what"; else fail "$what"; sed 's/^/       /' "$T/out"; fi; }

for f in "$D"/properties/*.tcl tests/properties-*.tcl; do
	tclsh8.6 /dev/stdin "$f" <<'TCL' || fail "$f: incomplete Tcl"
set fh [open [lindex $argv 0]]; fconfigure $fh -encoding utf-8; set src [read $fh]; close $fh
exit [expr {[info complete $src] ? 0 : 1}]
TCL
done
ok "the app's Tcl is complete"
check "ribbon-properties is a shell script that parses" sh -n "$D/bin/ribbon-properties"
check "the .kit MIME type is well-formed XML" python3 -c "import xml.dom.minidom as m, sys; m.parse(sys.argv[1])" "$D/mime/ribbon-kit.xml"
# K4: a .kit runs when opened (kit run); Properties is on right-click and Alt+Enter
check "opening a .kit is kit run (mimeapps.list, ribbon-kit-run.desktop)" sh -c "grep -qx 'application/x-ribbon-kit=ribbon-kit-run.desktop' '$D/xdg/mimeapps.list' &&
	grep -qx 'Exec=kit run %f' '$D/applications/ribbon-kit-run.desktop' && grep -qx 'MimeType=application/x-ribbon-kit;' '$D/applications/ribbon-kit-run.desktop' &&
	! grep -q '^MimeType=' '$D/applications/ribbon-properties.desktop'"
tclsh8.6 /dev/stdin "$D/shell" >"$T/act" 2>&1 <<'TCL'
lassign $argv D
source -encoding utf-8 $D/apps.tcl
source -encoding utf-8 $D/files.tcl
proc apps::run {cmd} { lappend ::ran $cmd }
set files::st(.w,path) /tmp/x
files::activate .w notes.kit
puts $::ran
TCL
check "double-click on a .kit in Files runs it with kit run" grep -qF "kit run '/tmp/x/notes.kit'" "$T/act"

if ! command -v xvfb-run >/dev/null 2>&1 || ! command -v wish8.6 >/dev/null 2>&1; then
	echo "  skip the app (no xvfb-run / wish8.6)"
	[ $fails -eq 0 ] && echo "properties: all checks passed" || echo "properties: $fails checks failed"
	exit $((fails > 0))
fi

echo "the pages, in each scheme"
for scheme in graphite fjord moss; do
	h=$T/home-$scheme; tclsh8.6 -encoding utf-8 tests/properties-fixture.tcl "$h" $scheme "$T/pics"
	scenes="rail permissions photo folder"
	[ $scheme = graphite ] && scenes="$scenes storage libraries signature held kitfile notkit sheet install uninstall rewind"
	for scene in $scenes; do
		check "draws $scene in $scheme" env HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_CACHE_HOME="$T/cache" \
			KIT_LIB=/nonexistent RIBBON_PROPERTIES_SCENE=tests/properties-scene.tcl RIBBON_SCENE=$scene RIBBON_PROPERTIES_EXIT=600 \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/properties/main.tcl"
	done
done
# the boards' pages, drawn and compared with the board's crop in tests/properties-boards (the page right of
# the rail, 870 x 720; both blurred, RMSE): Props-A5-Storage, A6-Libraries, A7-Signature, A11-Held,
# then A8, A9 and kit's prompt
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then
	h=$T/home-graphite
	for scene in storage libraries signature held; do
		rm -f "$T/shot.png"
		env HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_CACHE_HOME="$T/cache" \
			KIT_LIB=/nonexistent RIBBON_PROPERTIES_SCENE=tests/properties-scene.tcl RIBBON_SCENE=$scene RIBBON_PROPERTIES_SHOT="$T/shot.png" \
			timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/properties/main.tcl" >"$T/out" 2>&1
		r=""
		if [ -s "$T/shot.png" ]; then
			convert "$T/shot.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert "tests/properties-boards/$scene.png" -blur 0x2 "$T/b.png"
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		fi
		if awk "BEGIN { exit !(${r:-1} < 0.02) }"; then ok "$scene matches its board (blurred RMSE $r)"
		else fail "$scene against its board: RMSE ${r:-?}"; sed 's/^/       /' "$T/out"; fi
	done
	# Props-A8-KitFile (the page of a 1100 x 720 window) and A9-NotKit (a 600 px window, centred: 60 lower);
	# kit's prompt (Kit-Sheet-1..4): the sheet alone, centred on the window, against the board's sheet
	# (640 wide, 700 with Uninstall's data question; 88 header + 48 a row + 72 footer, + 74 a data line)
	for spec in kitfile:kitfile:870x720+400+104 notkit:notkit:870x600+400+164 \
		install:sheet-install:640x304+400+312 sheet:sheet-update:640x208+400+360 uninstall:sheet-uninstall:700x344+370+292 rewind:sheet-rewind:640x208+400+360; do
		scene=${spec%%:*}; rest=${spec#*:}; board=${rest%%:*}; geo=${rest#*:}
		rm -f "$T/shot.png"
		env HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_CACHE_HOME="$T/cache" \
			KIT_LIB=/nonexistent RIBBON_PROPERTIES_SCENE=tests/properties-scene.tcl RIBBON_SCENE=$scene RIBBON_PROPERTIES_SHOT="$T/shot.png" \
			timeout 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/properties/main.tcl" >"$T/out" 2>&1
		r=""
		if [ -s "$T/shot.png" ]; then
			convert "$T/shot.png" -crop "$geo" +repage -blur 0x2 "$T/a.png"; convert "tests/properties-boards/$board.png" -blur 0x2 "$T/b.png"
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		fi
		if awk "BEGIN { exit !(${r:-1} < 0.02) }"; then ok "$scene matches $board (blurred RMSE $r)"
		else fail "$scene against $board: RMSE ${r:-?}"; sed 's/^/       /' "$T/out"; fi
	done
else
	echo "  skip the board comparisons (no ImageMagick)"
fi

echo "the flow"
if [ "$(id -u)" != 0 ]; then
	echo "  skip the flow (it gives files away: needs root)"
else
	h=$T/flow; tclsh8.6 -encoding utf-8 tests/properties-fixture.tcl "$h" graphite "$T/pics"
	B=$T/stubs; mkdir -p "$B"
	# pkexec: log the call, then run it (as root, as polkit would)
	cat > "$B/pkexec" <<STUB
#!/bin/sh
echo "\$*" >> "$T/pkexec.log"
case "\$1" in /*) ;; *) echo "pkexec: needs an absolute path" >&2; exit 127 ;; esac
exec "\$@"
STUB
	chmod +x "$B/pkexec"
	kitenv=""
	K=srcpkgs/ribbon-kit/files
	F=tests/fixtures/kittrust
	if [ -f "$K/lib/verbs.tcl" ] && command -v minisign >/dev/null 2>&1; then
		# kittrust's trusted key list (the test-only root and app keys): who signed, for the
		# Signature facts, and what kit verifies a kit against
		mkdir -p "$T/kit/src/notes/bin" "$T/kit/src/notes/share/applications"
		if { tclsh8.6 kit/kittrust/kitkey init -repository org.ribbon.test -root "$F/test-root.pub" "$T/kit/keys" &&
			tclsh8.6 kit/kittrust/kitkey add -role app -name ribbon-release "$T/kit/keys" "$F/test-app.pub" &&
			tclsh8.6 kit/kittrust/kitkey add -role index "$T/kit/keys" "$F/test-index.pub" &&
			tclsh8.6 kit/kittrust/kitkey sign -key "$F/test-root.key" "$T/kit/keys"; } >"$T/out" 2>&1; then
			printf 'keys = %s\ntimeout = 5\nmirror = file://%s\n' "$T/kit/keys" "$T/kit/repo" > "$T/kit/kit.conf"
			kitenv="PROPS_TRUST=$T/kit/keys PROPS_TRUST_PUB=$PWD/$F/test-app.pub"
		else sed 's/^/       /' "$T/out"; fail "kitkey: a trusted key list for the flow"; fi
	fi
	if [ -n "$kitenv" ] && [ -n "${KITFMT_MK4TCL:-}" ]; then
		# a kit to install, signed with the test app key
		printf '#!/bin/sh\necho notes\n' > "$T/kit/src/notes/bin/notes"; chmod 755 "$T/kit/src/notes/bin/notes"
		printf '[Desktop Entry]\nType=Application\nName=Notes\nGenericName=Note taker\nExec=notes\nCategories=Office;\n' > "$T/kit/src/notes/share/applications/notes.desktop"
		cat > "$T/kit/src/notes.manifest" <<'MANIFEST'
name org.example.notes version 1.0 kind app summary {Notes for the Properties test}
perms {network yes folders {Downloads rw} display wayland}
entries {{notes bin/notes {} app}}
effects {{desktop share/applications/notes.desktop}}
MANIFEST
		R=$PWD
		if (cd "$T/kit/src" && KIT_CONF=$T/kit/kit.conf HOME=$h tclsh8.6 "$R/$K/bin/kit" pack -q -sign "$R/$F/test-app.key" notes "$T/kit/notes.kit") >"$T/out" 2>&1; then
			kitenv="$kitenv PROPS_KIT=$T/kit/notes.kit KIT_CONF=$T/kit/kit.conf KIT_NOSYNC=1"
			# notes 2.0, published in a signed index (kitindex) on a file:// mirror and pinned (KIT_INDEX):
			# the update a held kit goes forward to (Props-A11-Held)
			sed -i 's/version 1.0/version 2.0/' "$T/kit/src/notes.manifest"
			if (cd "$T/kit/src" && KIT_CONF=$T/kit/kit.conf HOME=$h tclsh8.6 "$R/$K/bin/kit" pack -q -sign "$R/$F/test-app.key" notes "$T/kit/notes2.kit") >"$T/out" 2>&1 &&
				mkdir -p "$T/kit/repo.kits" && cp "$T/kit/notes2.kit" "$T/kit/repo.kits/" &&
				tclsh8.6 kit/kittrust/kitindex build -key "$F/test-index.key" -keys "$T/kit/keys" "$T/kit/repo.kits" "$T/kit/repo" >>"$T/out" 2>&1; then
				kitenv="$kitenv PROPS_KIT2=$T/kit/notes2.kit KIT_INDEX=$T/kit/repo/snapshots/1"
			else
				sed 's/^/       /' "$T/out"; fail "a second version of the kit in a signed index"
			fi
		else
			echo "  skip kit's grab, mend and toss: kit pack could not make a .kit ($(tail -n 1 "$T/out"))"
		fi
	else
		echo "  (kit's grab, mend and toss are skipped: they need kit's library, minisign and Mk4tcl in KITFMT_MK4TCL)"
	fi
	# shellcheck disable=SC2086
	if env PATH="$B:$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_CACHE_HOME="$T/cache" \
		PKEXEC_LOG="$T/pkexec.log" RIBBON_PROPERTIES_SCENE=tests/properties-flow.tcl $kitenv \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/properties/main.tcl" > "$T/flow.out" 2>&1 &&
		grep -qx 'flow: the end' "$T/flow.out"
	then grep -c '  ok ' "$T/flow.out" | sed 's/^/  ok   flow: /; s/$/ checks/'; grep '  skip' "$T/flow.out"
	else grep -v '  ok ' "$T/flow.out"; fail "the flow"; fi
fi

[ $fails -eq 0 ] && echo "properties: all checks passed" || echo "properties: $fails checks failed"
[ $fails -eq 0 ]
