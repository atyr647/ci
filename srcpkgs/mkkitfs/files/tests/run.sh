#!/bin/sh
# mkkitfs's tests (docs/MKKITFS.md).  Run by `make check` and by Ribbon's tests/test-mkkitfs.sh.
#
#   MKKITFS=<built mkkitfs> [METAKIT=<metakit source>] sh tests/run.sh
#
# 1. golden kits: `mkkitfs expect` and `mkkitfs index` agree byte for byte with
#    kit/kitfmt/tests/golden/*.expect and *.index; every damaged kit is refused as its .expect says
#    1b. the confinement (tests/confine-test.cpp: seccomp, Landlock and the unmount guard on their own;
#    then extract through it)
# 2. a fuzz pass over damaged copies of the golden kits (MKKITFS_FUZZ iterations, default 300); the
#    sanitizer build's pass is `make fuzz` (tests/fuzz-sanitize.sh)
# 3. through FUSE (skipped without a usable /dev/fuse): mkkitfsd + mkkitfs serving the golden
#    kits, the damaged ones refused at mount, EIO for the bad chunk, references and linger
# 4. with Mk4tcl (built from METAKIT, or KITFMT_MK4TCL): kitpack makes a ~90 MB kit and a small Tk
#    app's kit; the C++ index of the big kit equals kitfmt's; concurrent reads; start-up time of the
#    Tk app (with xvfb-run and wish); composition with bubblewrap >= 0.10 (MKKITFS_BWRAP or bwrap)
# 5. MKKITFS_BENCH=1: the cold/warm read benchmark against the extracted copy (cold needs root)
# Every line is "  ok", "  FAIL", "  skip" or "  info"; the exit status is 1 if anything failed.
set -u
here=$(cd "$(dirname "$0")" && pwd)
top=${RIBBON_TREE:-$(cd "$here/../../../.." && pwd)}   # the Ribbon tree (kit/kitfmt: golden kits, kitpack)
gold=$top/kit/kitfmt/tests/golden
keys=$top/kit/kitfmt/tests/keys/test.pub
tcldir=$here/../tcl
M=${MKKITFS:?set MKKITFS to the mkkitfs binary}
if [ ! -f "$gold/app.kit" ]; then
	echo "  skip mkkitfs tests: no golden kits at $gold (set RIBBON_TREE to a Ribbon checkout)"
	exit 0
fi
status=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; status=1; }
skip() { echo "  skip $*"; }
work=$(mktemp -d)
cleanup() {
	for s in "$work"/*/s "$work"/fuse/kit/mkkitfs.sock "$work"/trust/s; do
		[ -S "$s" ] && tclsh "$tcldir/mkkitfsd" ctl -socket "$s" quit >/dev/null 2>&1
	done
	sleep 0.3
	grep -F "$work" /proc/mounts | cut -d' ' -f2 | while read -r m; do fusermount3 -uz "$m" 2>/dev/null || umount -l "$m" 2>/dev/null; done
	rm -rf "$work"
}
trap cleanup EXIT INT TERM

# ---- 1. the golden kits, without FUSE ----------------------------------------------------------
for k in app app-header system; do
	"$M" expect --keys "$keys" "$gold/$k.kit" > "$work/$k.got" 2>"$work/$k.err"
	if grep -v '^#' "$gold/$k.expect" | cmp -s - "$work/$k.got"; then ok "$k.kit: every line of $k.expect"
	else fail "$k.kit differs from $k.expect:"; grep -v '^#' "$gold/$k.expect" | diff - "$work/$k.got" | head -20; fi
	"$M" index "$gold/$k.kit" > "$work/$k.idx"
	if cmp -s "$work/$k.idx" "$gold/$k.index"; then ok "$k.kit: the index is $k.index byte for byte"; else fail "$k.kit: the index differs from $k.index"; fi
done
# the damaged kits: each line of their .expect is a check
for k in bad-chunk bad-root bad-signature bad-image truncated wrong-version unknown-feature bad-name; do
	f=$gold/$k.kit
	n=0; bad=0
	while IFS= read -r line; do
		case $line in '#'*|'') continue ;; esac
		n=$((n + 1))
		set -- $line
		case "$1 $2" in
			"open ok"|"open fail") got=$("$M" open --keys "$keys" "$f" 2>/dev/null | head -1) ;;
			"open-force ok") got="open-force $("$M" open --force --keys "$keys" "$f" 2>/dev/null | head -1 | cut -d' ' -f2-)" ;;
			"open-signed fail") got="open-signed $("$M" open --signed --keys "$keys" "$f" 2>/dev/null | head -1 | cut -d' ' -f2-)" ;;
			"verify fail") got=$("$M" verify --force "$f" 2>/dev/null | head -1) ;;
			"read "*) got="read $2 $("$M" cat "$f" "$2" 2>/dev/null | grep -a '^read fail' | cut -d' ' -f3)" ;;
			"signature "*) got="signature $("$M" open --force --keys "$keys" "$f" 2>/dev/null | sed -n 's/^signature \([a-z]*\).*/\1/p')" ;;
			"probe kit") got="probe kit $("$M" probe "$f" 2>/dev/null | sed -n 's/^kit //p')" ;;
			*) got="(no check for: $line)" ;;
		esac
		[ "$got" = "$line" ] || { fail "$k.kit: want '$line', got '$got'"; bad=1; }
	done < "$gold/$k.expect"
	[ $bad = 0 ] && ok "$k.kit refused as $k.expect says ($n checks)"
