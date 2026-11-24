#!/bin/sh
# kit-build.sh - build one upstream package as a system kit from a Ribbon recipe (docs/RECIPES.md). Ribbon's own
# builder: no xbps-src, no Void container. One kit per upstream package (decision 82).
#
#   build/kits/kit-build.sh RECIPE-DIR OUT       build recipes/NAME -> OUT/kits/KIT-VERSION.kit
#   build/kits/kit-build.sh --fetch RECIPE-DIR   download the recipe's sources into DISTDIR (checked; a refusal is final)
#   build/kits/kit-build.sh --info RECIPE-DIR    the recipe's fields, one per line
#
# The sources are taken from DISTDIR (default out/distfiles) by their file names and held to the recipe's sha256
# before a byte is unpacked; the build never downloads. build and stage run in a bubblewrap sandbox: no network, the
# system read-only, the caller's home folders hidden, an environment made here (PATH, HOME, LC_ALL=C, TZ=UTC,
# SOURCE_DATE_EPOCH), and only the work directory writable, always at /run/build (the recipe at /run/recipe: a copy with
# its links followed, so a recipe may link to files elsewhere in the repository). KIT_BUILD_SANDBOX=none builds without it (said in the
# build's record). What stage puts outside /usr travels as defaults (decision 126); /bin, /sbin, /lib and /lib64 are
# refused (Ribbon's /usr is merged: a recipe installs into /usr).
#
# OUT/kits/KIT-VERSION.kit, OUT/trees/NAME (the staged /usr), OUT/images/NAME.erofs, OUT/src/NAME.manifest and
# OUT/src/NAME.buildinfo (the recipe's and sources' hashes, the sandbox, the compiler: what made this kit).
# A recipe is built in a root made of the kits its build_needs name (their trees in OUT), nothing of the host. One
# without build_needs is refused, unless KIT_BUILD_HOST=1: then it is built against this machine's own system and its
# record says `root host` (the bootstrap's stand-in, recipes/bootstrap, is built so).
# A build whose inputs are all the same as the last one's (the key in its record) is not done again (KIT_BUILD_FORCE=1 does).
# Two more ways to make that root, for the base set, whose recipes need each other in a circle (build/kits/bootstrap.sh):
#   KIT_SEED=DIR        the build needs are taken from DIR, the OUT of an earlier stage, not from OUT
#   KIT_BOOTSTRAP=DIR   the root is the stand-in system built in DIR (recipes/bootstrap) with, laid over it, those of the
#                       build needs that KIT_BOOTSTRAP_BUILT names (the recipes of OUT built before this one in this
#                       stage); a need it does not name is left to the stand-in. Only over the stand-in may a kit
#                       bring a path that is already there.
# Environment: DISTDIR, KITFMT_MK4TCL, KIT_SIGN, KITPACK_VERITY, SOURCE_DATE_EPOCH, JOBS, KIT_BUILD_SANDBOX, KIT_BUILD_FORCE,
# KIT_BUILD_HOST, KIT_SEED, KIT_BOOTSTRAP, KIT_BOOTSTRAP_BUILT.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "kit-build: $*" >&2; exit 1; }
mode=build
case ${1:-} in --fetch) mode=fetch; shift ;; --info) mode=info; shift ;; esac
[ $# -ge 1 ] || die "usage: kit-build.sh [--fetch|--info] RECIPE-DIR [OUT]"
RD=$(cd "$1" 2>/dev/null && pwd) || die "no recipe directory $1"
R=$RD/recipe
[ -f "$R" ] || die "no $R"
DISTDIR=${DISTDIR:-$ROOT/out/distfiles}
case $DISTDIR in /*) ;; *) DISTDIR=$PWD/$DISTDIR ;; esac

# the recipe's fields, read in a shell of their own (a recipe is shell: assignments and two functions)
field() { (set +eu; name=; kit=; version=; revision=; summary=; license=; source=; sha256=; srcdir=; needs=; build_needs=
	# shellcheck disable=SC1090
	. "$R" >/dev/null 2>&1; eval "printf '%s\n' \"\$$1\"") | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }
name=$(field name); kit=$(field kit); version=$(field version); revision=$(field revision)
summary=$(field summary); license=$(field license); source=$(field source); sha256=$(field sha256)
srcdir=$(field srcdir); needs=$(field needs); build_needs=$(field build_needs)
for f in name kit version revision summary license; do
	eval "[ -n \"\$$f\" ]" || die "$R: no $f"
done
[ "$name" = "$(basename "$RD")" ] || die "$R: name=$name, but the recipe is in $(basename "$RD")"
echo "$name" | grep -Eq '^[a-z0-9][a-z0-9+._-]*$' || die "$R: name '$name' (lowercase letters, digits, + . _ -)"
echo "$kit" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || die "$R: kit '$kit' is not a reverse-DNS kit name"
echo "$version" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z.+~-]*$' || die "$R: version '$version'"
echo "$revision" | grep -Eq '^[1-9][0-9]*$' || die "$R: revision '$revision'"
[ "$(echo "$source" | wc -w)" = "$(echo "$sha256" | wc -w)" ] || die "$R: one sha256 per source"
for h in $sha256; do echo "$h" | grep -Eq '^[0-9a-f]{64}$' || die "$R: '$h' is not a sha256"; done
ver=${version}_$revision

if [ "$mode" = info ]; then
	printf 'name %s\nkit %s\nversion %s\nsummary %s\nlicense %s\nneeds %s\nbuild_needs %s\nsource %s\n' "$name" "$kit" "$ver" "$summary" "$license" "$needs" "$build_needs" "$source"
	exit 0
fi

# check SOURCE-FILE HASH
check() { [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }
if [ "$mode" = fetch ]; then
	mkdir -p "$DISTDIR"
	# shellcheck disable=SC2086
	set -- $sha256
	for u in $source; do
		h=$1; shift
		f=$DISTDIR/$(basename "$u")
		if [ -f "$f" ] && check "$f" "$h"; then echo "kit-build: $(basename "$f") is there"; continue; fi
		case $u in https://*) ;; *) die "$u: sources are fetched over https only" ;; esac
		curl -fsSL --proto '=https' --max-time 600 -o "$f.part" "$u" || { rm -f "$f.part"; die "$u could not be fetched (not tried another way)"; }
		check "$f.part" "$h" || { rm -f "$f.part"; die "$u is not the file the recipe names (sha256)"; }
		mv "$f.part" "$f"
		echo "kit-build: fetched $(basename "$f")"
	done
	exit 0
fi

[ $# -eq 2 ] || die "usage: kit-build.sh RECIPE-DIR OUT"
[ -n "${KITFMT_MK4TCL:-}" ] || die "KITFMT_MK4TCL (a built Mk4tcl) is needed: kitpack writes the kit with it"
command -v mkfs.erofs >/dev/null 2>&1 || die "no mkfs.erofs (erofs-utils)"
TCLSH=$(command -v tclsh || command -v tclsh8.6) || die "no tclsh"; export TCLSH
sandbox=${KIT_BUILD_SANDBOX:-bwrap}
case $sandbox in
bwrap) command -v bwrap >/dev/null 2>&1 || die "no bwrap (bubblewrap): the build runs in a sandbox (KIT_BUILD_SANDBOX=none builds without)" ;;
none) ;;
*) die "KIT_BUILD_SANDBOX=$sandbox: bwrap or none" ;;
esac
mkdir -p "$2"; OUT=$(cd "$2" && pwd)
cd "$ROOT"
. build/kits/lib.sh
W=$OUT/work/$name
mkdir -p "$OUT/trees" "$OUT/images" "$OUT/kits" "$OUT/src"

# ---- the build root ---------------------------------------------------------------------------------------------
# A recipe with build_needs is built in a root made of exactly those kits and what they need (their trees in OUT, from
# earlier builds): nothing of the host is in it. One without is built against the host's own system only when asked
# (KIT_BUILD_HOST=1: the bootstrap's stand-in), and the record says so: a kit built so links what the host has, and
# would be missing it on a Ribbon machine.
seed=; boot=
if [ -n "${KIT_SEED:-}" ]; then seed=$(cd "$KIT_SEED" 2>/dev/null && pwd) || die "KIT_SEED: no directory $KIT_SEED"; fi
if [ -n "${KIT_BOOTSTRAP:-}" ]; then boot=$(cd "$KIT_BOOTSTRAP" 2>/dev/null && pwd) || die "KIT_BOOTSTRAP: no directory $KIT_BOOTSTRAP"; fi
if [ -n "$seed" ] && [ -n "$boot" ]; then die "KIT_SEED and KIT_BOOTSTRAP are two different stages: one at a time"; fi
if [ "$seed" = "$OUT" ] || [ "$boot" = "$OUT" ]; then die "a stage is built into a directory of its own, not into the one it is built from"; fi
NS=${seed:-$OUT}	# where the build needs' kits are
tree_of() { # KIT-NAME -> the tree's name in NS (its manifest names the kit)
	for _m in "$NS"/src/*.manifest; do
		[ -f "$_m" ] || continue
		if grep -q "^name $1  *version " "$_m"; then basename "$_m" .manifest; return 0; fi
	done
	return 1
}
needs_of() { sed -n 's/^needs //p' "$NS/src/$1.manifest" | tr '{}' '  ' | tr ' ' '\n' | grep -E '^[a-z0-9-]+(\.[a-z0-9-]+)+$' || :; }
roottrees=; boottrees=; standin=
if [ -n "$boot" ]; then
	for _m in "$boot"/src/*.manifest; do
		[ -f "$_m" ] || continue
		_t=$(basename "$_m" .manifest)
		if [ -d "$boot/trees/$_t" ] && [ -f "$boot/images/$_t.erofs" ]; then boottrees="$boottrees $_t"; fi
	done
	[ -n "$boottrees" ] || die "KIT_BOOTSTRAP: $boot holds no built stand-in (build/kits/bootstrap.sh builds recipes/bootstrap there)"
	[ -n "$build_needs" ] || die "$name has no build_needs: with KIT_BOOTSTRAP a recipe says what it is built with"
fi
if [ -z "$build_needs" ] && [ -z "${KIT_BUILD_HOST:-}" ]; then
	die "$name has no build_needs: a kit is built in a root of the kits it names (KIT_BUILD_HOST=1 builds it against this machine's own system, as the bootstrap's stand-in is)"
fi
if [ -n "$build_needs" ]; then
	[ "$sandbox" = bwrap ] || die "$name has build_needs: a root made of kits needs the sandbox"
	todo=$build_needs
	while :; do
		# shellcheck disable=SC2086
		set -- $todo
		[ $# -gt 0 ] || break
		k=$1; shift; todo=$*
		t=$(tree_of "$k") || t=
		# over the stand-in, a kit that was not built before this one in this stage is the stand-in's to replace
		# (whatever an earlier run left in OUT: the root is the same on every run)
		if [ -n "$boot" ]; then
			case " ${KIT_BOOTSTRAP_BUILT:-} " in *" ${t:-/} "*) ;; *) t= ;; esac
			if [ -z "$t" ] || [ "$t" = "$name" ]; then case " $standin " in *" $k "*) ;; *) standin="$standin $k" ;; esac; continue; fi
		fi
		if [ -z "$t" ]; then
			die "$name needs $k to build, and $NS holds no such kit (build it first: kit-set.sh orders a set)"
		fi
		case " $roottrees " in *" $t "*) continue ;; esac
		if [ ! -d "$NS/trees/$t" ] || [ ! -f "$NS/images/$t.erofs" ]; then die "$k ($t) is not built in $NS"; fi
		roottrees="$roottrees $t"
		todo="$todo $(needs_of "$t" | tr '\n' ' ')"
	done
	roottrees=$(echo "$roottrees" | tr ' ' '\n' | grep . | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
fi

# ---- the key: everything that goes into this build; the same key and a kit that is there is a build already done ----
rhash=$(cd "$RD" && find -L . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
standin=$(echo "$standin" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/^ *//; s/ *$//')
rootline=host
[ -z "$roottrees" ] || rootline="kits$(for t in $roottrees; do printf ' %s:%s' "$t" "$(sha256sum "$NS/images/$t.erofs" | cut -c1-64)"; done)"
if [ -n "$boot" ]; then
	rootline="bootstrap$(for t in $boottrees; do printf ' %s:%s' "$t" "$(sha256sum "$boot/images/$t.erofs" | cut -c1-64)"; done) under ${rootline#host}"
	rootline="${rootline% under }"
fi
flags="-O2"
key=$(printf '%s\n' "kit-build 5" "$flags" "$rhash" "$sha256" "$sandbox" "$rootline" "${SOURCE_DATE_EPOCH:-0}" | sha256sum | cut -d' ' -f1)
if [ -z "${KIT_BUILD_FORCE:-}" ] && [ -f "$OUT/kits/$kit-$ver.kit" ] && grep -qx "key $key" "$OUT/src/$name.buildinfo" 2>/dev/null; then
	echo "kit-build: $kit $ver is up to date"
	exit 0
fi
RC=$OUT/work/$name.recipe
prev=$(sed -n '1s/^kit //p' "$OUT/src/$name.buildinfo" 2>/dev/null || :)	# the kit this recipe made last: "KIT VERSION"
rm -rf "$W" "$RC" "$OUT/trees/$name"
mkdir -p "$W/src" "$W/dest" "$W/home"

# ---- sources: checked, then unpacked ---------------------------------------------------------------------------
# shellcheck disable=SC2086
set -- $sha256
for u in $source; do
	h=$1; shift
	f=$DISTDIR/$(basename "$u")
	[ -f "$f" ] || die "$(basename "$f") is not in $DISTDIR (kit-build.sh --fetch $RD)"
	check "$f" "$h" || die "$f is not the file the recipe names (sha256 $(sha256sum "$f" | cut -d' ' -f1), the recipe has $h)"
	case $f in
	*.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar.zst|*.tar) tar xf "$f" -C "$W/src" --no-same-owner || die "$f does not unpack" ;;
	*.zip) (mkdir -p "$W/src/$(basename "$f" .zip)" && cd "$W/src/$(basename "$f" .zip)" && unzip -q "$f") || die "$f does not unpack" ;;
	*) cp "$f" "$W/src/" ;;
	esac
