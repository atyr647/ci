#!/bin/sh
# check.sh - the test suite (tests/run.sh) in CI, on an ubuntu-24.04 runner (the check job of build/ci/ribbon-image.yml).
#
#   sudo build/ci/check.sh deps      install every package build/ci/check-tools.txt names (packages: list them), and
#                                    Space Grotesk as ribbon-desktop ships it (fonts, below); lets users make user
#                                    namespaces (AppArmor's restriction off: kit run's sandbox)
#   build/ci/check.sh run RESULTS    fetch the Metakit tarball srcpkgs/mk4tcl/template names (checked), build Mk4tcl
#                                    from it (build/ci/build-mk4tcl.sh), then tests/run.sh with KITFMT_MK4TCL and
#                                    KIT_METAKIT_TARBALL set, so that kit end to end, mkkitfs and make install-mk4tcl
#                                    (tests/steps.d/93-ci.sh) run instead of skipping; likewise unix_sockets from the
#                                    tarball srcpkgs/tcl-unix-sockets/template names (build/ci/build-unix-sockets.sh), put
#                                    on TCLLIBPATH (and UNIX_SOCKETS_DIR) for the Notes hand-off, the greeter and FUSE.
#                                    RESULTS gets check-summary.txt (RESULT lines), check.log (the whole run), check-tail.log,
#                                    check-fails.txt, check-skips.txt.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$PWD

