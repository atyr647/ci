#!/bin/sh
# kit-publish.sh -- the publishing routine of docs/KIT-TRUST.md section 5, run as CI would run it, with the
# test-only keys of tests/fixtures/kittrust standing in for the real ones:
#   the root ceremony    Ribbon's key list org.ribbon.main, three roots, any two sign (T1 B)
#   every build          kit pack of a Ribbon app (ribbon-desktop's Notes), then kitseal with the app key
#   every publish        kitindex build with the index key, into a repository directory
#   a client             Ribbon's repository file (repos.d/org.ribbon.main.conf: url, keys) and nothing
#                        in kit.conf but repos =; kit find and kit grab install Notes from the file:// mirror
# plus another publisher's repository beside Ribbon's (T7 A): its app kit, a .kit file, installs with
# kit grab FILE once its repository file is there, and is refused (exit 4) without it.
# Needs minisign and Mk4tcl (KITFMT_MK4TCL=<dir>); skips without them.
set -u
cd "$(dirname "$0")/.." || exit 1
R=$PWD
F=$R/tests/fixtures/kittrust
KT=$R/kit/kittrust
KIT=$R/srcpkgs/ribbon-kit/files/bin/kit
status=0
ok() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; status=1; }
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v minisign >/dev/null 2>&1 ||
	! echo 'exit [catch {package require Mk4tcl}]' | TCLLIBPATH="${KITFMT_MK4TCL:-}" tclsh8.6 >/dev/null 2>&1; then
	echo "  skip publishing kits (needs tclsh8.6, minisign and Mk4tcl: KITFMT_MK4TCL=<dir>)"
	exit 0
