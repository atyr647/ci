#!/bin/sh
# ribbon-kits.sh - Ribbon's own packages as system kits (docs/INDEPENDENCE.md P2; docs/SYSTEM-KITS-BUILD.md).
#
# Each package of build/install/manifests is staged exactly as `make install DESTDIR=` installs it (the same manifest
# the xbps template is held to, tests/steps.d/90-install.sh), and its /usr becomes one system kit: an uncompressed
# erofs image (KIT-FORMAT.md 8) packed by kitpack, named org.ribbon.NAME (short name: the package's), at the template's
# version_revision, needing the other Ribbon kits its template depends on.
#
#   build/kits/ribbon-kits.sh OUT [PACKAGE...]      (default: every manifest whose package is built in O)
#
#   OUT/trees/PACKAGE/        the staged /usr (what the image holds: the image's root is /usr). What the package
#                             installs outside /usr is in it as defaults, share/ribbon/defaults/PACKAGE/etc/..., and the
#                             directories it wants made as share/ribbon/defaults/PACKAGE.state; ribbon-kit's kit-defaults
#                             puts each down where there is none (decision 126)
#   OUT/outside.txt           the list of those files
#   OUT/base-needs.txt        per kit, the template's dependencies that are not Ribbon kits (the base still brings them)
#   OUT/images/PACKAGE.erofs  the image
#   OUT/kits/NAME-VERSION.kit the kit (signed when KIT_SIGN names a secret key of the system role)
#   OUT/kits.txt              "NAME VERSION FILE" per kit
#
# It refuses (and names the path) when two kits would bring the same path: the merged /usr view takes the later
# image's entry without a word (measured: a file, and a link over a directory), so a clash is stopped here.
#
# Environment: O (make build's output, default out/build), KITFMT_MK4TCL (a built Mk4tcl, needed), KIT_SIGN (secret key),
# KITPACK_VERITY (auto|yes|no, default auto), SOURCE_DATE_EPOCH, MANIFESTS (another manifests directory, as install.sh). Needs mkfs.erofs, tclsh, the packages built (make build).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "ribbon-kits: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: ribbon-kits.sh OUT [PACKAGE...]"
OUT=$1; shift
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
O=${O:-out/build}
case $O in /*) ;; *) O=$ROOT/$O ;; esac
[ -n "${KITFMT_MK4TCL:-}" ] || die "KITFMT_MK4TCL (a built Mk4tcl) is needed: kitpack writes the kit with it"
command -v mkfs.erofs >/dev/null 2>&1 || die "no mkfs.erofs (erofs-utils)"
TCLSH=$(command -v tclsh || command -v tclsh8.6) || die "no tclsh"
export TCLSH
cd "$ROOT"
. build/kits/lib.sh
MD=${MANIFESTS:-build/install/manifests}

if [ $# -eq 0 ]; then
	set --
	for m in "$MD"/*.manifest; do set -- "$@" "$(basename "$m" .manifest)"; done
	all=1
else all=0; fi

kitname() { echo "org.ribbon.${1#ribbon-}"; }
# a template's fields, one per line: version_revision, short_desc, license, then its dependencies' names
template() {
	# shellcheck disable=SC1090,SC2034,SC2154
	(set +eu; XBPS_CROSS_BASE=; XBPS_TARGET_MACHINE=x86_64; . "$ROOT/srcpkgs/$1/template" >/dev/null 2>&1
	printf '%s_%s\n%s\n%s\n' "$version" "$revision" "$short_desc" "$license"
	# shellcheck disable=SC2086
	for d in $depends; do echo "${d%%[<>=]*}"; done)
}

rm -rf "$OUT/trees" "$OUT/images" "$OUT/kits" "$OUT/src" "$OUT/stage"
mkdir -p "$OUT/trees" "$OUT/images" "$OUT/kits" "$OUT/src" "$OUT/stage"
: > "$OUT/outside.txt"; : > "$OUT/base-needs.txt"; : > "$OUT/kits.txt"

# ---- stage ----------------------------------------------------------------------------------------------------
built=
for p; do
	[ -f "$MD/$p.manifest" ] || die "no package $p ($MD/$p.manifest)"
	# the base's own lines (xbps.d, kernel.d) are not a kit's: the kit backend has none
	if ! O="$O" DISTDIR="${DISTDIR:-out/distfiles}" DESTDIR="$OUT/stage/$p" PREFIX=/usr RIBBON_PKG_BACKEND=kit \
		sh build/install/install.sh install "$p" --if-built >"$OUT/stage/$p.log" 2>&1; then
		cat "$OUT/stage/$p.log" >&2; die "$p does not install into a staging root"
	fi
	if [ ! -d "$OUT/stage/$p/usr" ]; then
		[ "$all" = 1 ] || die "$p is not built (make build), or installs nothing into /usr"
		echo "ribbon-kits: $p is not built here, left out" >&2
		continue
	fi
	mv "$OUT/stage/$p/usr" "$OUT/trees/$p"
	# the install record is the base-neutral installer's; a kit is its own record
	rm -rf "$OUT/stage/$p/var/lib/ribbon/installed"
	# what the package installs outside /usr travels in the kit as defaults (kit-defaults puts each down where there is
	# none), and the directories it wants made (the manifest's state lines) as a list
	kit_defaults "$OUT/stage/$p" "$OUT/trees/$p" "$p" | sed "s|^|$p\t|" >> "$OUT/outside.txt"
	if grep -q '^state ' "$MD/$p.manifest"; then
		mkdir -p "$OUT/trees/$p/share/ribbon/defaults"
		sed -n 's/^state  *//p' "$MD/$p.manifest" > "$OUT/trees/$p/share/ribbon/defaults/$p.state"
		chmod 644 "$OUT/trees/$p/share/ribbon/defaults/$p.state"
	fi
	built="$built $p"
