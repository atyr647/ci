#!/bin/sh
# kconfig.sh - Ribbon's kernel configuration: a base .config plus fragments (build/kernel/config/NN-*.config).
#
#   kconfig.sh lint  BASE FRAGMENT...    the fragments are well formed, name only options the base knows, never
#                                        give one option two values, and never set an option that has no prompt
#                                        with the base and the fragments (GATES below) to other than its default
#   kconfig.sh merge BASE FRAGMENT...    the base with every fragment line put in place of the base's own line for
#                                        that option (the last fragment wins), on stdout; `make olddefconfig` then
#                                        resolves it (the kernel's scripts/kconfig/merge_config.sh does the same)
#   kconfig.sh check CONFIG FRAGMENT...  after olddefconfig: every fragment line survived (a "not set" line also
#                                        holds when the option is gone, as it is when the menu above it is off);
#                                        each one that did not is printed, and the exit status is 1
#   kconfig.sh dir DIR                   the base and the fragments of a build/kernel/config directory, in order (the
#                                        base is the file named in DIR/SOURCE)
#
# A fragment line is `CONFIG_X=VALUE` or `# CONFIG_X is not set`; blank lines and other comments are ignored.
set -eu
LC_ALL=C; export LC_ALL

die() { echo "kconfig.sh: $*" >&2; exit 2; }

# Options that have no prompt (are not user-visible) unless another option has a value, from the Kconfig files of
# the kernel the template builds (6.18). olddefconfig gives such an option its default whatever .config says, so a
# fragment line for it holds only with its gate set too: "OPTION GATE GATE-VALUE DEFAULT-WITHOUT-THE-GATE".
# Without the kernel source lint cannot find these itself, nor an option that something still on selects: those
# only kconfig.sh check, after olddefconfig in CI, catches.
GATES='
# drivers/media/Kconfig: prompt "..." if MEDIA_SUPPORT_FILTER, default y if !MEDIA_SUPPORT_FILTER
CONFIG_MEDIA_CAMERA_SUPPORT CONFIG_MEDIA_SUPPORT_FILTER y y
CONFIG_MEDIA_ANALOG_TV_SUPPORT CONFIG_MEDIA_SUPPORT_FILTER y y
CONFIG_MEDIA_DIGITAL_TV_SUPPORT CONFIG_MEDIA_SUPPORT_FILTER y y
CONFIG_MEDIA_RADIO_SUPPORT CONFIG_MEDIA_SUPPORT_FILTER y y
CONFIG_MEDIA_SDR_SUPPORT CONFIG_MEDIA_SUPPORT_FILTER y y
CONFIG_MEDIA_PLATFORM_SUPPORT CONFIG_MEDIA_SUPPORT_FILTER y y
CONFIG_MEDIA_TEST_SUPPORT CONFIG_MEDIA_SUPPORT_FILTER y y
'

# "SYMBOL VALUE" for each setting in the given files (VALUE n for "is not set"), in order
settings() {
	awk '
		/^CONFIG_[A-Za-z0-9_]+=/ { i = index($0, "="); print substr($0, 1, i - 1), substr($0, i + 1); next }
		/^# CONFIG_[A-Za-z0-9_]+ is not set$/ { print $2, "n"; next }
	' "$@"
}

# the lines of a fragment that are neither settings, comments nor blank (each as FILE:LINE: TEXT)
malformed() {
	awk '
		/^CONFIG_[A-Za-z0-9_]+=(y|m|n|-?[0-9]+|0x[0-9a-fA-F]+|"([^"\\]|\\.)*")$/ { next }
		/^# CONFIG_[A-Za-z0-9_]+ is not set$/ { next }
		/^#/ || /^[ \t]*$/ { next }
		{ print FILENAME ":" FNR ": " $0 }
	' "$@"
}

