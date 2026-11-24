#!/bin/sh
# Ribbon's own package builder (build/kits/kit-build.sh, docs/RECIPES.md): a recipe and checked sources become a system
# kit, built in a sandbox. A fixture recipe (a small C program in a tarball made here) is built for real, against the
# host (KIT_BUILD_HOST=1: it names no build_needs); then every recipe in recipes/ is read. The real recipes are built in
# roots of the base set's kits, which a test run does not have (docs/RECIPES.md records where they were built).
# Skips without cc, make, bwrap, mkfs.erofs or Mk4tcl (KITFMT_MK4TCL).
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
for t in cc make bwrap mkfs.erofs tclsh8.6; do
	command -v "$t" >/dev/null 2>&1 || { echo "  skip the kit builder (no $t)"; exit 0; }
done
[ -n "${KITFMT_MK4TCL:-}" ] || { echo "  skip the kit builder (kitpack needs Mk4tcl: KITFMT_MK4TCL)"; exit 0; }
bwrap --ro-bind / / --unshare-net true 2>/dev/null || { echo "  skip the kit builder (bubblewrap cannot make a sandbox here)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
KB=$ROOT/build/kits/kit-build.sh
export SOURCE_DATE_EPOCH=1700000000 KITPACK_VERITY=no
unset KIT_SIGN KIT_BUILD_HOST KIT_SEED KIT_BOOTSTRAP KIT_BUILD_FORCE

# ---- the fixture: hello-1.0.tar.gz and its recipe ----------------------------------------------------------------
mkdir -p "$T/hello-1.0" "$T/dist" "$T/recipes/hello/patches"
cat > "$T/hello-1.0/hello.c" <<'C'
#include <stdio.h>
int main(void) { puts("hello from a kit"); return 0; }
C
# built with debug information, which the builder takes out of the kit
printf 'hello: hello.c\n\tcc -O2 -g -o hello hello.c\n' > "$T/hello-1.0/Makefile"
tar czf "$T/dist/hello-1.0.tar.gz" -C "$T" hello-1.0
sum=$(sha256sum "$T/dist/hello-1.0.tar.gz" | cut -d' ' -f1)
cat > "$T/recipes/hello/patches/0001-greeting.patch" <<'P'
--- a/hello.c
+++ b/hello.c
@@ -1,2 +1,2 @@
 #include <stdio.h>
-int main(void) { puts("hello from a kit"); return 0; }
+int main(void) { puts("hello from a patched kit"); return 0; }
P
recipe() { # the fixture's recipe, with $1 as its stage() body's extra lines
	cat > "$T/recipes/hello/recipe" <<R
name=hello
kit=org.test.hello
version=1.0
revision=3
summary="A greeting"
license="MIT"
source="https://example.invalid/hello-1.0.tar.gz"
sha256="${2:-$sum}"
srcdir="hello-1.0"
needs="org.test.libc"
build() {
	make -j"\$JOBS"
	{ echo "net: \$(sed 1,2d /proc/net/dev | cut -d: -f1 | tr -d ' ' | tr '\n' ' ')"; echo "secret: \${SECRET_TOKEN:-none}"; echo "home: \$HOME";
	  echo "roothome: \$(ls -A /root 2>/dev/null | wc -l)"; touch /usr/kit-build-test 2>/dev/null && echo "usr: writable" || echo "usr: read-only";
	  echo "destdir: \${DESTDIR:-unset}"; } > sandbox.txt
}
stage() {
	install -Dm755 hello "\$DESTDIR/usr/bin/hello"
	install -Dm644 sandbox.txt "\$DESTDIR/usr/share/hello/sandbox.txt"
	install -Dm640 "\$RECIPE/recipe" "\$DESTDIR/etc/hello.conf"
	$1
}
R
}
recipe ":"
export DISTDIR=$T/dist
if sh "$KB" "$T/recipes/hello" "$T/out0" >"$T/log" 2>&1 || ! grep -q 'hello has no build_needs' "$T/log" || ls "$T/out0/kits/"*.kit >/dev/null 2>&1; then
	bad "a recipe without build_needs was not refused: $(cat "$T/log")"
else ok "a recipe without build_needs is refused: it would be built against the host"; fi
export KIT_BUILD_HOST=1
if SECRET_TOKEN=hunter2 sh "$KB" "$T/recipes/hello" "$T/out" >"$T/log" 2>&1; then ok "a recipe builds: sources checked, unpacked, patched, built and staged"
else bad "the fixture recipe does not build"; sed 's/^/     /' "$T/log"; fi
k=$T/out/kits/org.test.hello-1.0_3.kit
[ -s "$k" ] && ok "the kit is named by the recipe's kit name and version_revision" || bad "no $k"
[ ! -e "$T/out/work" ] && ok "a build that succeeded leaves no work directory behind (the sources, the recipe's copy)" || bad "left in work: $(ls "$T/out/work" | tr '\n' ' ')"
if command -v readelf >/dev/null 2>&1; then
	if readelf -S "$T/out/trees/hello/bin/hello" 2>/dev/null | grep -q '\.debug_info'; then bad "the kit's program keeps its debug information"
	elif readelf -s "$T/out/trees/hello/bin/hello" 2>/dev/null | grep -q ' main$'; then ok "the program was built with -g and the kit holds it without debug information, its symbols kept"
	else bad "the kit's program lost its symbols too: $(readelf -s "$T/out/trees/hello/bin/hello" 2>&1 | tail -3)"; fi
fi
[ "$("$T/out/trees/hello/bin/hello" 2>&1)" = "hello from a patched kit" ] && ok "the program in the staged /usr runs, and it was built from the patched source" || bad "the staged program: $("$T/out/trees/hello/bin/hello" 2>&1)"
m=$(cat "$T/out/src/hello.manifest" 2>/dev/null)
case $m in *"name org.test.hello  version 1.0_3  kind system"*"x-short hello"*"needs {{org.test.libc {}}}"*) ok "the manifest: a system kit, the recipe's name as its short name, its needs" ;; *) bad "manifest: $m" ;; esac
s=$(cat "$T/out/trees/hello/share/hello/sandbox.txt" 2>/dev/null)
case $s in *"net: lo "*) ok "the build had no network (only lo)" ;; *) bad "network in the build: $s" ;; esac
case $s in *"secret: none"*) ok "the caller's environment did not reach the build" ;; *) bad "environment leaked: $s" ;; esac
case $s in *"home: /run/build/home"*"roothome: 0"*"usr: read-only"*) ok "the caller's home is hidden, the system is read-only, and the work directory is /run/build whatever it is outside" ;; *) bad "sandbox: $s" ;; esac
[ ! -e /usr/kit-build-test ] || { bad "the build wrote into /usr"; rm -f /usr/kit-build-test; }
case $s in *"destdir: unset"*) ok "build() does not see DESTDIR (stage() does): a build cannot compile the staging directory in" ;; *) bad "DESTDIR in build(): $s" ;; esac
d=$T/out/trees/hello/share/ribbon/defaults/hello/etc/hello.conf
{ [ -f "$d" ] && [ "$(stat -c %a "$d")" = 640 ] && [ ! -e "$T/out/trees/hello/etc" ]; } && ok "what the recipe stages outside /usr travels as a default, mode kept" || bad "defaults: $(find "$T/out/trees/hello" | head -20)"
grep -q "^source hello-1.0.tar.gz $sum$" "$T/out/src/hello.buildinfo" && grep -q '^root host$' "$T/out/src/hello.buildinfo" && grep -q '^sandbox bwrap$' "$T/out/src/hello.buildinfo" && grep -q '^recipe [0-9a-f]\{64\}$' "$T/out/src/hello.buildinfo" &&
	ok "the build's record names the sources' hashes, the recipe's, the sandbox, and that it was built against the host" || bad "buildinfo: $(cat "$T/out/src/hello.buildinfo" 2>&1)"
