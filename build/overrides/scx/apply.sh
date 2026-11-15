#!/bin/sh
# Ribbon OS override of void-packages/srcpkgs/scx ($1 = that dir).
#
# Void's scx is every sched_ext scheduler and tool (21 binaries, 139 MiB).
# Ribbon runs one: scx_lavd (ribbon-scheduler's default, and GameMode's
# --performance), 9.3 MiB. scx keeps scx_lavd; a new subpackage scx-extra
# takes the rest (scx_bpfland, scx_rusty, scxtop, ...), so `xbps-install
# scx-extra` still gives `ribbon scheduler set` every choice
# (docs/STACK.md §2.1).
# FOR INDEPENDENCE: not in build-packages.sh's OVERRIDES yet; Ribbon
# rebuilds Void packages only once it builds everything (docs/STACK.md
# "At independence"). Its binary packages are listed in ./packages, which
# the collection step will need for the subpackages.
set -e
dir=$1
grep -q 'Ribbon OS override' "$dir/template" && exit 0
grep -q "^do_install()" "$dir/template" || { echo "scx override: do_install not found" >&2; exit 1; }
if grep -q '_package()' "$dir/template"; then echo "scx override: template already has subpackages" >&2; exit 1; fi
sed -i '1a # Ribbon OS override: only scx_lavd in scx; the other schedulers and tools go to scx-extra (build/overrides/scx).' "$dir/template"
cat >> "$dir/template" <<'TPL'

scx-extra_package() {
	short_desc+=" - every scheduler but scx_lavd, and the tools"
	depends="scx>=${version}_${revision}"
	pkg_install() {
		for _f in "${DESTDIR}"/usr/bin/scx*; do
			[ "${_f##*/}" = scx_lavd ] && continue
			vmove "usr/bin/${_f##*/}"
		done
		[ -x "${DESTDIR}/usr/bin/scx_lavd" ] || msg_error "scx: scx_lavd was not built\n"
	}
}
TPL
ln -sfn scx "$dir/../scx-extra"
