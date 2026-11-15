# tests/fixtures/updates-seam/common.sh - RIBBON_LIB for ribbon-update in the desktop's tests: the real common.sh,
# then a stand-in for the package seam's update part (pkg.sh, pkg-update.sh) behind the same functions. Its state is
# in RIBBON_SEAM_STUB: plan (pkg_updates' lines, NAME|OLD|NEW|BYTES|ACTION|TAGS), installed (NAME VERSION), and log
# (what was asked). fail-check / fail-update there make the check or the update fail.
. "${RIBBON_REAL_LIB:?}/common.sh"
_stub=${RIBBON_SEAM_STUB:?}
pkg_backend() { echo stub; }
pkg_refresh() { echo "pkg_refresh" >> "$_stub/log"; }
pkg_versions() { cat "$_stub/installed" 2>/dev/null; }
pkg_updates() {
	echo "pkg_updates" >> "$_stub/log"
	[ -e "$_stub/fail-check" ] && { echo "pkg: the repository could not be reached" >&2; return 1; }
	cat "$_stub/plan" 2>/dev/null
}
pkg_upgrade_self() { echo "pkg_upgrade_self $*" >> "$_stub/log"; }
pkg_upgrade() {
	echo "pkg_upgrade $*" >> "$_stub/log"
	[ -e "$_stub/fail-update" ] && { echo "pkg: the transaction failed" >&2; return 1; }
	local n old new rest
	while IFS='|' read -r n old new rest; do
		[ -n "$n" ] || continue
		{ grep -v "^$n " "$_stub/installed" 2>/dev/null; echo "$n $new"; } > "$_stub/installed.new"
		mv "$_stub/installed.new" "$_stub/installed"
	done < "$_stub/plan"
	: > "$_stub/plan"
}