cp "$T/out/images/hello.erofs" "$T/first.erofs"
sh "$KB" "$T/recipes/hello" "$T/out2" >"$T/log" 2>&1
cmp -s "$T/first.erofs" "$T/out2/images/hello.erofs" && ok "a second build makes the same image, byte for byte" || bad "the image is not reproducible"
# a new version replaces the old kit in OUT/kits (one kit per recipe: the kernel's 6.18.63 stayed beside 6.18.64)
sed -i 's/^revision=3$/revision=4/' "$T/recipes/hello/recipe"
sh "$KB" "$T/recipes/hello" "$T/out2" >"$T/log" 2>&1
[ -f "$T/out2/kits/org.test.hello-1.0_4.kit" ] && [ ! -e "$T/out2/kits/org.test.hello-1.0_3.kit" ] &&
	ok "a recipe's new version replaces its old kit in OUT/kits" || bad "after a new revision: $(ls "$T/out2/kits" | tr '\n' ' ')"
sed -i 's/^revision=4$/revision=3/' "$T/recipes/hello/recipe"
# a file the recipe links to from outside its directory (as the kernel's links to build/kernel/config) reaches the build
echo "linked in" > "$T/elsewhere.txt"; ln -s ../../elsewhere.txt "$T/recipes/hello/elsewhere.txt"
recipe 'install -Dm644 "$RECIPE/elsewhere.txt" "$DESTDIR/usr/share/hello/elsewhere.txt"'
if sh "$KB" "$T/recipes/hello" "$T/out8" >"$T/log" 2>&1 && [ "$(cat "$T/out8/trees/hello/share/hello/elsewhere.txt" 2>&1)" = "linked in" ]; then
	ok "a file the recipe links to from outside its directory is there in the sandbox"
