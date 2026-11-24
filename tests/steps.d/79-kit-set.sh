#!/bin/sh
# A set of recipes built in order, and builds in a root made only of kits (build/kits/kit-set.sh, kit-build.sh's
# build_needs; docs/RECIPES.md). Three fixture recipes named against the alphabet: z-base (built on the host: a shell
# and its libraries, standing in for a bootstrap's first stage), m-tool (built in a root of z-base alone) and a-app
# (built in a root of m-tool and what it needs). Skips without bwrap, busybox, mkfs.erofs or Mk4tcl (KITFMT_MK4TCL).
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
for t in bwrap busybox mkfs.erofs tclsh8.6 tsort ldd; do
	command -v "$t" >/dev/null 2>&1 || { echo "  skip the kit set (no $t)"; exit 0; }
done
[ -n "${KITFMT_MK4TCL:-}" ] || { echo "  skip the kit set (kitpack needs Mk4tcl: KITFMT_MK4TCL)"; exit 0; }
bwrap --ro-bind / / --unshare-net true 2>/dev/null || { echo "  skip the kit set (bubblewrap cannot make a sandbox here)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
KS=$ROOT/build/kits/kit-set.sh
export SOURCE_DATE_EPOCH=1700000000 KITPACK_VERITY=no DISTDIR=$T/dist
unset KIT_SIGN KIT_SET_KEEP_GOING KIT_BUILD_FORCE KIT_SEED KIT_BOOTSTRAP
# z-base names no build_needs: it is built against the host, which kit-build.sh does only when told to
export KIT_BUILD_HOST=1
mkdir -p "$T/dist" "$T/r/z-base" "$T/r/m-tool" "$T/r/a-app"
head() { printf 'name=%s\nkit=%s\nversion=1\nrevision=%s\nsummary="%s"\nlicense="MIT"\n' "$1" "$2" "${3:-1}" "$1"; }
base() { # REVISION
	{ head z-base org.test.base "$1"; cat <<'R'
stage() {
	# a shell and the libraries it loads, into a merged /usr: all a later build's root has
	mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/lib"
	cp "$(command -v busybox)" "$DESTDIR/usr/bin/busybox"
	for a in sh ls cat echo mkdir cp chmod sed tr wc find head; do ln -s busybox "$DESTDIR/usr/bin/$a"; done
	ldd "$(command -v busybox)" | sed -n 's/.*[[:space:]]\(\/[^ ]*\) (0x.*/\1/p' | while read -r l; do cp -L "$l" "$DESTDIR/usr/lib/"; done
}
R
	} > "$T/r/z-base/recipe"
}
base 1
{ head m-tool org.test.tool; cat <<'R'
needs="org.test.base"
build_needs="org.test.base"
build() {
	{ echo "bin: $(ls /usr/bin | tr '\n' ' ')"; echo "etc: $(ls -A /etc | wc -l)"; echo "path: $PATH";
	  [ -e /usr/bin/cc ] || [ -e /usr/bin/python3 ] || [ -e /usr/include ] && echo "host: seen" || echo "host: none"; } > root.txt
}
stage() {
	mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/share/tool"
	printf '#!/bin/sh\necho "made by tool: $1"\n' > "$DESTDIR/usr/bin/tool"; chmod 755 "$DESTDIR/usr/bin/tool"
	cp root.txt "$DESTDIR/usr/share/tool/root.txt"
}
R
} > "$T/r/m-tool/recipe"
{ head a-app org.test.app; cat <<'R'
needs="org.test.tool org.test.missing"
build_needs="org.test.tool"
build() { tool app > made.txt; ls /usr/bin | tr '\n' ' ' > bin.txt; }
stage() { mkdir -p "$DESTDIR/usr/share/app"; cp made.txt bin.txt "$DESTDIR/usr/share/app/"; }
R
} > "$T/r/a-app/recipe"
# m-tool and a-app are made with nothing but the kits' shell: srcdir is the empty source directory
O=$T/out
if sh "$KS" "$O" "$T/r" >"$T/log" 2>&1; then ok "three recipes that need each other build as a set"; else bad "the set does not build"; sed 's/^/     /' "$T/log"; fi
order=$(grep -o 'kit-build: org.test.[a-z]*' "$T/log" | sed 's/.*test\.//' | tr '\n' ' ')
[ "$order" = "base tool app " ] && ok "in the order they need each other (base, tool, app), not the alphabet's" || bad "order: $order"
r=$(cat "$O/trees/m-tool/share/tool/root.txt" 2>/dev/null)
case $r in *"bin: busybox cat chmod cp echo find head ls mkdir sed sh tr wc "*"etc: 0"*"path: /usr/bin"*"host: none"*) ok "m-tool was built in a root that is z-base's kit and nothing else: no compiler, no /etc, nothing of the host" ;; *) bad "m-tool's root: $r" ;; esac
[ "$(cat "$O/trees/a-app/share/app/made.txt" 2>/dev/null)" = "made by tool: app" ] && ok "a-app's build ran the tool from m-tool's kit" || bad "a-app: $(cat "$O/trees/a-app/share/app/made.txt" 2>&1)"
case $(cat "$O/trees/a-app/share/app/bin.txt" 2>/dev/null) in *busybox*tool*) ok "  and its root held what m-tool needs too (z-base), though the recipe names only m-tool" ;; *) bad "a-app's root: $(cat "$O/trees/a-app/share/app/bin.txt" 2>&1)" ;; esac
grep -q '^root kits m-tool:[0-9a-f]\{64\} z-base:[0-9a-f]\{64\}$' "$O/src/a-app.buildinfo" && grep -q '^root host$' "$O/src/z-base.buildinfo" && ! grep -q '^cc ' "$O/src/a-app.buildinfo" &&
	ok "each build's record says what its root was: the host for z-base, the kits and their images' hashes for a-app" || bad "records: $(cat "$O/src/a-app.buildinfo" "$O/src/z-base.buildinfo" 2>&1)"