done
S=$W/src${srcdir:+/$srcdir}
[ -d "$S" ] || die "the sources hold no $srcdir (srcdir)"
for p in "$RD"/patches/*.patch; do
	[ -f "$p" ] || continue
	patch -s -d "$S" -p1 < "$p" || die "$(basename "$p") does not apply"
done
# what the sandbox sees at /run/recipe: the recipe's directory with its links followed (the key hashed it so: find -L)
cp -RL "$RD" "$RC" || die "the recipe's directory cannot be copied (a link that leads nowhere?)"

# ---- build and stage, sandboxed ---------------------------------------------------------------------------------
# in the sandbox the work directory is /run/build and the recipe /run/recipe, whatever they are outside: a path that ends up
# in a built file (debug information, __FILE__) is the same on every machine
if [ "$sandbox" = bwrap ]; then B=/run/build; RR=/run/recipe; else B=$W; RR=$RD; fi
cat > "$W/run" <<RUN
set -eu
build() { :; }
stage() { echo "the recipe has no stage()" >&2; exit 1; }
. "$RR/recipe"
cd "$B/src${srcdir:+/$srcdir}"
# DESTDIR is stage()'s alone: a build that sees it can compile it in (Tcl's Makefile takes its INSTALL_ROOT from it)
kit_dest=\$DESTDIR; unset DESTDIR
build
DESTDIR=\$kit_dest; export DESTDIR
cd "$B/src${srcdir:+/$srcdir}"
stage
RUN
cat > "$W/strip" <<RUN
set -eu
# no debug information in a kit (decision 137): every ELF file and archive is stripped of it with the root's own strip,
# symbols kept (a backtrace still names functions), and an archive written with no times, owners or modes in it (-D:
# a binutils not built for deterministic archives writes the moment of the strip into every archive it touches)
for t in find head; do
	command -v "\$t" >/dev/null 2>&1 || { echo "kit-build: the build root has no \$t: the kit cannot be searched for programs to strip" >&2; exit 1; }
done
elf=\$(printf '\\177ELF')
find "\$DESTDIR" -type f | while IFS= read -r f; do
	if [ "\$(head -c 4 "\$f")" = "\$elf" ] || [ "\$(head -c 7 "\$f")" = '!<arch>' ]; then
		command -v strip >/dev/null 2>&1 || { echo "kit-build: \${f#\$DESTDIR} is a program or library, and the build root has no strip (binutils)" >&2; exit 1; }
		[ -w "\$f" ] || chmod u+w "\$f"
		strip --strip-debug -D "\$f" || { echo "kit-build: strip refused \${f#\$DESTDIR}" >&2; exit 1; }
	fi
done
RUN
failed() { tail -n 60 "$W/build.log" >&2; die "$name: the build failed (log: $W/build.log)"; }
# between stage and strip, outside the sandbox (with this machine's readelf): an ELF file that carries bytes after its
# contents (an archive appended to it, as Tcl's zipfs does with its script library) would lose them to strip, and the
# kit would be broken without a word
appended() {
	_m=$(find "$W/dest" -type f | while IFS= read -r f; do
		[ "$(head -c 4 "$f")" = "$(printf '\177ELF')" ] || continue
		# shellcheck disable=SC2046
		set -- $(readelf -h "$f" 2>/dev/null | awk -F: '/Start of section headers/ { s = $2 } /Size of section headers/ { z = $2 }
			/Number of section headers/ { n = $2 } END { print s + 0, z + 0, n + 0 }')
		[ "${1:-0}" -gt 0 ] || continue
		_end=$(($1 + $2 * $3)); _size=$(wc -c < "$f")
		if [ "$_size" -gt "$_end" ]; then echo "${f#"$W/dest"} carries $((_size - _end)) bytes after its ELF contents"; break; fi
	done)
	[ -z "$_m" ] || die "$name: $_m (an archive appended to it?), which stripping would take off"
}
command -v readelf >/dev/null 2>&1 || die "no readelf (binutils): a kit's programs are read with it before they are stripped"
path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
[ -z "$roottrees$boottrees" ] || path=/usr/bin
envs="PATH=$path HOME=$B/home LC_ALL=C TZ=UTC
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0} DESTDIR=$B/dest JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)} RECIPE=$RR
CFLAGS=$flags CXXFLAGS=$flags"
if [ -n "$roottrees$boottrees" ]; then
	# the root: the kits' trees laid into one /usr (hard links; a path two kits bring stops the build, as it stops kitd),
	# the merged-/usr links, and nothing else
	mkdir -p "$W/root/usr"
	for t in $roottrees; do
		clash=$(cd "$NS/trees/$t" && find . ! -type d | while IFS= read -r f; do
			if [ -e "$W/root/usr/$f" ] || [ -L "$W/root/usr/$f" ]; then echo "/usr/${f#./}"; break; fi; done)
		[ -z "$clash" ] || die "the build root: $t brings $clash, which another kit of the root holds"
		cp -a --link "$NS/trees/$t/." "$W/root/usr/" 2>/dev/null || cp -a "$NS/trees/$t/." "$W/root/usr/" || die "cannot lay $t into the build root"
	done
	if [ -n "$boottrees" ]; then
		# the stand-in underneath: its files first, then the kits' over them (a kit's file takes the place of the stand-in's)
		mv "$W/root/usr" "$W/root/kits"; mkdir "$W/root/usr"
		for t in $boottrees; do
			cp -a --link "$boot/trees/$t/." "$W/root/usr/" 2>/dev/null || cp -a "$boot/trees/$t/." "$W/root/usr/" || die "cannot lay the stand-in $t into the build root"
		done
		cp -a --link --remove-destination "$W/root/kits/." "$W/root/usr/" 2>"$W/lay.err" || cp -a --remove-destination "$W/root/kits/." "$W/root/usr/" 2>"$W/lay.err" ||
			die "the build root: a kit and the stand-in hold one path as a directory in one and a file in the other: $(head -n1 "$W/lay.err")"
		rm -rf "$W/root/kits" "$W/lay.err"
	fi
	mkdir -p "$W/root/usr/bin" "$W/root/usr/lib"
	set -- --ro-bind "$W/root/usr" /usr --symlink usr/bin /bin --symlink usr/bin /sbin --symlink usr/lib /lib \
		--symlink usr/lib /lib64 --dir /etc --dev /dev --proc /proc --tmpfs /tmp --tmpfs /run \
		--ro-bind "$RC" /run/recipe --bind "$W" /run/build --unshare-net --unshare-ipc --unshare-pid --unshare-uts \
		--die-with-parent --new-session --clearenv
	for e in $envs; do set -- "$@" --setenv "${e%%=*}" "${e#*=}"; done
	bwrap "$@" /bin/sh /run/build/run >"$W/build.log" 2>&1 || failed
	appended
	bwrap "$@" /bin/sh /run/build/strip >>"$W/build.log" 2>&1 || failed
	rm -rf "$W/root"
elif [ "$sandbox" = bwrap ]; then
	set -- --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /root --tmpfs /home --tmpfs /run \
		--ro-bind "$RC" /run/recipe --bind "$W" /run/build --unshare-net --unshare-ipc --unshare-pid --unshare-uts \
		--die-with-parent --new-session --clearenv
	for e in $envs; do set -- "$@" --setenv "${e%%=*}" "${e#*=}"; done
	bwrap "$@" /bin/sh /run/build/run >"$W/build.log" 2>&1 || failed
	appended
	bwrap "$@" /bin/sh /run/build/strip >>"$W/build.log" 2>&1 || failed
else
	# shellcheck disable=SC2086
	env -i $envs /bin/sh "$W/run" >"$W/build.log" 2>&1 || failed
	appended
	# shellcheck disable=SC2086
	env -i $envs /bin/sh "$W/strip" >>"$W/build.log" 2>&1 || failed
fi

# ---- the tree -----------------------------------------------------------------------------------------------------
for d in bin sbin lib lib64 usr/local; do
	if [ -e "$W/dest/$d" ] || [ -L "$W/dest/$d" ]; then die "$name stages /$d: a recipe installs into /usr (Ribbon's /usr is merged)"; fi
done
# one directory for programs and one for libraries: /sbin and /lib64 are links to /usr/bin and /usr/lib, so a kit's
# /usr/sbin or /usr/lib64 would be a second place nothing looks in
for d in sbin lib64 lib32 libx32; do
	if [ -e "$W/dest/usr/$d" ] || [ -L "$W/dest/usr/$d" ]; then die "$name stages /usr/$d: programs go to /usr/bin, libraries to /usr/lib"; fi
done
[ -d "$W/dest/usr" ] || die "$name staged nothing into /usr"
mv "$W/dest/usr" "$OUT/trees/$name"
kit_defaults "$W/dest" "$OUT/trees/$name" "$name" > "$OUT/src/$name.outside"
find "$OUT/trees/$name" -name '*.la' -type f -delete
[ -n "$(find "$OUT/trees/$name" ! -type d | head -n1)" ] || die "$name staged no file"
# the staging directory is nowhere on a machine: a file or link that names it is a build that kept DESTDIR
leak=$( { grep -rlF -- "$B/dest" "$OUT/trees/$name" 2>/dev/null; find "$OUT/trees/$name" -type l -lname "$B/dest*"; } | head -n 3 | sed "s|^$OUT/trees/$name|/usr|" | tr '\n' ' ')
[ -z "$leak" ] || die "$name: $leak name the staging directory $B/dest, which is nowhere on a machine"

# ---- what its programs load -------------------------------------------------------------------------------------
# Built in a root of kits, a kit's programs and libraries may load only libraries that are the kit's own or in a kit
# it says it needs (and those kits' needs), and name the one loader: a library the build found in its root and no
# need names would be missing on a machine, and nothing would say so until the program ran. (Over the stand-in the
# needs are not all built yet, and against the host there is nothing to hold a kit to: not checked there.)
if [ -n "$roottrees" ] && [ -z "$boottrees" ]; then
	command -v readelf >/dev/null 2>&1 || die "no readelf (binutils): a kit's libraries are held to its needs with it"
	have=$OUT/trees/$name
	todo=$needs; seen=
	while :; do
		# shellcheck disable=SC2086
		set -- $todo
		[ $# -gt 0 ] || break
		k=$1; shift; todo=$*
		t=$(tree_of "$k") || continue
		case " $seen " in *" $t "*) continue ;; esac
		seen="$seen $t"; have="$have $NS/trees/$t"
		todo="$todo $(needs_of "$t" | tr '\n' ' ')"
	done
	# shellcheck disable=SC2086
	find $have ! -type d -name '*.so*' | sed 's|.*/||' | LC_ALL=C sort -u > "$W/sonames"
	find "$OUT/trees/$name" -type f -exec readelf -ld /dev/null {} + 2>/dev/null | awk -v names="$W/sonames" -v root="$OUT/trees/$name" '
		BEGIN { while ((getline l < names) > 0) have[l] = 1 }
		/^File: / { f = substr($0, 7); sub("^" root, "/usr", f) }
		/Requesting program interpreter:/ { i = $0; sub(/.*interpreter: /, "", i); sub(/\].*/, "", i)
			if (i != "/lib64/ld-linux-x86-64.so.2") print f ": its loader is " i }
		/\(NEEDED\)/ { n = $0; sub(/.*\[/, "", n); sub(/\].*/, "", n); if (!(n in have)) print f ": loads " n }' > "$W/unmet"
	if [ -s "$W/unmet" ]; then
		head -n 20 "$W/unmet" >&2
		die "$name: $(wc -l < "$W/unmet") of its files load a library that neither the kit nor a kit it needs holds, or name another loader (above; needs: ${needs:-none})"
	fi
