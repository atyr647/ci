#!/bin/sh
# make build / make install / make uninstall on any base (build/install, docs/BUILDING.md "Build and install on
# any base"). In a scratch tree, as the user running the tests, with no network:
#   1. make build, then make install DESTDIR=...; a second make install changes nothing (idempotent);
#   2. each package installed alone is held to what its srcpkgs template installs (tests/install-template-tree.sh
#      runs the template's do_install with stand-ins for xbps-src's helpers; tests/install-compare.py compares path,
#      type, mode, link target and the contents of every file from this repository); the third-party files a
#      template installs are declared by the manifest, the make_dirs are its state lines, mkkitfs (which needs the
#      Metakit source) is held to its template with a stand-in binary, and make install is all packages together;
#   3. the dependencies report names every dependency each package's template declares;
#   4. every installed script parses (sh -n, bash -n, Tcl's info complete) and its #! is one of a declared set;
#   5. the Ribbon shell, Settings and the text editor start FROM THE INSTALLED TREE under xvfb: a mount namespace
#      (unshare -m as root, unshare -rm otherwise) lays DESTDIR/usr/{bin,lib,share} over /usr with a read-only
#      overlay, so /usr/lib/ribbon and /usr/share/ribbon are the installed ones and nothing on the host changes;
#      each draws its window and none says a file or package is missing;
#   6. make uninstall leaves the scratch root empty.
# A host without a C compiler, wish8.6, xvfb-run or a mount namespace skips what it cannot do and says so.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
for t in cc make python3 tclsh8.6 bash; do
	command -v "$t" >/dev/null 2>&1 || { echo "  skip install (no $t)"; exit 0; }