[ "$(cut -f1 "$O/kits.txt" | sort | tr '\n' ' ')" = "org.test.app org.test.base org.test.tool " ] && [ "$(cat "$O/unmet.txt")" = "org.test.app	org.test.missing" ] &&
	ok "kits.txt lists the set, unmet.txt the run-time need no kit meets" || bad "kits.txt: $(cat "$O/kits.txt"); unmet: $(cat "$O/unmet.txt")"

# nothing changed: nothing is built again; the base changes: what was built in it is built again
sh "$KS" "$O" "$T/r" >"$T/log" 2>&1
[ "$(grep -c 'is up to date' "$T/log")" = 3 ] && ok "a second run builds nothing: every kit is up to date" || bad "second run: $(cat "$T/log")"
base 2
sh "$KS" "$O" "$T/r" >"$T/log" 2>&1
{ grep -q 'org.test.base 1_2 ->' "$T/log" && grep -q 'org.test.tool 1_1 ->' "$T/log" && grep -q 'org.test.app 1_1 ->' "$T/log"; } &&
	ok "a new z-base rebuilds m-tool and a-app: their roots changed" || bad "after the base changed: $(cat "$T/log")"

# ---- refusals -------------------------------------------------------------------------------------------------------
mkdir "$T/r2"; cp -r "$T/r/m-tool" "$T/r2/"
if sh "$KS" "$T/o2" "$T/r2" >"$T/log" 2>&1 || ! grep -q 'm-tool needs org.test.base to build: no recipe' "$T/log"; then bad "a build need nothing provides: $(cat "$T/log")"; else ok "a build need that no recipe and no kit provides is refused before anything is built"; fi
cp -r "$T/r/z-base" "$T/r2/"; sed -i 's/^stage()/build_needs="org.test.tool"\nstage()/' "$T/r2/z-base/recipe"
if sh "$KS" "$T/o2" "$T/r2" >"$T/log" 2>&1 || ! grep -q 'in a circle' "$T/log" || [ -d "$T/o2/kits" ]; then bad "a circle: $(cat "$T/log")"; else ok "recipes that need each other in a circle are refused"; fi
mkdir -p "$T/r3/one" "$T/r3/two"
for n in one two; do { head $n org.test.$n; echo 'stage() { mkdir -p "$DESTDIR/usr/share"; echo x > "$DESTDIR/usr/share/same"; }'; } > "$T/r3/$n/recipe"; done
if sh "$KS" "$T/o3" "$T/r3" >"$T/log" 2>&1 || ! grep -q '/usr/share/same: one two' "$T/log"; then bad "a clash in the set: $(cat "$T/log")"; else ok "two kits of the set that bring one path are refused, the path named"; fi
sed -i 's/kit=org.test.two/kit=org.test.one/' "$T/r3/two/recipe"
if sh "$KS" "$T/o4" "$T/r3" >"$T/log" 2>&1 || ! grep -q 'both make the kit org.test.one' "$T/log"; then bad "one kit from two recipes: $(cat "$T/log")"; else ok "two recipes that make one kit are refused"; fi
# keep going: a failed recipe takes with it what needs it to build, the rest is built, the exit status says so
mkdir "$T/r5"; cp -r "$T/r/z-base" "$T/r/m-tool" "$T/r/a-app" "$T/r5/"; mkdir "$T/r5/solo"
{ head solo org.test.solo; echo 'stage() { mkdir -p "$DESTDIR/usr/share/solo"; echo x > "$DESTDIR/usr/share/solo/x"; }'; } > "$T/r5/solo/recipe"
sed -i 's/^stage() {$/stage() {\n\texit 9/' "$T/r5/m-tool/recipe"
KIT_SET_KEEP_GOING=1 sh "$KS" "$T/o5" "$T/r5" >"$T/log" 2>&1; rc=$?
{ [ $rc != 0 ] && grep -q 'a-app left out: it needs m-tool to build' "$T/log" && [ -f "$T/o5/kits/org.test.solo-1_1.kit" ] && [ -f "$T/o5/kits/org.test.base-1_2.kit" ] && [ ! -e "$T/o5/kits/org.test.app-1_1.kit" ]; } &&
	ok "keep going: the failed recipe and what needs it are left out and said, the others are built, exit 1" || bad "keep going (rc $rc): $(cat "$T/log")"
if sh "$KS" "$T/o6" "$T/r5" >"$T/log" 2>&1 || [ -e "$T/o6/kits/org.test.app-1_1.kit" ]; then bad "without keep going a failure did not stop the set"; else ok "without it the first failure stops the set"; fi
exit $fail