done

# ---- 1b. confinement (src/confine.cpp): the profiles on their own, then extract through it ----------
if command -v "${CXX:-c++}" >/dev/null 2>&1; then
	if ${CXX:-c++} -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -Werror -o "$work/confine-test" \
		"$here/confine-test.cpp" "$here/../src/confine.cpp" -lpthread 2>"$work/confine-build.log"; then
		mkdir -p "$work/confine"
		# as root, in a private mount namespace, the unmount guard is checked on a tmpfs as well
		if [ "$(id -u)" = 0 ] && command -v unshare >/dev/null 2>&1 && unshare -m --propagation private true 2>/dev/null; then
			out=$(CONFINE_TEST_MOUNT=1 unshare -m --propagation private "$work/confine-test" "$work/confine" 2>&1); rc=$?
		else
			out=$("$work/confine-test" "$work/confine" 2>&1); rc=$?
		fi
		printf '%s\n' "$out"
		[ $rc = 0 ] || fail "the confinement profiles (tests/confine-test.cpp)"
	else
		cat "$work/confine-build.log"; fail "tests/confine-test.cpp does not build"
	fi
else
	skip "the confinement profiles (no C++ compiler)"
fi
mkdir -p "$work/x"
if "$M" extract "$gold/app.kit" "$work/x" >/dev/null 2>"$work/x.err" && [ "$(find "$work/x" -type f | wc -l)" -gt 0 ] \
	&& "$M" cat "$gold/app.kit" lib/big.txt 2>/dev/null | cmp -s - "$work/x/lib/big.txt"; then
	ok "extract writes the kit's tree beneath DESTDIR from inside its confinement"
else
	cat "$work/x.err"; fail "extract under confinement"
fi

# ---- 2. fuzz -------------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
	if out=$(python3 "$here/fuzz.py" "$M" "$gold" "$keys" "${MKKITFS_FUZZ:-300}" "${MKKITFS_FUZZ_SEED:-1}" 2>&1); then
		ok "$(printf '%s\n' "$out" | tail -1)"
	else printf '%s\n' "$out" | tail -20; fail "fuzz pass"; fi
else
	skip "fuzz pass (no python3)"
fi

# ---- 3. through FUSE -----------------------------------------------------------------------
fuse_ok=0
if [ -c /dev/fuse ] && [ -r /dev/fuse ] && [ -w /dev/fuse ] && { [ "$(id -u)" = 0 ] || command -v fusermount3 >/dev/null 2>&1; }; then
	fuse_ok=1
fi
tcl_ok=0
if command -v tclsh >/dev/null 2>&1 && echo 'exit [catch {package require unix_sockets}]' | tclsh >/dev/null 2>&1; then tcl_ok=1; fi
if [ $fuse_ok = 1 ] && [ $tcl_ok = 1 ]; then
	mkdir -p "$work/fuse"
	if out=$(timeout 300 tclsh "$here/fuse.tcl" "$M" "$gold" "$keys" "$work/fuse" 2>&1); then printf '%s\n' "$out"
	else printf '%s\n' "$out"; fail "FUSE tests"; fi
	if command -v minisign >/dev/null 2>&1 && [ -f "$top/kit/kittrust/kittrust.tcl" ]; then
		mkdir -p "$work/trust"
		if out=$(timeout 120 tclsh "$here/trust.tcl" "$M" "$top" "$work/trust" 2>&1); then printf '%s\n' "$out"
		else printf '%s\n' "$out"; fail "trust kittrust"; fi
	else
		skip "trust kittrust (needs minisign and kit/kittrust)"
	fi
