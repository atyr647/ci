#!/bin/sh
# The base set built in stages (build/kits/bootstrap.sh; kit-build.sh's KIT_BOOTSTRAP and KIT_SEED; docs/RECIPES.md, "The
# bootstrap"), with fixture recipes: a stand-in made on the host (busybox as a shell, a program that loads the C library,
# the libraries they load), and a base set of two recipes that need each other and themselves to build, sh and tool.
# Then what kit-build.sh holds a kit built in a root of kits to: the libraries its programs load.
# Skips without bwrap, busybox, mkfs.erofs, readelf or Mk4tcl (KITFMT_MK4TCL).
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
for t in bwrap busybox mkfs.erofs tclsh8.6 tsort ldd readelf cmp; do
	command -v "$t" >/dev/null 2>&1 || { echo "  skip the kit stages (no $t)"; exit 0; }
done
[ -n "${KITFMT_MK4TCL:-}" ] || { echo "  skip the kit stages (kitpack needs Mk4tcl: KITFMT_MK4TCL)"; exit 0; }
bwrap --ro-bind / / --unshare-net true 2>/dev/null || { echo "  skip the kit stages (bubblewrap cannot make a sandbox here)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
KB=$ROOT/build/kits/kit-build.sh
KS=$ROOT/build/kits/kit-set.sh
BS=$ROOT/build/kits/bootstrap.sh
export SOURCE_DATE_EPOCH=1700000000 KITPACK_VERITY=no DISTDIR=$T/dist RECIPES=$T/r
unset KIT_SIGN KIT_SET_KEEP_GOING KIT_BUILD_FORCE KIT_SEED KIT_BOOTSTRAP KIT_BOOTSTRAP_BUILT KIT_BUILD_HOST
mkdir -p "$T/dist" "$T/r/bootstrap" "$T/r/sh" "$T/r/tool" "$T/r/app"
head() { printf 'name=%s\nkit=%s\nversion=1\nrevision=1\nsummary="%s"\nlicense="MIT"\n' "$1" "$2" "$1"; }
{ head bootstrap org.test.bootstrap; cat <<'R'
stage() {
	mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/lib" "$DESTDIR/usr/share"
	cp "$(command -v busybox)" "$DESTDIR/usr/bin/busybox"
	cp "$(command -v env)" "$DESTDIR/usr/bin/dyn"
	for a in sh ls cat echo mkdir cp chmod sed tr wc find head ln; do ln -s busybox "$DESTDIR/usr/bin/$a"; done
	for p in busybox env; do ldd "$(command -v $p)" | sed -n 's/.*[[:space:]]\(\/[^ ]*\) (0x.*/\1/p'; done | while read -r l; do cp -L "$l" "$DESTDIR/usr/lib/"; done
	echo stand-in > "$DESTDIR/usr/share/who"
	# a strip that does nothing (the kits built in this root hold busybox, which has no debug information to take out),
	# as a binutils not built for deterministic archives would: it refuses to be run without -D, which would write the
	# moment of the strip into an archive
	printf '#!/bin/sh\ncase " $* " in *" -D "*) exit 0 ;; esac\necho "strip: run without -D" >&2; exit 1\n' > "$DESTDIR/usr/bin/strip"
	chmod 755 "$DESTDIR/usr/bin/strip"
	echo stand-in > "$DESTDIR/usr/share/only-stand-in"
}
R
} > "$T/r/bootstrap/recipe"
# sh: the root's own shell and libraries, as a kit; it brings the paths the stand-in holds
{ head sh org.test.sh; cat <<'R'
build_needs="org.test.sh org.test.tool"
stage() {
	mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/lib" "$DESTDIR/usr/share"
	cp /usr/bin/busybox /usr/bin/dyn /usr/bin/strip "$DESTDIR/usr/bin/"
	for a in sh ls cat echo mkdir cp chmod sed tr wc find head ln; do ln -s busybox "$DESTDIR/usr/bin/$a"; done
	cp /usr/lib/*.so* "$DESTDIR/usr/lib/"
	echo kit > "$DESTDIR/usr/share/who"
}
R
} > "$T/r/sh/recipe"
# tool: says what its root was
{ head tool org.test.tool; cat <<'R'
needs="org.test.sh"
build_needs="org.test.sh org.test.tool"
build() {
	{ echo "who: $(cat /usr/share/who)"; echo "share: $(ls /usr/share | tr '\n' ' ')"; echo "path: $PATH"; echo "cflags: $CFLAGS"; } > root.txt
}
stage() {
	mkdir -p "$DESTDIR/usr/share/tool"
	cp root.txt "$DESTDIR/usr/share/tool/root.txt"
}
R
} > "$T/r/tool/recipe"
printf '# the fixture base set\nsh\ntool\n' > "$T/r/BASE"
{ head app org.test.app; cat <<'R'
needs="org.test.sh"
build_needs="org.test.sh"
stage() { mkdir -p "$DESTDIR/usr/share/app"; ls /usr/share | tr '\n' ' ' > "$DESTDIR/usr/share/app/share.txt"; }
R
} > "$T/r/app/recipe"

# ---- the three stages ---------------------------------------------------------------------------------------------
O=$T/out
if sh "$BS" "$O" >"$T/log" 2>&1; then ok "a base set whose two recipes need each other and themselves to build is built, in three stages"; else bad "bootstrap.sh: $(cat "$T/log")"; fi
S=$O/bootstrap
grep -q '^root host$' "$S/stage0/src/bootstrap.buildinfo" 2>/dev/null && ok "stage 0: the stand-in is built against the host, and its record says so" || bad "stage 0's record: $(cat "$S/stage0/src/bootstrap.buildinfo" 2>&1)"
# stage 1: sh first, with nothing of the set built (the stand-in stands in for both needs); tool then with sh laid over
grep -q '^root bootstrap bootstrap:[0-9a-f]\{64\}$' "$S/stage1/src/sh.buildinfo" 2>/dev/null && grep -q '^standin org.test.sh org.test.tool$' "$S/stage1/src/sh.buildinfo" &&
	ok "stage 1: sh is built in the stand-in alone; its record names the stand-in's image and the needs it stood in for" || bad "stage 1 sh: $(cat "$S/stage1/src/sh.buildinfo" 2>&1)"
grep -q '^root bootstrap bootstrap:[0-9a-f]\{64\} under kits sh:[0-9a-f]\{64\}$' "$S/stage1/src/tool.buildinfo" 2>/dev/null && grep -q '^standin org.test.tool$' "$S/stage1/src/tool.buildinfo" &&
	ok "  tool is built in the stand-in with sh's kit laid over it (and never its own, from an earlier run)" || bad "stage 1 tool: $(cat "$S/stage1/src/tool.buildinfo" 2>&1)"
r=$(cat "$S/stage1/trees/tool/share/tool/root.txt" 2>/dev/null)
case $r in *"who: kit"*"share: only-stand-in who "*"path: /usr/bin"*) ok "  there the kit's file took the place of the stand-in's (the one place a second bringer of a path is let in), and the stand-in's other files were still there" ;; *) bad "stage 1 tool's root: $r" ;; esac
case $r in *"cflags: -O2"*) ok "  the build was given the builder's compiler flags (-O2, no debug information)" ;; *) bad "flags: $r" ;; esac
# stage 2: roots of stage 1's kits alone
r=$(cat "$S/stage2/trees/tool/share/tool/root.txt" 2>/dev/null)
case $r in *"who: kit"*"share: tool who "*) ok "stage 2: tool is built in a root of stage 1's kits alone: nothing of the stand-in is in it" ;; *) bad "stage 2 tool's root: $r" ;; esac
grep -q '^root kits sh:[0-9a-f]\{64\} tool:[0-9a-f]\{64\}$' "$S/stage2/src/tool.buildinfo" 2>/dev/null && grep -q "^seed $S/stage1\$" "$S/stage2/src/tool.buildinfo" &&
	ok "  its record names the kits, their images and the stage they came from" || bad "stage 2 tool: $(cat "$S/stage2/src/tool.buildinfo" 2>&1)"
h1=$(sha256sum "$S/stage1/images/sh.erofs" | cut -c1-64)
grep -q "sh:$h1" "$S/stage2/src/tool.buildinfo" 2>/dev/null && ok "  and they are stage 1's own images" || bad "stage 2's root is not stage 1's sh"
# stage 3 is the set
{ [ -f "$O/kits/org.test.sh-1_1.kit" ] && [ -f "$O/kits/org.test.tool-1_1.kit" ] && grep -q "^seed $S/stage2\$" "$O/src/tool.buildinfo" && [ ! -e "$O/kits/org.test.bootstrap-1_1.kit" ]; } &&
	ok "stage 3, built in roots of stage 2's kits, is the set in OUT; the stand-in is not among its kits" || bad "stage 3: $(ls "$O/kits" 2>&1)"
[ "$(cat "$S/same.txt" 2>/dev/null | tr '\n' ' ')" = "sh tool " ] && [ ! -s "$S/differ.txt" ] && cmp -s "$S/stage2/images/tool.erofs" "$O/images/tool.erofs" &&
	ok "  and both kits came out the same, byte for byte, as the stage before made them (same.txt)" || bad "same: $(cat "$S/same.txt" 2>&1); differ: $(cat "$S/differ.txt" 2>&1)"
cmp -s "$S/stage1/images/tool.erofs" "$S/stage2/images/tool.erofs" && bad "stage 1's tool equals stage 2's, though its root held the stand-in" || ok "  (stage 1's tool is not: its root was another)"
sh "$BS" "$O" >"$T/log" 2>&1
[ "$(grep -c "is up to date" "$T/log")" = 7 ] && ok "a second run builds nothing: the stand-in and every stage's kits are up to date" || bad "second run: $(cat "$T/log")"
sh "$BS" "$T/o1" 1 >"$T/log" 2>&1
{ [ -d "$T/o1/bootstrap/stage1/kits" ] && [ ! -e "$T/o1/bootstrap/stage2" ] && [ ! -e "$T/o1/kits" ]; } && ok "bootstrap.sh OUT 1 stops after stage 1" || bad "stop after stage 1: $(cat "$T/log")"

# ---- the set beside the others --------------------------------------------------------------------------------------
if sh "$KS" "$O" "$T/r" >"$T/log" 2>&1 && grep -q 'kit-build: org.test.app 1_1 ->' "$T/log" && ! grep -q 'org.test.sh\|org.test.tool\|org.test.bootstrap' "$T/log"; then
	ok "kit-set.sh leaves the base set and the stand-in to bootstrap.sh and builds the other recipes"
else bad "kit-set with a base set: $(cat "$T/log")"; fi
[ "$(cat "$O/trees/app/share/app/share.txt" 2>/dev/null)" = "who " ] && ok "  each in a root of the base set's kits (app's holds sh, which it names, and nothing else)" || bad "app's root: $(cat "$O/trees/app/share/app/share.txt" 2>&1)"
if sh "$KS" "$T/o2" "$T/r" sh tool >"$T/log" 2>&1 || ! grep -q 'in a circle' "$T/log"; then bad "the base set, named, without a seed: $(cat "$T/log")"; else ok "named without a stage to take its needs from, the set is the circle it is: refused"; fi
if KIT_SEED=$S/stage1 sh "$KS" "$T/o2" "$T/r" sh tool >"$T/log" 2>&1 && cmp -s "$T/o2/images/tool.erofs" "$S/stage2/images/tool.erofs"; then
	ok "with KIT_SEED kit-set.sh builds it: needs that come from an earlier stage give no order (and the kits are stage 2's, byte for byte)"
else bad "kit-set with KIT_SEED: $(cat "$T/log")"; fi

# ---- refusals ---------------------------------------------------------------------------------------------------------
if KIT_SEED=$S/stage0 sh "$KB" "$T/r/tool" "$T/o3" >"$T/log" 2>&1 || ! grep -q "needs org.test.sh to build, and $S/stage0 holds no such kit" "$T/log"; then bad "a seed without the need: $(cat "$T/log")"; else ok "KIT_SEED: a build need the seed does not hold is refused (nothing stands in for it)"; fi
if KIT_SEED=$O sh "$KB" "$T/r/tool" "$O" >"$T/log" 2>&1 || ! grep -q 'a directory of its own' "$T/log"; then bad "a stage built into its own seed: $(cat "$T/log")"; else ok "a stage is not built into the directory it is built from"; fi
if KIT_SEED=$S/stage1 KIT_BOOTSTRAP=$S/stage0 sh "$KB" "$T/r/tool" "$T/o3" >"$T/log" 2>&1 || ! grep -q 'one at a time' "$T/log"; then bad "seed and stand-in together: $(cat "$T/log")"; else ok "KIT_SEED and KIT_BOOTSTRAP together are refused"; fi
if KIT_BOOTSTRAP=$T/dist sh "$KB" "$T/r/tool" "$T/o3" >"$T/log" 2>&1 || ! grep -q 'holds no built stand-in' "$T/log"; then bad "an empty stand-in: $(cat "$T/log")"; else ok "KIT_BOOTSTRAP: a directory with no built stand-in is refused"; fi
# over the stand-in two KITS still may not bring one path
mkdir -p "$T/r/dup" "$T/r/both"
{ head dup org.test.dup; echo 'build_needs="org.test.sh"'; echo 'stage() { mkdir -p "$DESTDIR/usr/share"; echo dup > "$DESTDIR/usr/share/who"; }'; } > "$T/r/dup/recipe"
{ head both org.test.both; echo 'build_needs="org.test.sh org.test.dup"'; echo 'stage() { mkdir -p "$DESTDIR/usr/share/both"; echo x > "$DESTDIR/usr/share/both/x"; }'; } > "$T/r/both/recipe"
KIT_BOOTSTRAP=$S/stage0 KIT_BOOTSTRAP_BUILT="sh tool" sh "$KB" "$T/r/dup" "$S/stage1" >"$T/log" 2>&1 || bad "dup did not build: $(cat "$T/log")"
if KIT_BOOTSTRAP=$S/stage0 KIT_BOOTSTRAP_BUILT="sh tool dup" sh "$KB" "$T/r/both" "$S/stage1" >"$T/log" 2>&1 || ! grep -q 'brings /usr/share/who, which another kit of the root holds' "$T/log"; then bad "two kits with one path over the stand-in: $(cat "$T/log")"; else ok "over the stand-in, two kits that bring one path are still refused"; fi

# ---- a kit is held to the libraries its needs bring ---------------------------------------------------------------------
mkdir -p "$T/r/prog"
prog() { # NEEDS
	{ head prog org.test.prog; echo "needs=\"$1\""; echo 'build_needs="org.test.sh"'
	  echo 'stage() { mkdir -p "$DESTDIR/usr/bin"; cp /usr/bin/dyn "$DESTDIR/usr/bin/prog"; }'; } > "$T/r/prog/recipe"
}
prog ""
if sh "$KB" "$T/r/prog" "$O" >"$T/log" 2>&1 || ! grep -q '/usr/bin/prog: loads libc.so.6' "$T/log" || [ -e "$O/kits/org.test.prog-1_1.kit" ]; then bad "a program whose library no need brings: $(cat "$T/log")"
else ok "a kit with a program that loads a library neither it nor a kit it needs holds is refused, the file and the library named"; fi
prog "org.test.sh"
if sh "$KB" "$T/r/prog" "$O" >"$T/log" 2>&1; then ok "with the need named (the kit that holds the library) it builds"; else bad "the same with its need: $(cat "$T/log")"; fi
{ head prog org.test.prog; echo 'needs="org.test.sh"'; echo 'build_needs="org.test.sh"'
  echo 'stage() { mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/sbin"; cp /usr/bin/dyn "$DESTDIR/usr/sbin/prog"; }'; } > "$T/r/prog/recipe"
if sh "$KB" "$T/r/prog" "$O" >"$T/log" 2>&1 || ! grep -q 'stages /usr/sbin: programs go to /usr/bin' "$T/log"; then bad "a recipe that stages /usr/sbin: $(cat "$T/log")"; else ok "a recipe that stages /usr/sbin is refused (one directory for programs; likewise /usr/lib64)"; fi
mkdir -p "$T/r/nostrip"
{ head nostrip org.test.nostrip; echo 'needs="org.test.tool"'; echo 'build_needs="org.test.tool"'
  echo 'stage() { mkdir -p "$DESTDIR/usr/bin"; cp /usr/bin/dyn "$DESTDIR/usr/bin/nostrip"; }'; } > "$T/r/nostrip/recipe"
# a root of tool and what it needs (sh): sh brings strip; with it taken out, the program cannot be stripped
cp -a "$O" "$T/o-nostrip"; rm -f "$T/o-nostrip/trees/sh/bin/strip"
if sh "$KB" "$T/r/nostrip" "$T/o-nostrip" >"$T/log" 2>&1 || ! grep -q '/usr/bin/nostrip is a program or library, and the build root has no strip' "$T/log"; then bad "a program in a root without strip: $(cat "$T/log")"
else ok "a kit with a program, built in a root without strip, is refused: it could not be stripped"; fi
cp -a "$O" "$T/o-nofind"; rm -f "$T/o-nofind/trees/sh/bin/find"
if sh "$KB" "$T/r/nostrip" "$T/o-nofind" >"$T/log" 2>&1 || ! grep -q 'the build root has no find' "$T/log"; then bad "a root without find: $(cat "$T/log")"
else ok "  and so is any kit built in a root without find or head, which the search for programs needs (it would find nothing, and say nothing)"; fi
exit $fail