fi
# a system-wide Mk4tcl passes the check above with KITFMT_MK4TCL unset (set -u)
KITFMT_MK4TCL=${KITFMT_MK4TCL:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export KIT_NOSYNC=1
unset KIT_INDEX XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME 2>/dev/null || :
step() { # step DESC CMD... : run, keep the output, fail with it shown
	d=$1; shift
	if "$@" >"$T/out" 2>&1; then return 0; fi
	sed 's/^/       /' "$T/out"; fail "$d"; return 1
}

# ---- the root ceremony (once, offline): three roots, any two sign ----------------------------------
L=$T/ceremony/trusted-keys
mkdir -p "$T/ceremony"
step "kitkey init: Ribbon's key list with three roots, threshold 2" \
	tclsh8.6 "$KT/kitkey" init -repository org.ribbon.main -root "$F/test-root.pub" -root "$F/test-root2.pub" \
	-root "$F/test-root3.pub" -threshold 2 "$L" &&
	step "kitkey add: the app and index keys" tclsh8.6 "$KT/kitkey" add -role app -name ribbon-app "$L" "$F/test-app.pub" &&
	step "kitkey add: the index key" tclsh8.6 "$KT/kitkey" add -role index "$L" "$F/test-index.pub" &&
	step "kitkey sign: two of the three roots" tclsh8.6 "$KT/kitkey" sign -key "$F/test-root.key" -key "$F/test-root3.key" "$L" &&
	ok "the root ceremony: org.ribbon.main, signed by two of its three roots"
if tclsh8.6 "$KT/kitkey" check "$L" >"$T/out" 2>&1; then ok "kitkey check: the list meets its threshold"; else
	sed 's/^/       /' "$T/out"; fail "kitkey check"; fi

# ---- every build: pack a Ribbon app, seal it with the app key ---------------------------------------
S=$T/src
mkdir -p "$S/notes/lib/ribbon/apps" "$S/notes/bin" "$S/notes/share/applications" "$T/kits"
cp -R srcpkgs/ribbon-desktop/files/apps/notes "$S/notes/lib/ribbon/apps/notes"
printf '#!/bin/sh\nexec wish8.6 "$(dirname "$0")/../lib/ribbon/apps/notes/main.tcl" "$@"\n' >"$S/notes/bin/ribbon-notes"
chmod 755 "$S/notes/bin/ribbon-notes"
cp srcpkgs/ribbon-desktop/files/apps/notes/applications/ribbon-notes.desktop "$S/notes/share/applications/"
cat >"$S/notes.manifest" <<'MANIFEST'
name org.ribbon.notes version 1.0 kind app short notes summary {Ribbon Notes}
perms {display wayland}
entries {{ribbon-notes bin/ribbon-notes {} app}}
effects {{desktop share/applications/ribbon-notes.desktop}}
MANIFEST
if (cd "$S" && HOME=$T/packer tclsh8.6 "$KIT" pack -q notes "$T/kits/notes.kit") >"$T/out" 2>&1; then ok "kit pack: Ribbon Notes as a kit"
else sed 's/^/       /' "$T/out"; fail "kit pack notes"; fi
step "kitseal: the app key seals it" tclsh8.6 "$KT/kitseal" -key "$F/test-app.key" -keys "$L" "$T/kits/notes.kit" &&
	ok "kitseal: sealed with the app key"

# ---- every publish: the index -----------------------------------------------------------------------
REPO=$T/www/ribbon
step "kitindex build" tclsh8.6 "$KT/kitindex" build -key "$F/test-index.key" -keys "$L" -mk4tcl "$KITFMT_MK4TCL" "$T/kits" "$REPO" &&
	ok "kitindex build: the repository (index, keys, manifests, chunks)"
[ -f "$REPO/index.minisig" ] && cmp -s "$REPO/keys" "$L" && ok "the repository carries the key list clients update from" ||
	fail "the repository's index signature or key list"

# ---- a client: Ribbon's repository file, nothing else ----------------------------------------------
C=$T/client
mkdir -p "$C/etc/kit/repos.d" "$C/home"
cp "$L" "$C/etc/kit/trusted-keys"; cp "$L.minisig" "$C/etc/kit/trusted-keys.minisig"
# what ribbon-kit ships, with the url the owner's hosting will give
sed "s|^keys = /etc/kit/trusted-keys|url = file://$REPO\nkeys = $C/etc/kit/trusted-keys|" \
	srcpkgs/ribbon-kit/files/etc/kit/repos.d/org.ribbon.main.conf >"$C/etc/kit/repos.d/org.ribbon.main.conf"
printf 'repos = %s\ntimeout = 5\n' "$C/etc/kit/repos.d" >"$C/kit.conf"
kit() { HOME=$C/home KIT_CONF=$C/kit.conf TCLLIBPATH=$KITFMT_MK4TCL timeout -k 5 120 tclsh8.6 "$KIT" "$@"; }
if kit find notes >"$T/out" 2>&1 && grep -q '^  notes  *1\.0  *Ribbon Notes$' "$T/out"; then ok "kit find: Notes, from the mirror the repository file names"
else sed 's/^/       /' "$T/out"; fail "kit find notes"; fi
if echo y | kit grab notes >"$T/out" 2>&1 && kit list >"$T/list" 2>&1 && grep -q 'notes' "$T/list"; then ok "kit grab notes: installed from the signed index"
else sed 's/^/       /' "$T/out" "$T/list"; fail "kit grab notes"; fi
# kit keeps the .kit file itself (store/<root>/kit, served by mkkitfs): read Notes back out of it
installed=$(find "$C/home/.local/share/kit/store" -name kit -type f 2>/dev/null | head -n1)
if [ -n "$installed" ] && TCLLIBPATH=$KITFMT_MK4TCL tclsh8.6 /dev/stdin "$R/kit/kitfmt/kitfmt.tcl" "$installed" \
	srcpkgs/ribbon-desktop/files/apps/notes/main.tcl >"$T/out" 2>&1 <<'TCL'
lassign $argv kf kit want
source $kf
set h [kitfmt open $kit -signed 0]
set got [kitfmt read $h lib/ribbon/apps/notes/main.tcl]
set f [open $want rb] ; set exp [read $f] ; close $f
exit [expr {$got eq $exp ? 0 : 1}]
TCL
then ok "  the installed kit holds Notes as it is in the tree"
else sed 's/^/       /' "$T/out"; fail "the installed Notes (${installed:-no kit in the store})"; fi

# ---- another publisher's repository beside Ribbon's (T7 A) -----------------------------------------
X=$C/etc/kit/repos.d/com.example.apps.keys
step "kitkey: the other publisher's list" tclsh8.6 "$KT/kitkey" init -repository com.example.apps -root "$F/test-root2.pub" "$X" &&
	step "kitkey add" tclsh8.6 "$KT/kitkey" add -role app "$X" "$F/test-other.pub" &&
	step "kitkey sign" tclsh8.6 "$KT/kitkey" sign -key "$F/test-root2.key" "$X"
mkdir -p "$S/hello/bin"
printf '#!/bin/sh\necho hello\n' >"$S/hello/bin/hello"; chmod 755 "$S/hello/bin/hello"
printf 'name com.example.hello version 2.0 kind app short hello summary {Hello from another publisher}\nentries {{hello bin/hello {} app}}\n' >"$S/hello.manifest"
if (cd "$S" && HOME=$T/packer tclsh8.6 "$KIT" pack -q -sign "$F/test-other.key" hello "$T/hello.kit") >"$T/out" 2>&1; then :
else sed 's/^/       /' "$T/out"; fail "kit pack hello"; fi
if echo y | kit grab "$T/hello.kit" >"$T/out" 2>&1; then
	sed 's/^/       /' "$T/out"; fail "a kit by a key of no repository file must be refused"
else
	rc=$?; [ $rc -eq 4 ] && ok "without its repository file, the other publisher's kit is refused (exit 4)" ||
		{ sed 's/^/       /' "$T/out"; fail "kit grab hello.kit without its repository: exit $rc, not 4"; }
fi
printf 'url = https://kits.example.com/apps\n' >"$C/etc/kit/repos.d/com.example.apps.conf"
if echo y | kit grab "$T/hello.kit" >"$T/out" 2>&1 && kit list >"$T/list" 2>&1 && grep -q 'hello' "$T/list"; then
	ok "with com.example.apps.conf (its own roots), kit grab hello.kit installs it"
else sed 's/^/       /' "$T/out" "$T/list"; fail "kit grab hello.kit with its repository"; fi
[ -f "$C/home/.local/share/kit/repos/com.example.apps/keys/anchor" ] && ok "  its list is anchored in its own state directory" ||
	fail "the other repository's anchor in data/repos/com.example.apps/keys"
exit $status
