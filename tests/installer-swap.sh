#!/bin/bash
# The Hardware page's swap sizes are postinstall's: page::swap_plan (pages.tcl,
# the page's copy reads from it) against step_swap itself (ribbon-tools'
# postinstall, run with stand-ins for /proc/meminfo, the root filesystem and
# ribbon-swap), for every mode on machines of 4 to 128 GiB on btrfs, zfs and
# bcachefs. Needs bash and tclsh8.6.
set -u
cd "$(dirname "$0")/.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip installer swap sizes (no tclsh8.6)"; exit 0; }
PAGES=srcpkgs/ribbon-installer/files/tk/pages.tcl
POST=srcpkgs/ribbon-tools/files/bin/postinstall
fail=0
fn=$(sed -n '/^step_swap() {$/,/^}$/p' "$POST")
[ -n "$fn" ] || { echo "  FAIL step_swap not found in $POST"; exit 1; }
# step_swap with this machine's MemTotal (kB) and root filesystem: what it hands ribbon-swap
post() { # kib fs mode [bytes]
	bash -c '
		KIB=$1 FS=$2; shift 2
		log() { :; }
		root_fstype() { echo "$FS"; }
		awk() { echo "$KIB"; }
		ribbon-swap() { shift; echo "$*"; }
		eval "$FN"
		step_swap "$@"' post "$@"
}
export FN=$fn
page() { # kib fs mode [bytes]
	tclsh8.6 /dev/stdin "$PAGES" "$@" <<'EOF'
lassign $argv f kib fs mode size
set fh [open $f]; fconfigure $fh -encoding utf-8; set src [read $fh]; close $fh
regexp {\nproc page::swap_plan .*?\n\}\n} $src def
namespace eval page {}
eval $def
set p [page::swap_plan $mode [expr {$kib * 1024}] $fs [expr {$size eq "" ? 0 : $size}]]
puts "zram=[dict get $p zram] file=[dict get $p file] hibernate=[dict get $p hibernate]"
EOF
}
n=0
for kib in 3990000 8029248 16303128 32765360 34359738 65811372 131900000; do
	for fs in btrfs zfs bcachefs; do
		for m in zram gaming hibernate none "custom 8000000000" "custom 100000"; do
			# shellcheck disable=SC2086
			a=$(post "$kib" "$fs" $m); b=$(page "$kib" "$fs" $m)
			n=$((n + 1))
			if [ "$a" != "$b" ]; then echo "  FAIL $((kib / 1048576)) GiB, $fs, $m: postinstall '$a', the page '$b'"; fail=1; fi
		done
	done
done
[ $fail -eq 0 ] && echo "  ok   the Hardware page's swap sizes are postinstall's ($n cases)"
exit $fail