packages() {
	grep -v '^#' build/ci/check-tools.txt |
		awk '$1 == "+" { for (i = 2; i <= NF; i++) print $i; next } { for (i = 2; i <= NF; i++) if ($i != "-" && $i != "!") print $i }' |
		LC_ALL=C sort -u
}
# Space Grotesk as ribbon-desktop installs it: the template's variable font (its distfile, checked) and the 600
# instance its build cuts with greeter/space-grotesk-semibold.py. The boards are drawn with these, and Ubuntu's
# fonts-space-grotesk is an older cut without the 600, so the scene tests' titles would fall back to DejaVu Sans.
fonts() {
	eval "$(set +eu; XBPS_CROSS_BASE=; . srcpkgs/ribbon-desktop/template >/dev/null 2>&1
		i=0; for d in $distfiles; do i=$((i + 1)); case $d in *">SpaceGrotesk-wght.ttf") n=$i; printf 'sgurl=%s\n' "${d%>*}" ;; esac; done
		j=0; for c in $checksum; do j=$((j + 1)); [ "$j" = "${n:-0}" ] && printf 'sgsum=%s\n' "$c"; done)"
	[ -n "${sgurl:-}" ] && [ -n "${sgsum:-}" ] || { echo "check.sh: no SpaceGrotesk-wght.ttf in srcpkgs/ribbon-desktop/template" >&2; return 1; }
	t=$(mktemp -d)
	curl -fsSL --retry 3 -o "$t/sg.ttf" "$sgurl"
	[ "$(sha256sum "$t/sg.ttf" | cut -d' ' -f1)" = "$sgsum" ] || { echo "check.sh: $sgurl does not match the template's checksum" >&2; return 1; }
	d=/usr/local/share/fonts/ribbon
	mkdir -p "$d"
	cp "$t/sg.ttf" "$d/SpaceGrotesk[wght].ttf"
	python3 srcpkgs/ribbon-desktop/files/greeter/space-grotesk-semibold.py "$t/sg.ttf" "$d/SpaceGrotesk-SemiBold.ttf"
	chmod 644 "$d"/*.ttf
	rm -rf "$t"
	fc-cache -f "$d"
}
case ${1:-} in
packages) packages ;;
deps)
	pkgs=$(packages)
	apt-get update -qq
	# shellcheck disable=SC2086
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs
	fonts
	# Ubuntu 24.04 confines unprivileged user namespaces with AppArmor (kernel.apparmor_restrict_unprivileged_userns),
	# which Ribbon's base does not: kit run's bubblewrap sandbox and the suite's unshare -r checks need them as a user
	if [ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
		sysctl -q -w kernel.apparmor_restrict_unprivileged_userns=0
	fi
	;;
run)
	R=${2:?usage: check.sh run RESULTS}
	mkdir -p "$R" out/distfiles out/logs
	case $R in /*) ;; *) R=$ROOT/$R ;; esac
	sum=$R/check-summary.txt
	: > "$sum"
	eval "$(set +eu; XBPS_CROSS_BASE=; . srcpkgs/mk4tcl/template >/dev/null 2>&1
		printf 'url=%s version=%s\n' "$distfiles" "$version")"
	tarball=out/distfiles/$(basename "$url")
	[ -f "$tarball" ] || curl -fsSL --retry 3 -o "$tarball" "$url" > out/logs/mk4tcl.log 2>&1 || rm -f "$tarball"
	MK=$ROOT/out/build/mk4tcl
	if [ -f "$tarball" ] && sh build/ci/build-mk4tcl.sh "$tarball" "$MK" >> out/logs/mk4tcl.log 2>&1; then
		echo "RESULT mk4tcl: ok (Mk4tcl $version built from the checked Metakit tarball)" >> "$sum"
		KITFMT_MK4TCL=$MK; export KITFMT_MK4TCL
	else
		echo "RESULT mk4tcl: FAILED (see mk4tcl.log)" >> "$sum"
	fi
	[ ! -f "$tarball" ] || { KIT_METAKIT_TARBALL=$ROOT/$tarball; export KIT_METAKIT_TARBALL; }
	cp out/logs/mk4tcl.log "$R/" 2>/dev/null || :
	eval "$(set +eu; XBPS_CROSS_BASE=; . srcpkgs/tcl-unix-sockets/template >/dev/null 2>&1
		printf 'usurl=%s usversion=%s\n' "$distfiles" "$version")"
	ustar=out/distfiles/$(basename "$usurl")
	[ -f "$ustar" ] || curl -fsSL --retry 3 -o "$ustar" "$usurl" > out/logs/unix-sockets.log 2>&1 || rm -f "$ustar"
	US=$ROOT/out/build/unix-sockets
	if [ -f "$ustar" ] && sh build/ci/build-unix-sockets.sh "$ustar" "$US" >> out/logs/unix-sockets.log 2>&1; then
		echo "RESULT unix_sockets: ok (unix_sockets $usversion built from the checked tarball)" >> "$sum"
		TCLLIBPATH="$US${TCLLIBPATH:+ $TCLLIBPATH}" UNIX_SOCKETS_DIR=$US; export TCLLIBPATH UNIX_SOCKETS_DIR
	else
		echo "RESULT unix_sockets: FAILED (see unix-sockets.log)" >> "$sum"
	fi
	cp out/logs/unix-sockets.log "$R/" 2>/dev/null || :

	st=0
	timeout -k 30 3600 sh tests/run.sh > out/logs/check.log 2>&1 || st=$?
	cp out/logs/check.log "$R/check.log"
	tail -n 400 out/logs/check.log > "$R/check-tail.log"
	# each FAIL line under the step (== ...) and the steps.d file (-- ...) it came from
	sed 's/\x1b\[[0-9;]*m//g' out/logs/check.log | awk '/^== / { s = $0; f = ""; next } /^-- / { f = " " $0; next }
		/^ *FAIL/ { print s f ": " $0 }' > "$R/check-fails.txt"
	grep -E '^ *skip' out/logs/check.log | sort | uniq -c | sort -rn > "$R/check-skips.txt" || :
	nok=$(grep -c '^ *ok ' out/logs/check.log || :)
	nfail=$(grep -c '^ *FAIL' out/logs/check.log || :)
	nskip=$(grep -c '^ *skip' out/logs/check.log || :)
	if [ "$st" = 0 ]; then
		echo "RESULT check: ok (tests/run.sh: all checks passed; $nok ok, $nskip skip)" >> "$sum"
	else
		echo "RESULT check: FAILED (tests/run.sh exit $st; $nok ok, $nfail FAIL, $nskip skip: see check-fails.txt)" >> "$sum"
	fi
	cat "$sum"
	# a helper that did not build makes its checks skip, not fail: the job fails on it all the same
	[ "$st" = 0 ] && ! grep -q "^RESULT [a-z_0-9]*: FAILED" "$sum"
	;;
*)
	echo "usage: $0 deps | packages | run RESULTS" >&2; exit 2 ;;
esac