elif [ $fuse_ok = 0 ]; then
	skip "FUSE tests (no usable /dev/fuse, or no fusermount3)"
else
	skip "FUSE tests (no tclsh with unix_sockets)"
fi

# ---- 4. with kits made by kitpack ------------------------------------------------------------
mk4=""
if [ -n "${KITFMT_MK4TCL:-}" ]; then
	mk4=$KITFMT_MK4TCL
elif [ -n "${METAKIT:-}" ] && [ -f "$METAKIT/tcl/mk4tcl.cpp" ] && command -v tclsh >/dev/null 2>&1; then
	tc=$(for f in /usr/lib/tclConfig.sh /usr/lib64/tclConfig.sh /usr/lib/tcl8.6/tclConfig.sh /usr/lib/*/tcl8.6/tclConfig.sh; do [ -f "$f" ] && echo "$f" && break; done)
	if [ -n "$tc" ]; then
		mkdir -p "$work/mk4/Mk4tcl"
		cp "$here/../metakit-config.h" "$work/mk4/config.h"
		# shellcheck disable=SC1090
		inc=$(. "$tc" && echo "$TCL_INCLUDE_SPEC"); stub=$(. "$tc" && echo "$TCL_STUB_LIB_SPEC")
		# shellcheck disable=SC2086
		if ${CXX:-c++} -O1 -w -shared -fPIC -DUSE_TCL_STUBS -I"$work/mk4" -I"$METAKIT/include" -I"$METAKIT/src" $inc \
			-o "$work/mk4/Mk4tcl/libMk4tcl.so" "$METAKIT"/src/*.cpp "$METAKIT/tcl/mk4tcl.cpp" "$METAKIT/tcl/mk4too.cpp" $stub 2>"$work/mk4.log"; then
			echo 'package ifneeded Mk4tcl 2.4.9.7 [list load [file join $dir libMk4tcl.so] Mk4tcl]' > "$work/mk4/Mk4tcl/pkgIndex.tcl"
			mk4=$work/mk4
		fi
	fi
fi
if [ -z "$mk4" ]; then
	skip "kitpack tests: concurrent reads, kitfmt on a big kit, start-up, composition (no Mk4tcl: set METAKIT or KITFMT_MK4TCL)"
else
	# kitpack and kitfmt load this Mk4tcl, whatever else is on auto_path: its pkgIndex.tcl is in the directory itself
	# (build/ci/build-mk4tcl.sh's OUT) or in one below it (DIR/Mk4tcl, as the build above makes it)
	cat > "$work/mk4.tcl" <<EOF
foreach d [list $mk4 {*}[glob -nocomplain -type d -directory $mk4 *]] { if {[file exists \$d/pkgIndex.tcl]} { set dir \$d ; source \$d/pkgIndex.tcl } }
package require Mk4tcl
set script [lindex \$argv 0]
set argv [lrange \$argv 1 end]
set argv0 \$script
source \$script
EOF
	pack() { tclsh "$work/mk4.tcl" "$top/kit/kitfmt/kitpack" -date 1700000000 -q "$@"; }
	# a payload: what this machine has of Tcl/Tk's libraries, plus one big shared library
	pay=$work/payload
	mkdir -p "$pay/lib"
	for d in /usr/share/tcltk /usr/lib/tcl8.6 /usr/share/tcl8.6 /usr/lib/tk8.6 /usr/share/tk8.6 /usr/lib/tcllib*; do
		[ -d "$d" ] && cp -rL "$d" "$pay/lib/" 2>/dev/null
	done
	bigso=$(find /usr/lib -maxdepth 2 -name '*.so*' -type f -size +8M -size -40M 2>/dev/null | head -1)
	[ -n "$bigso" ] && cp -L "$bigso" "$pay/lib/"
	find "$pay" -type l -delete
	printf 'name org.ribbon.test.payload version 1.0 kind app\n' > "$work/payload.manifest"
	if pack -manifest "$work/payload.manifest" "$pay" "$work/payload.kit" 2>"$work/pack.log"; then
		ok "kitpack made a $(du -k "$work/payload.kit" | cut -f1) KiB kit of $(du -sk "$pay" | cut -f1) KiB ($(find "$pay" -type f | wc -l) files)"
		cat > "$work/idx.tcl" <<EOF
lappend auto_path $top/kit/kitfmt
package require kitfmt
set h [kitfmt open [lindex \$argv 0]]
fconfigure stdout -translation binary
puts -nonewline [encoding convertto utf-8 [kitfmt index \$h]]
EOF
		if tclsh "$work/mk4.tcl" "$work/idx.tcl" "$work/payload.kit" > "$work/p.tcl.idx" 2>/dev/null && "$M" index "$work/payload.kit" > "$work/p.cpp.idx" &&
			cmp -s "$work/p.tcl.idx" "$work/p.cpp.idx"; then
			ok "the big kit: mkkitfs's index equals kitfmt's ($(wc -l < "$work/p.cpp.idx") lines)"
		else fail "the big kit: mkkitfs's index differs from kitfmt's"; fi
		if [ $fuse_ok = 1 ] && [ $tcl_ok = 1 ] && command -v python3 >/dev/null 2>&1; then
			mkdir -p "$work/rd"
			MKKITFS=$M tclsh "$tcldir/mkkitfsd" serve -socket "$work/rd/s" -mountpoint "$work/rd/mnt" -linger 0 -log "$work/rd/log" 2>>"$work/rd/log" &
			i=0; while [ ! -S "$work/rd/s" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
			ctl() { tclsh "$tcldir/mkkitfsd" ctl -socket "$work/rd/s" "$@"; }
			d=$(ctl mount "$work/payload.kit" | tr '\t' '\n' | sed -n '/^dir$/{n;p;}')
			ln -sfn "$d" "$work/rd/cur"
			if python3 "$here/reads.py" concurrent "$work/rd/cur" "$pay" 8 "${MKKITFS_CONCURRENT_SECONDS:-8}"; then :; else status=1; fi
			if [ "$(ctl status | tr '\t' '\n' | sed -n '/^bad-reads$/{n;p;}')" = 0 ]; then ok "no bad reads in the server's counters"; else fail "the server counted bad reads"; fi
			if [ "${MKKITFS_BENCH:-0}" = 1 ]; then
				cat > "$work/rd/remount" <<EOF
#!/bin/sh
tclsh $tcldir/mkkitfsd ctl -socket $work/rd/s unmount $work/payload.kit now 1 >/dev/null
d=\$(tclsh $tcldir/mkkitfsd ctl -socket $work/rd/s mount $work/payload.kit | tr '\t' '\n' | sed -n '/^dir\$/{n;p;}')
ln -sfn "\$d" $work/rd/cur
EOF
				chmod +x "$work/rd/remount"
				python3 "$here/reads.py" bench "$work/rd/cur" "$pay" "$work/rd/remount"
			fi
			ctl quit >/dev/null
		else
			skip "concurrent reads (needs FUSE, unix_sockets and python3)"
		fi
	else
		cat "$work/pack.log"; fail "kitpack could not make the test kit"
	fi
	# start-up of a small Tk app from its kit, against bare
	if pack -manifest "$here/tkapp/manifest" "$here/tkapp/src" "$work/tkhello.kit" 2>"$work/pack2.log"; then
		if [ $fuse_ok = 1 ] && [ $tcl_ok = 1 ] && command -v xvfb-run >/dev/null 2>&1 &&
			{ command -v wish || command -v "wish$(echo 'puts [info tclversion]' | tclsh)"; } >/dev/null 2>&1; then
			mkdir -p "$work/st"
			if timeout 300 xvfb-run -a tclsh "$here/startup.tcl" "$M" "$work/tkhello.kit" "$here/tkapp/src" "$work/st" "${MKKITFS_STARTUP_RUNS:-15}"; then :; else status=1; fi
		else
			skip "start-up time (needs FUSE, unix_sockets, xvfb-run and wish)"
		fi
		bw=${MKKITFS_BWRAP:-bwrap}
		if [ $fuse_ok = 1 ] && [ $tcl_ok = 1 ] && command -v "$bw" >/dev/null 2>&1 && "$bw" --help 2>&1 | grep -q -- --overlay-src; then
			mkdir -p "$work/co"
			if timeout 120 tclsh "$here/compose.tcl" "$M" "$gold" "$work/co" "$bw"; then :; else status=1; fi
		else
			skip "composition with bubblewrap (needs FUSE and bubblewrap >= 0.10: set MKKITFS_BWRAP)"
		fi
	else
		cat "$work/pack2.log"; fail "kitpack could not make the Tk app's kit"
	fi
fi
exit $status