else bad "a linked file: $(tail -5 "$T/log")"; fi
rm "$T/recipes/hello/elsewhere.txt"

# ---- refusals ----------------------------------------------------------------------------------------------------
recipe ":" "$(printf '%064d' 0)"
if sh "$KB" "$T/recipes/hello" "$T/out3" >"$T/log" 2>&1 || [ -e "$T/out3/work/hello/src/hello-1.0" ] || ! grep -q 'is not the file the recipe names' "$T/log"; then
	bad "a source that is not the recipe's was not refused before unpacking: $(cat "$T/log")"
else ok "a source with another sha256 is refused, and nothing of it is unpacked"; fi
recipe 'install -Dm755 hello "$DESTDIR/bin/hello"'
if sh "$KB" "$T/recipes/hello" "$T/out4" >"$T/log" 2>&1 || ! grep -q 'stages /bin' "$T/log" || ls "$T/out4/kits/"*.kit >/dev/null 2>&1; then bad "a recipe staging /bin was not refused: $(tail -3 "$T/log")"
else ok "a recipe that stages /bin is refused (a recipe installs into /usr)"; fi
recipe 'printf appended >> "$DESTDIR/usr/bin/hello"'
if sh "$KB" "$T/recipes/hello" "$T/out9" >"$T/log" 2>&1 || ! grep -q '/usr/bin/hello carries 8 bytes after its ELF contents' "$T/log"; then
	bad "a program with bytes appended was not refused: $(tail -3 "$T/log")"
else ok "a program that carries bytes after its ELF contents (an appended archive) is refused: stripping would take them off"; fi
recipe 'echo "$DESTDIR/usr/share/hello" > "$DESTDIR/usr/share/hello/where"'
if sh "$KB" "$T/recipes/hello" "$T/out10" >"$T/log" 2>&1 || ! grep -q '/usr/share/hello/where  *name the staging directory' "$T/log"; then
	bad "a file naming the staging directory was not refused: $(tail -3 "$T/log")"
else ok "a file that names the staging directory is refused"; fi
recipe 'exit 7'
if sh "$KB" "$T/recipes/hello" "$T/out5" >"$T/log" 2>&1 || ls "$T/out5/kits/"*.kit >/dev/null 2>&1; then bad "a failing stage made a kit"; else ok "a failing build makes no kit"; fi
recipe ":"; mv "$T/recipes/hello" "$T/recipes/other"
if sh "$KB" "$T/recipes/other" "$T/out6" >"$T/log" 2>&1; then bad "a recipe in a directory of another name was built"; else ok "a recipe's name is its directory's"; fi
rm -f "$T/dist/hello-1.0.tar.gz"; mv "$T/recipes/other" "$T/recipes/hello"
if sh "$KB" "$T/recipes/hello" "$T/out7" >"$T/log" 2>&1 || ! grep -q 'is not in' "$T/log"; then bad "a missing source: $(cat "$T/log")"; else ok "a missing source is said; the build itself never downloads"; fi

# ---- the real recipes ---------------------------------------------------------------------------------------------
n=0
for r in recipes/*/; do
	if sh "$KB" --info "$r" >"$T/info" 2>&1 && grep -q '^kit [a-z0-9.-]*$' "$T/info"; then n=$((n + 1)); else bad "$r: $(cat "$T/info")"; fi
done
[ "$n" -ge 4 ] && ok "every recipe in recipes/ reads ($n)" || bad "only $n recipes read"
# no kit name twice, and none of Ribbon's own
dup=$(for r in recipes/*/; do sh "$KB" --info "$r" | sed -n 's/^kit //p'; done | sort | uniq -d)
[ -z "$dup" ] && ok "no two recipes make one kit" || bad "kit names twice: $dup"
exit $fail
