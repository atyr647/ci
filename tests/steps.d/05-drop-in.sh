#!/bin/sh
# Drop-in apps (C1): the apps loop of ribbon-desktop's template, run as the packager runs it. The block
# between the apps:begin and apps:end markers runs under sh -e (xbps-src's do_install) against a fixture
# apps tree, with stand-ins for xbps-src's vinstall and vbin. Each file lands where the layout says, the
# files that are not part of a layout stay out, and a template without an apps folder is not an error.
# Base-specific (tests/base.sh): it runs only when the build is for Void.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tests/base.sh
base_only void "drop-in apps (the template's do_install under xbps-src stand-ins)" || exit 0
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

block=$T/block.sh
sed -n '/# apps:begin/,/# apps:end/p' srcpkgs/ribbon-desktop/template > "$block"
if [ "$(grep -c '# apps:begin' srcpkgs/ribbon-desktop/template)" = 1 ] && [ -s "$block" ]; then
	ok "the template has one apps block"
else
	fail "the template has no single apps:begin/apps:end block"; exit 1
fi

# the fixture: two apps, one with every kind of file and one stray file that is not an app folder
F=$T/files
mkdir -p "$F/apps/probe/bin" "$F/apps/probe/applications" "$F/apps/probe/policy" "$F/apps/probe2"
echo 'puts probe' > "$F/apps/probe/main.tcl"
echo 'puts util' > "$F/apps/probe/util.tcl"
echo 'exec wish8.6 probe' > "$F/apps/probe/bin/ribbon-probe"
echo '[Desktop Entry]' > "$F/apps/probe/applications/ribbon-probe.desktop"
echo '<policyconfig/>' > "$F/apps/probe/policy/ribbon-probe.policy"
echo 'polkit.addRule' > "$F/apps/probe/policy/ribbon-probe.rules"
echo 'puts two' > "$F/apps/probe2/main.tcl"
echo 'not installed' > "$F/apps/probe2/notes.txt"
echo 'stray' > "$F/apps/stray.txt"

run_block() { # FILESDIR DESTDIR: the block under sh -e, with stand-ins for vinstall and vbin
	FILESDIR=$1 DESTDIR=$2 sh -e -c '
vinstall() { _vd="$DESTDIR/$3"; mkdir -p "$_vd"; _vn=${4:-$(basename "$1")}; cp "$1" "$_vd/$_vn" && chmod "$2" "$_vd/$_vn"; }
vbin() { vinstall "$1" 755 usr/bin; }
. "$0"' "$block"
}

D=$T/dest
if run_block "$F" "$D" 2>"$T/err"; then ok "the apps block runs under sh -e"; else fail "the apps block failed: $(cat "$T/err")"; fi

for p in usr/lib/ribbon/probe/main.tcl usr/lib/ribbon/probe/util.tcl usr/lib/ribbon/probe2/main.tcl \
	usr/share/applications/ribbon-probe.desktop usr/share/polkit-1/actions/ribbon-probe.policy \
	usr/share/polkit-1/rules.d/ribbon-probe.rules; do
	if [ -f "$D/$p" ]; then ok "installed $p"; else fail "not installed: $p"; fi
done
if [ -x "$D/usr/bin/ribbon-probe" ]; then ok "bin/* goes to usr/bin, executable"; else fail "usr/bin/ribbon-probe missing or not executable"; fi
if [ ! -e "$D/usr/lib/ribbon/probe2/notes.txt" ] && [ ! -e "$D/usr/lib/ribbon/apps" ]; then
	ok "files outside the layout are not installed"
else
	fail "a file outside the layout was installed"
fi

# a template with no apps folder: nothing to do, no error
if run_block "$T/none" "$T/dest2" 2>"$T/err" && [ ! -e "$T/dest2" ]; then
	ok "no apps folder: nothing installed, no error"
else
	fail "no apps folder is an error: $(cat "$T/err")"
fi

[ "$fails" -eq 0 ] || { echo "drop-in: $fails failure(s)"; exit 1; }
