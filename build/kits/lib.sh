# shellcheck shell=sh
# lib.sh - what the kit builders share (ribbon-kits.sh, kit-build.sh): a staged /usr tree becomes a system kit.
# Sourced; needs ROOT (this repository), KITFMT_MK4TCL, mkfs.erofs and tclsh. die() is the caller's.

kit_uuid() { printf '%s' "ribbon kit image $1" | sha256sum | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/'; }

# kit_pack TREE MANIFEST IMAGE KIT: the erofs image of TREE (its root is /usr) and the kit around it.
# As CI's kernel.sh makes its images: uncompressed, no inline data, one fixed time, root-owned, a UUID from the
# manifest's name and version, so the same tree gives the same image. Signed when KIT_SIGN names a secret key.
kit_pack() {
	_tree=$1 _man=$2 _img=$3 _kit=$4
	_id=$(sed -n 's/^name \([^ ]*\)  *version \([^ ]*\).*/\1 \2/p' "$_man")
	[ -n "$_id" ] || die "$_man: no 'name NAME version VERSION' line"
	mkfs.erofs --quiet -T"${SOURCE_DATE_EPOCH:-0}" --all-root -U "$(kit_uuid "$_id")" -Enoinline_data \
		"$_img" "$_tree" >"$_img.log" 2>&1 || { cat "$_img.log" >&2; die "mkfs.erofs failed for $_tree"; }
	rm -f "$_img.log"
	# kitpack holds the image in one Tcl value, which stops at 2 GiB
	_sz=$(wc -c < "$_img")
	[ "$_sz" -lt 2000000000 ] || die "$_img is $_sz bytes: kitpack packs images under 2 GB (it reads the image whole)"
	mkdir -p "$(dirname "$_kit")/.empty"
	set -- -q -mk4tcl "$KITFMT_MK4TCL" -manifest "$_man" -image "$_img" -fs erofs -verity "${KITPACK_VERITY:-auto}"
	[ -z "${KIT_SIGN:-}" ] || set -- "$@" -sign "$KIT_SIGN"
	"${TCLSH:-tclsh}" "$ROOT/kit/kitfmt/kitpack" "$@" "$(dirname "$_kit")/.empty" "$_kit" >&2 || die "kitpack failed for $_tree"
	rmdir "$(dirname "$_kit")/.empty"
}

# kit_defaults STAGE TREE NAME: what a package staged outside /usr (STAGE, its usr already taken out) goes into the
# tree as defaults (share/ribbon/defaults/NAME/..., decision 126); prints those files' paths, one per line.
kit_defaults() {
	find "$1" -depth -type d -empty -exec rmdir {} + 2>/dev/null || :
	[ -d "$1" ] || return 0
	mkdir -p "$2/share/ribbon/defaults"
	(cd "$1" && find . ! -type d | LC_ALL=C sort | sed 's|^\.||')
	mv "$1" "$2/share/ribbon/defaults/$3"
}

# kit_clashes TREES NAME...: the paths more than one of the trees TREES/NAME brings, "/usr/PATH: NAME NAME" per line.
# A path may be in two kits only as a directory in both: the merged /usr view takes the later image's entry for any
# other without a word (docs/SYSTEM-KITS-BUILD.md 2b), and kitd refuses such a set (decision 127).
kit_clashes() {
	_trees=$1; shift
	for _p; do
		(cd "$_trees/$_p" && find . -mindepth 1 -type d | sed "s|^\./||; s|\$|\td\t$_p|"
		cd "$_trees/$_p" && find . -mindepth 1 ! -type d | sed "s|^\./||; s|\$|\to\t$_p|")
	done | LC_ALL=C sort | awk -F'\t' '{ n[$1]++; if ($2 == "o") o[$1] = 1; who[$1] = who[$1] " " $3 }
		END { for (k in n) if (n[k] > 1 && o[k]) print "/usr/" k ":" who[k] }' | LC_ALL=C sort
}