fi

# ---- manifest, record, kit ----------------------------------------------------------------------------------------
kneeds=
for n in $needs; do kneeds="$kneeds {$n {}}"; done
{
	printf 'name %s  version %s  kind system\n' "$kit" "$ver"
	printf 'summary {%s}\nlicense {%s}\nx-short %s\n' "$summary" "$license" "$name"
	[ -z "$kneeds" ] || printf 'needs {%s}\n' "${kneeds# }"
} > "$OUT/src/$name.manifest"
{
	echo "kit $kit $ver"
	echo "recipe $rhash"
	# shellcheck disable=SC2086
	set -- $sha256
	for u in $source; do echo "source $(basename "$u") $1"; shift; done
	echo "sandbox $sandbox"
	echo "root $rootline"
	[ -z "$seed" ] || echo "seed $seed"
	[ -z "$standin" ] || echo "standin $standin"
	echo "flags $flags"
	if [ -z "$roottrees$boottrees" ]; then
		echo "cc $( (cc --version 2>/dev/null || echo none) | head -n1)"
		echo "host $(uname -m) $( ( . /etc/os-release 2>/dev/null; echo "${ID:-unknown} ${VERSION_ID:-}" ) )"
	fi
	echo "key $key"
} > "$OUT/src/$name.buildinfo"
kit_pack "$OUT/trees/$name" "$OUT/src/$name.manifest" "$OUT/images/$name.erofs" "$OUT/kits/$kit-$ver.kit"
# OUT/kits holds one kit per recipe: the one it made before, of another version, goes
if [ -n "$prev" ] && [ "$prev" != "$kit $ver" ]; then rm -f "$OUT/kits/${prev% *}-${prev##* }.kit"; fi
rm -rf "$W" "$RC"; rmdir "$OUT/work" 2>/dev/null || :
echo "kit-build: $kit $ver -> $OUT/kits/$kit-$ver.kit$([ -n "${KIT_SIGN:-}" ] || echo ' (unsigned: no KIT_SIGN)')"