lint() {
	base=$1; shift
	[ -f "$base" ] || die "no base $base"
	bad=0
	m=$(malformed "$@")
	[ -z "$m" ] || { echo "$m" | sed 's/^/malformed: /'; bad=1; }
	known=$(settings "$base" | cut -d' ' -f1 | sort -u)
	for f in "$@"; do
		settings "$f" | while read -r sym _; do
			echo "$known" | grep -qx "$sym" || echo "unknown to the base: $sym ($f)"
		done
	done | grep . && bad=1
	# one value per option across all fragments
	for f in "$@"; do settings "$f" | sed "s|\$| $f|"; done | sort -k1,1 -s |
		awk '{ if ($1 == s && $2 != v) { print "two values for " $1 ": " v " (" w ") and " $2 " (" $3 ")"; bad = 1 }
			s = $1; v = $2; w = $3 } END { exit bad }' || bad=1
	# an option without its prompt keeps its default: its gate must be set too (base, then the fragments in order)
	{ echo "$GATES" | sed -n 's/^CONFIG_/G CONFIG_/p'; settings "$base" | sed 's/^/B /'; settings "$@" | sed 's/^/F /'; } | awk '
		$1 == "G" { gate[$2] = $3; gval[$2] = $4; gdef[$2] = $5; next }
		{ have[$2] = $3 }
		$1 == "F" { want[$2] = $3; if (!($2 in seen)) { order[++n] = $2; seen[$2] = 1 } }
		END {
			for (i = 1; i <= n; i++) {
				s = order[i]
				if (!(s in gate) || want[s] == gdef[s]) continue
				g = gate[s]; v = (g in have) ? have[g] : "n"
				if (v != gval[s]) {
					printf "not user-visible: %s=%s needs %s=%s (without it olddefconfig makes it %s)\n", s, want[s], g, gval[s], gdef[s]
					bad = 1
				}
			}
			exit bad
		}' || bad=1
	return $bad
}

merge() {
	base=$1; shift
	[ -f "$base" ] || die "no base $base"
	for f in "$@"; do [ -f "$f" ] || die "no fragment $f"; done
	settings "$@" | awk -v base="$base" '
		{ want[$1] = $2; if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 } }
		END {
			while ((getline l < base) > 0) {
				s = ""
				if (l ~ /^CONFIG_[A-Za-z0-9_]+=/) s = substr(l, 1, index(l, "=") - 1)
				else if (l ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) { split(l, w, " "); s = w[2] }
				if (s != "" && (s in want)) continue
				print l
			}
			print ""
			print "# Ribbon (build/kernel/config)"
			for (i = 1; i <= n; i++) {
				s = order[i]
				if (want[s] == "n") print "# " s " is not set"; else print s "=" want[s]
			}
		}'
}

check() {
	conf=$1; shift
	[ -f "$conf" ] || die "no config $conf"
	{ settings "$conf" | sed 's/^/H /'; settings "$@" | sed 's/^/W /'; } | awk '
		$1 == "H" { got[$2] = substr($0, length($2) + 4); next }
		{
			want = substr($0, length($2) + 4)
			v = ($2 in got) ? got[$2] : "n"
			if (v != want) { printf "%s: wanted %s, olddefconfig made it %s\n", $2, want, v; bad = 1 }
		}
		END { exit bad }'
}

dir() {
	d=$1
	[ -f "$d/SOURCE" ] || die "no $d/SOURCE"
	b=$(awk '!/^#/ && NF { print $1; exit }' "$d/SOURCE")
	[ -n "$b" ] && [ -f "$d/$b" ] || die "the base named in $d/SOURCE is missing"
	echo "$d/$b"
	for f in "$d"/[0-9][0-9]-*.config; do [ -f "$f" ] && echo "$f"; done
	return 0
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case $cmd in
lint) [ $# -ge 2 ] || die "usage: kconfig.sh lint BASE FRAGMENT..."; lint "$@" ;;
merge) [ $# -ge 2 ] || die "usage: kconfig.sh merge BASE FRAGMENT..."; merge "$@" ;;
check) [ $# -ge 2 ] || die "usage: kconfig.sh check CONFIG FRAGMENT..."; check "$@" ;;
dir) [ $# -eq 1 ] || die "usage: kconfig.sh dir DIR"; dir "$1" ;;
*) die "usage: kconfig.sh lint|merge|check|dir ..." ;;
esac