done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
B=$T/build D=$T/dist R=$T/root
mkdir -p "$D"
PKGS=$(for m in build/install/manifests/*.manifest; do basename "$m" .manifest; done)
# The srcpkgs templates are Void's packaging, xbps its package manager: for a build for Void make install puts down
# the xbps backend's files too (the manifests' `base xbps` lines), as the templates do; for another base it leaves
# them out (tests/base-neutral.sh checks both ways)
. tests/base.sh
PMB=none; [ "$(ribbon_base)" = void ] && PMB=xbps
# builds PACKAGE: what the manifest takes from make build; built PACKAGE: false for a `needs` package not built
builds() { grep -o ' @build/[^ ]*' "build/install/manifests/$1.manifest" | sed 's| @build/||'; }
built() {
	grep -q '^needs ' "build/install/manifests/$1.manifest" || return 0
	for b in $(builds "$1"); do [ -e "$B/$1/$b" ] || return 1; done
}

# the one third-party file make build uses, Space Grotesk, when this host has the template's exact file
want=$(grep -A1 '^checksum=' srcpkgs/ribbon-desktop/template | head -n1 | sed 's/^checksum="//')
for f in $(fc-list 2>/dev/null | cut -d: -f1 | grep -i 'spacegrotesk' || :); do
	[ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ] && { cp "$f" "$D/SpaceGrotesk-wght.ttf"; break; }
done
[ -f "$D/SpaceGrotesk-wght.ttf" ] && echo "  (Space Grotesk from this host: the template's checksum)" ||
	echo "  (no Space Grotesk on this host: the fonts are left out, as make install says)"

# ---- 1. build, install, install again
if make -s build O="$B" DISTDIR="$D" >"$T/build.out" 2>&1; then
	ok "make build"
else
	sed 's/^/       /' "$T/build.out"; fail "make build"; exit 1
fi
listing() { (cd "$1" && find . -printf '%y %m %p %l\n' | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2); }
if RIBBON_PKG_BACKEND=$PMB make -s install O="$B" DISTDIR="$D" DESTDIR="$R" PREFIX=/usr >"$T/install.out" 2>&1; then
	ok "make install DESTDIR=... PREFIX=/usr ($(find "$R" ! -type d | wc -l) files and links)"
else
	sed 's/^/       /' "$T/install.out"; fail "make install"; exit 1
fi
listing "$R" > "$T/first"
if RIBBON_PKG_BACKEND=$PMB make -s install O="$B" DISTDIR="$D" DESTDIR="$R" PREFIX=/usr >"$T/install2.out" 2>&1 && listing "$R" | cmp -s - "$T/first"; then
	ok "a second make install leaves the same tree"
else
	fail "a second make install changed the tree"
fi
if make -s install O="$B" DISTDIR="$D" DESTDIR="$T/x" PREFIX=/usr/local >/dev/null 2>&1; then
	fail "PREFIX=/usr/local was taken (the programs name /usr/lib/ribbon)"
else
	ok "PREFIX other than /usr is refused"
fi

# ---- 2. each package against its template (base-specific, tests/base.sh: the srcpkgs templates are Void's
# packaging, so only a build for Void holds a package to its template; each package is installed alone either way)
. tests/base.sh
VOID=0; base_only void "each package against its srcpkgs template" && VOID=1
for p in $PKGS; do
	o=$B
	if ! built "$p"; then
		# a package that needs the Metakit source (mkkitfs, mk4tcl) and was not built: its layout is checked with
		# stand-ins for what the build makes
		o=$T/standin; mkdir -p "$o/$p"
		for b in $(builds "$p"); do : > "$o/$p/$b"; done
	fi
	if [ "$VOID" = 1 ]; then
	if ! sh tests/install-template-tree.sh "$p" "$T/tpl-$p" "$D" >"$T/tpl-$p.out" 2>&1; then
		sed 's/^/       /' "$T/tpl-$p.out"; fail "$p: the template's do_install did not run"; continue
	fi
	td=$T/tpl-$p/destdir
	# srcpkgs/ribbon-desktop/template: vcopy of themes/Ribbon into usr/share/themes, which nothing has made yet, so
	# cp -a puts Ribbon's contents AT usr/share/themes; the manifest installs the theme where its name says
	if [ -d "$td/usr/share/themes/openbox-3" ] && [ ! -d "$td/usr/share/themes/Ribbon" ]; then
		echo "  note $p's template puts the Ribbon window theme at /usr/share/themes/openbox-3 (vcopy into a missing directory); compared as /usr/share/themes/Ribbon"
		mkdir "$T/theme" && mv "$td/usr/share/themes" "$T/theme/Ribbon" && mkdir "$td/usr/share/themes" &&
			mv "$T/theme/Ribbon" "$td/usr/share/themes/Ribbon" && rmdir "$T/theme"
		sed -i 's|^/usr/share/themes/\(openbox-3/\)|/usr/share/themes/Ribbon/\1|' "$T/tpl-$p/sources"
	fi
	fi
	RIBBON_PKG_BACKEND=$PMB O=$o DISTDIR=$D RECORD=$T/rec-$p DESTDIR=$T/one-$p sh build/install/install.sh install "$p" >/dev/null 2>"$T/one-$p.err" ||
		{ sed 's/^/       /' "$T/one-$p.err"; fail "$p: install.sh install"; continue; }
	sed -n 's/^install: [^:]*: \(\/[^ ]*\) left out .*/\1/p' "$T/one-$p.err" > "$T/left-$p"
	RIBBON_PKG_BACKEND=$PMB O=$o DISTDIR=$D sh build/install/install.sh list "$p" > "$T/list-$p" 2>/dev/null
	[ "$VOID" = 1 ] || { ok "$p installs alone"; continue; }
	if python3 tests/install-compare.py "$T/tpl-$p" "$T/one-$p" "$T/list-$p" "$T/left-$p" > "$T/cmp-$p" 2>&1; then
		ok "$p installs what its template installs ($(sed -n 's/^  compared //p' "$T/cmp-$p"))"
	else
		cat "$T/cmp-$p"; fail "$p differs from its template"
	fi
	# the state lines are the template's make_dirs
	md=$(XBPS_CROSS_BASE='' bash -c '. "$1" >/dev/null 2>&1; echo $make_dirs' _ "srcpkgs/$p/template")
	st=$(sed -n 's/^s //p' "$T/list-$p" | tr '\n' ' ' | sed 's/ $//')
	[ "$md" = "$st" ] && ok "$p: state directories = the template's make_dirs${md:+ ($md)}" ||
		fail "$p: state lines \"$st\", template make_dirs \"$md\""
done
# make install is every package together (mkkitfs only when it was built)
(for p in $PKGS; do [ -d "$T/one-$p" ] && built "$p" && (cd "$T/one-$p" && find . | sed 1d); done) | LC_ALL=C sort -u > "$T/union"
(cd "$R" && find . | sed 1d) | LC_ALL=C sort > "$T/all"
if cmp -s "$T/union" "$T/all"; then ok "make install = every package's install together"; else
	diff "$T/union" "$T/all" | head -10 | sed 's/^/       /'; fail "make install differs from the packages installed one by one"
fi

# ---- 3. the dependencies report
if [ -s "$B/dependencies.txt" ]; then
	miss=
	for p in $PKGS; do
		for n in $(XBPS_CROSS_BASE='' bash -c '. "$1" >/dev/null 2>&1; echo $depends' _ "srcpkgs/$p/template"); do
			grep -q "| void: $n\$" "$B/dependencies.txt" || miss="$miss $p:$n"
		done
	done
	[ -z "$miss" ] && ok "the dependencies report names every declared dependency" || fail "the report misses$miss"
else
	fail "make build wrote no dependencies report"
fi

# ---- 4. scripts parse; #! lines are from the declared set
SHEBANGS='#!/bin/sh|#!/bin/bash|#!/usr/bin/env tclsh|#!/usr/bin/tclsh|#!/usr/bin/env wish|#!/usr/bin/wish|#!/usr/sbin/nft -f'
nsh=0 ntcl=0
: > "$T/tcl-files"
for f in $(cd "$R" && find . -type f | LC_ALL=C sort); do
	g=$R/${f#./}
	first=$(head -c 200 "$g" | head -n1 | tr -d '\000')
	# a #!/bin/sh file that restarts itself with tclsh (the line before the exec ends in a backslash) is Tcl
	if [ "$first" = '#!/bin/sh' ] && grep -B1 -E '^exec (tclsh|wish)' "$g" | head -n1 | grep -q '\\$'; then
		echo "$g" >> "$T/tcl-files"; first=tcl-restart
	fi
	case $first in
		tcl-restart) ;;
		'#!'*)
			case "|$SHEBANGS|" in *"|$first|"*) ;; *) fail "${f#.}: #! $first is not in the declared set" ;; esac
			case $first in
				*bash*) bash -n "$g" 2>"$T/e" || { fail "${f#.} does not parse: $(head -n1 "$T/e")"; }; nsh=$((nsh + 1)) ;;
				*/sh) sh -n "$g" 2>"$T/e" || { fail "${f#.} does not parse: $(head -n1 "$T/e")"; }; nsh=$((nsh + 1)) ;;
				*tclsh* | *wish*) echo "$g" >> "$T/tcl-files" ;;
			esac ;;
		*) case $f in *.tcl) echo "$g" >> "$T/tcl-files" ;; *.sh) sh -n "$g" || fail "${f#.} does not parse"; nsh=$((nsh + 1)) ;; esac ;;
	esac
	if [ -x "$g" ] && [ "$first" != tcl-restart ] && [ "${first#\#!}" = "$first" ] && ! head -c4 "$g" | grep -q 'ELF'; then
		fail "${f#.} is executable but neither a script with #! nor a binary"
	fi