done
[ -n "$built" ] || die "nothing to pack"

# ---- no path twice ----------------------------------------------------------------------------------------------
# shellcheck disable=SC2086
clash=$(kit_clashes "$OUT/trees" $built)
[ -z "$clash" ] || { echo "$clash" >&2; die "two kits bring the same path (above): the view would take one without a word"; }

# ---- image, manifest, kit ---------------------------------------------------------------------------------------
for p in $built; do
	name=$(kitname "$p")
	tf=$OUT/src/$p.template
	template "$p" > "$tf"
	ver=$(sed -n 1p "$tf"); desc=$(sed -n 2p "$tf"); lic=$(sed -n 3p "$tf")
	case $ver in _|'') die "cannot read srcpkgs/$p/template" ;; esac
	needs=; base=
	# shellcheck disable=SC2013
	for d in $(sed 1,3d "$tf"); do
		case " $built " in *" $d "*) needs="$needs {$(kitname "$d") {}}" ;; *) base="$base $d" ;; esac
	done
	printf '%s\t%s\n' "$name" "${base# }" >> "$OUT/base-needs.txt"
	{
		printf 'name %s  version %s  kind system\n' "$name" "$ver"
		printf 'summary {%s}\n' "$desc"
		printf 'license {%s}\n' "$lic"
		printf 'x-short %s\n' "$p"
		[ -z "$needs" ] || printf 'needs {%s}\n' "${needs# }"
	} > "$OUT/src/$p.manifest"
	kit=$OUT/kits/$name-$ver.kit
	kit_pack "$OUT/trees/$p" "$OUT/src/$p.manifest" "$OUT/images/$p.erofs" "$kit"
	printf '%s\t%s\t%s\n' "$name" "$ver" "$kit" >> "$OUT/kits.txt"
done
rmdir "$OUT/stage" 2>/dev/null || rm -rf "$OUT/stage"
echo "ribbon-kits: $(wc -l < "$OUT/kits.txt") kits in $OUT/kits$([ -n "${KIT_SIGN:-}" ] || echo ' (unsigned: no KIT_SIGN)'); $(wc -l < "$OUT/outside.txt") files outside /usr listed in $OUT/outside.txt"