done
cat > "$T/parse.tcl" <<'TCL'
set bad 0
foreach f [split [read stdin] \n] {
	if {$f eq ""} continue
	set fh [open $f]; fconfigure $fh -encoding utf-8; set s [read $fh]; close $fh
	if {![info complete $s]} { puts "  FAIL [string range $f [string length $::env(R)] end]: Tcl braces, brackets or quotes do not close"; incr bad }
}
puts "tcl $bad"
TCL
tr=$(R=$R tclsh8.6 "$T/parse.tcl" < "$T/tcl-files")
echo "$tr" | grep '  FAIL' || :
ntcl=$(wc -l < "$T/tcl-files")
[ "$(echo "$tr" | tail -n1)" = "tcl 0" ] && [ "$nsh" -gt 0 ] && ok "$nsh shell and $ntcl Tcl scripts parse; every #! is one of: $(echo "$SHEBANGS" | tr '|' ' ')" ||
	fail "installed scripts that do not parse (above)"

# ---- 5. the shell, Settings and the editor from the installed tree
launch() {
	if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1 || ! command -v xwininfo >/dev/null 2>&1; then
		echo "  skip the apps from the installed tree (no wish8.6, xvfb-run or xwininfo)"; return 0
	fi
	if [ "$(id -u)" = 0 ]; then ns="unshare -m"; else ns="unshare -rm"; fi
	# shellcheck disable=SC2086
	if ! $ns sh -c "mount -t overlay overlay -o lowerdir=$R/usr/lib:/usr/lib /usr/lib && test -d /usr/lib/ribbon/shell" 2>/dev/null; then
		echo "  skip the apps from the installed tree (no mount namespace with overlayfs here: $ns)"; return 0
	fi
	H=$T/run
	mkdir -p "$H/home" "$H/state" "$H/cache" "$H/config" "$H/rt"
	chmod 700 "$H/rt"
	cat > "$T/apps.sh" <<'EOF'
set -e
unset TCLLIBPATH   # the Tcl packages (rbnalpha, ribbon::dbus, unix_extra) must come from the installed tree
for d in bin lib share; do mount -t overlay overlay -o "lowerdir=$R/usr/$d:/usr/$d" "/usr/$d"; done
[ -f /usr/lib/ribbon/shell/main.tcl ] && [ -d /usr/share/ribbon/xdg ] || { echo "the overlay did not take"; exit 1; }
xvfb-run -a -s "-screen 0 1440x900x24" sh -c '
	PATH=/usr/bin:/bin
	ribbon-shell >"$H/shell.log" 2>&1 & a=$!
	ribbon-settings >"$H/settings.log" 2>&1 & b=$!
	ribbon-editor >"$H/editor.log" 2>&1 & c=$!
	end=$(($(date +%s) + 40))
	while [ "$(date +%s)" -lt "$end" ]; do
		xwininfo -root -tree > "$H/tree" 2>/dev/null || :
		n=0
		for app in RibbonShellBar RibbonSettings RibbonEditor; do
			grep "\"$app\")" "$H/tree" | grep -qv " 1x1+" && n=$((n + 1))
		done
		[ "$n" = 3 ] && break
		sleep 0.5
	done
	sleep 2
	xwininfo -root -tree > "$H/tree" 2>/dev/null || :
	for p in $a $b $c; do kill -0 "$p" 2>/dev/null && echo "alive $p" || echo "dead $p"; done > "$H/alive"
	kill $a $b $c 2>/dev/null || :
	wait 2>/dev/null || :'
EOF
	# shellcheck disable=SC2086
	if ! env R="$R" H="$H" HOME=$H/home XDG_STATE_HOME=$H/state XDG_CACHE_HOME=$H/cache XDG_CONFIG_HOME=$H/config \
		XDG_RUNTIME_DIR=$H/rt timeout -k 5 120 $ns sh "$T/apps.sh" >"$T/apps.out" 2>&1; then
		sed 's/^/       /' "$T/apps.out"; fail "the installed apps did not run (unshare/overlay/xvfb)"; return 0
	fi
	for app in shell:RibbonShellBar settings:RibbonSettings editor:RibbonEditor; do
		class=${app#*:} app=${app%%:*}
		if grep "\"$class\")" "$H/tree" | grep -qv " 1x1+"; then w=1; else w=; fi
		errs=$(grep -iE "couldn't read file|no such file|can't find package|couldn't load|not found|error" "$H/$app.log" |
			grep -v 'no Wayland display' | head -n3)
		if [ -n "$w" ] && [ -z "$errs" ]; then
			ok "ribbon-$app runs from the installed tree (its window drawn, no missing file)"
		else
			[ -n "$w" ] || echo "       no ribbon-$app window (class $class)"
			sed 's/^/       /' "$H/$app.log" | head -n 20
			fail "ribbon-$app from the installed tree"
		fi
	done
	grep -q dead "$H/alive" && { sed 's/^/       /' "$H/alive"; fail "an app exited by itself"; } || ok "all three still running when stopped"
}
launch

# ---- 6. uninstall
if make -s uninstall O="$B" DISTDIR="$D" DESTDIR="$R" >"$T/un.out" 2>&1 && [ -z "$(find "$R" -mindepth 1 | head -n1)" ]; then
	ok "make uninstall removes everything it installed"
else
	sed 's/^/       /' "$T/un.out"; find "$R" -mindepth 1 | head | sed 's/^/       left: /'; fail "make uninstall"
fi

[ "$fails" = 0 ] && { echo "install: all checks passed"; exit 0; }
echo "install: $fails check(s) failed"
exit 1
