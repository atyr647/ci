#!/bin/sh
# installed-test.sh - Ribbon installed from the live ISO by its real installer, booted from the disk, and its system
# tools checked on the running system (the installed job of build/ci/labwc020-tests.yml). Three QEMU boots, UEFI
# (OVMF) throughout, one 40 GiB disk:
#   1. the live ISO, its kernel and initramfs started directly with ribbon.ci.install=1 and one more initramfs
#      archive (initrd-extra below): a dracut pre-pivot hook that puts build/ci/installed/install in the live
#      system as a dinit service. It runs ribbon-install onto the disk (btrfs, Limine, zram; the defaults) and puts
#      build/ci/installed/probe in the installed system.
#   2. the disk, through the firmware and Limine: the probe checks postinstall's work, ribbon-swap, ribbon-reserve,
#      ribbon-doctor, then runs ribbon-update for real and restarts.
#   3. the disk again: the updated system comes up and ribbon-boot-ok marks it good.
# The guest's lines start "RIBBON-CI " (serial console). OUTDIR gets installed-1.log .. installed-3.log (serial),
# installed-probe.txt and installed-summary.txt: one RESULT line per area (install, boot, postinstall, swap, reserve,
# doctor, update, after-update), "ok" only when the area had checks and none failed.
#
#   sudo build/ci/installed-test.sh ISO OUTDIR
#   build/ci/installed-test.sh initrd-extra DIR OUT   the extra initramfs archive (cpio, newc) of the files in DIR
#   build/ci/installed-test.sh summarize OUTDIR       the RESULT lines from OUTDIR's serial logs
#   build/ci/installed-test.sh fetch-iso DIR          (CI) wait for the ribbon-image run of this commit to upload its
#                                                     ISO, and download it into DIR (gh, GITHUB_TOKEN)
# INSTALL_SECONDS (default 1800), PROBE_SECONDS (default 2400) and AFTER_SECONDS (default 900) bound the boots.
set -u
H=$(cd "$(dirname "$0")" && pwd)
AREAS="install boot postinstall swap reserve doctor update after-update"

initrd_extra() { # DIR OUT: the hook and the guest's files as a newc cpio, to be put after the ISO's own initramfs
	d=$1; out=$2
	mkdir -p "$d/ribbon-ci" "$d/lib/dracut/hooks/pre-pivot"
	cp "$H/installed/install" "$H/installed/probe" "$d/ribbon-ci/"
	chmod 755 "$d/ribbon-ci/install" "$d/ribbon-ci/probe"
	cat > "$d/ribbon-ci/ribbon-ci-install" <<-'EOF'
		# CI only (build/ci/installed-test.sh): install Ribbon onto /dev/vda with ribbon-install
		type = process
		command = /usr/lib/ribbon-ci/install
		restart = false
		depends-on: loginready
	EOF
	cat > "$d/ribbon-ci/ribbon-ci-installed" <<-'EOF'
		# CI only (build/ci/installed-test.sh): the installed system's checks
		type = process
		command = /usr/lib/ribbon-ci/probe
		restart = false
		depends-on: loginready
	EOF
	# sourced by dracut's init once the live root is mounted at $NEWROOT (writable: an overlay)
	cat > "$d/lib/dracut/hooks/pre-pivot/99-ribbon-ci.sh" <<-'EOF'
		#!/bin/sh
		# CI only (build/ci/installed-test.sh): with ribbon.ci.install=1, the install service in the live system.
		# (RIBBON_CI_* stand in for the initramfs's paths in tests/steps.d/93-ci-labwc020.sh.)
		src=${RIBBON_CI_SRC:-/ribbon-ci}
		if grep -qw 'ribbon.ci.install=1' "${RIBBON_CI_CMDLINE:-/proc/cmdline}" && [ -d "$NEWROOT/etc/dinit.d" ]; then
			mkdir -p "$NEWROOT/usr/lib/ribbon-ci" "$NEWROOT/etc/dinit.d/boot.d"
			cp "$src/install" "$src/probe" "$src/ribbon-ci-installed" "$NEWROOT/usr/lib/ribbon-ci/"
			chmod 755 "$NEWROOT/usr/lib/ribbon-ci/install" "$NEWROOT/usr/lib/ribbon-ci/probe"
			cp "$src/ribbon-ci-install" "$NEWROOT/etc/dinit.d/ribbon-ci-install"
			ln -sfn ../ribbon-ci-install "$NEWROOT/etc/dinit.d/boot.d/ribbon-ci-install"
			echo "ribbon-ci: the install service is in the live system" > "${RIBBON_CI_KMSG:-/dev/kmsg}"
		fi
	EOF
	chmod 755 "$d/lib/dracut/hooks/pre-pivot/99-ribbon-ci.sh"
	# only the new directory and the files, owned by root: the archive must not replace /lib (a symlink to usr/lib in
	# the initramfs). The newc format (the kernel's initramfs format), written here so that no cpio is needed.
	cd "$d" && { find ribbon-ci; echo lib/dracut/hooks/pre-pivot/99-ribbon-ci.sh; } | LC_ALL=C sort |
		python3 -c '
import os, sys
out = sys.stdout.buffer
def entry(name, mode, data, ino):
    n = name.encode() + b"\0"
    out.write(b"070701" + b"".join(b"%08X" % v for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(n), 0)))
    out.write(n + b"\0" * ((4 - (110 + len(n)) % 4) % 4))
    out.write(data + b"\0" * ((4 - len(data) % 4) % 4))
for i, p in enumerate(l.strip() for l in sys.stdin):
    st = os.lstat(p)
    data = b"" if os.path.isdir(p) else open(p, "rb").read()
    entry(p, st.st_mode, data, i + 1)
entry("TRAILER!!!", 0, b"", 0)
' "$d" > "$out" && [ -s "$out" ]
}

summarize() { # OUTDIR
	o=$1
	cat "$o"/installed-[123].log 2>/dev/null | tr -d '\r' | grep -a 'RIBBON-CI ' | sed 's/^.*RIBBON-CI /RIBBON-CI /' > "$o/installed-probe.txt"
	for a in $AREAS; do
		# install's lines say "install: ...", the probe's "[area] ..."
		if [ "$a" = install ]; then tag='install:'; else tag="\\[$a\\]"; fi
		nok=$(grep -cE "^RIBBON-CI ok +$tag" "$o/installed-probe.txt" || :)
		fails=$(grep -E "^RIBBON-CI FAIL +$tag" "$o/installed-probe.txt" | sed 's/^RIBBON-CI FAIL *//' | head -n4 | tr '\n' ';' | sed 's/;$//; s/;/; /g')
		if [ -n "$fails" ]; then echo "RESULT installed-$a: FAILED ($fails)"
		elif [ "$nok" -eq 0 ]; then echo "RESULT installed-$a: FAILED (no check ran)"
		else echo "RESULT installed-$a: ok ($nok checks)"; fi
	done
}

fetch_iso() { # DIR
	d=$1; repo=${GITHUB_REPOSITORY:?}; sha=${GITHUB_SHA:?}
	deadline=$(( $(date +%s) + ${ISO_WAIT_MINUTES:-200} * 60 ))
	while :; do
		id=$(gh api "repos/$repo/actions/workflows/ribbon-image.yml/runs?head_sha=$sha&per_page=1" --jq '.workflow_runs[0].id // empty' 2>/dev/null)
		if [ -n "$id" ]; then
			gh api "repos/$repo/actions/runs/$id/artifacts" --jq '.artifacts[].name' 2>/dev/null | grep -qx ribbon-iso && break
			[ "$(gh api "repos/$repo/actions/runs/$id" --jq .status 2>/dev/null)" = completed ] && {
				echo "fetch-iso: the ribbon-image run $id finished without an ISO" >&2; return 1; }
		fi
		[ "$(date +%s)" -lt "$deadline" ] || { echo "fetch-iso: no ISO for $sha in time" >&2; return 1; }
		sleep 60
	done
	mkdir -p "$d"
	gh run download "$id" -R "$repo" -n ribbon-iso -D "$d" && echo "fetch-iso: run $id"
}

case ${1:-} in
initrd-extra) initrd_extra "${2:?usage: installed-test.sh initrd-extra DIR OUT}" "${3:?}"; exit $? ;;
summarize) summarize "${2:?usage: installed-test.sh summarize OUTDIR}"; exit 0 ;;
fetch-iso) fetch_iso "${2:?usage: installed-test.sh fetch-iso DIR}"; exit $? ;;
esac

ISO=${1:?usage: installed-test.sh ISO OUTDIR}; OUT=${2:?usage: installed-test.sh ISO OUTDIR}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
W=$(mktemp -d)
QPID=
trap 'kill "$QPID" 2>/dev/null; rm -rf "$W"' EXIT
sum=$OUT/installed-summary.txt; : > "$sum"
fatal() { echo "RESULT installed-install: FAILED ($*)" | tee -a "$sum"; exit 1; }

# the firmware: OVMF's code and a copy of its variables (the installer's boot entry lands there)
CODE=; VARS=
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd; do [ -r "$c" ] && { CODE=$c; break; }; done
for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd; do [ -r "$v" ] && { VARS=$v; break; }; done
[ -n "$CODE" ] && [ -n "$VARS" ] || fatal "no OVMF firmware on the host (ovmf)"
cp "$VARS" "$W/vars.fd"
FW="-drive if=pflash,format=raw,readonly=on,file=$CODE -drive if=pflash,format=raw,file=$W/vars.fd"
ACCEL="-accel tcg -cpu max"; [ -w /dev/kvm ] && ACCEL="-accel kvm -cpu host"

# the ISO's kernel, initramfs and command line (as build/ci/boot-test.sh reads them)
xorriso -osirrox on -indev "$ISO" -extract /boot "$W/boot" >/dev/null 2>&1
K=$(find "$W/boot" -maxdepth 1 -name 'vmlinuz*' | head -n1); I=$(find "$W/boot" -maxdepth 1 -name 'initrd*' | head -n1)
[ -n "$K" ] && [ -n "$I" ] || fatal "no kernel or initramfs in the ISO"
CMD=$(find "$W/boot" -name '*.cfg' -exec cat {} + 2>/dev/null | sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' |
	grep -hoE 'root=live:[^"]*' | head -n1 | sed 's/[[:space:]]*initrd=.*//; s/@@[A-Z_]*@@//g; s/[[:space:]]*$//')
[ -n "$CMD" ] || fatal "no live command line in the ISO's boot menus"
CMD="$CMD console=tty0 console=ttyS0,115200 ribbon.ci.install=1"
initrd_extra "$W/extra" "$W/extra.cpio" || fatal "the extra initramfs archive"
# the kernel unpacks one archive after another; an uncompressed one must start on a 4-byte boundary (zeros between
# archives are skipped)
cat "$I" > "$W/initrd"
pad=$(( (4 - $(wc -c < "$W/initrd") % 4) % 4 ))
[ "$pad" -eq 0 ] || head -c "$pad" /dev/zero >> "$W/initrd"
cat "$W/extra.cpio" >> "$W/initrd"
truncate -s 40G "$W/disk.raw"

# boot N SECONDS DONE-LINE QEMU-ARGS...: one boot; it ends when the guest powers off or restarts (-no-reboot),
# or SECONDS after the start, or 120 s after DONE-LINE
boot() {
	n=$1; secs=$2; line=$3; shift 3
	log=$OUT/installed-$n.log; : > "$log"
	# shellcheck disable=SC2086
	qemu-system-x86_64 $ACCEL -m 6144 -smp 4 -machine q35 $FW "$@" \
		-drive file="$W/disk.raw",format=raw,if=virtio \
		-device virtio-vga -display none -device virtio-rng-pci \
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
		-serial "file:$log" -no-reboot &
	QPID=$!
	t=0; seen=
	while [ $t -lt "$secs" ] && kill -0 "$QPID" 2>/dev/null; do
		sleep 5; t=$((t + 5))
		# after DONE-LINE the guest syncs and powers off or restarts by itself: 120 s more at most
		if [ -z "$seen" ] && grep -aq "RIBBON-CI $line" "$log" 2>/dev/null; then seen=1; secs=$((t + 120)); fi
	done
	kill -0 "$QPID" 2>/dev/null && { echo "boot $n: still running after $t s; stopped"; kill "$QPID"; }
	wait "$QPID" 2>/dev/null; QPID=
	echo "boot $n: $t s"
}

echo "boot 1: the live ISO installs onto the disk ($ACCEL)"
boot 1 "${INSTALL_SECONDS:-1800}" install-done -kernel "$K" -initrd "$W/initrd" -append "$CMD" \
	-drive file="$ISO",media=cdrom,readonly=on,if=none,id=cd -device ide-cd,drive=cd
grep -aq 'RIBBON-CI ok   install: the probe is in the installed system' "$OUT/installed-1.log" || {
	summarize "$OUT" > "$sum"; cat "$sum"; tail -n 60 "$OUT/installed-1.log"; exit 1; }
echo "boot 2: the installed system (firmware, Limine) with the probe"
boot 2 "${PROBE_SECONDS:-2400}" "done"
echo "boot 3: the system after ribbon-update"
boot 3 "${AFTER_SECONDS:-900}" "done"
summarize "$OUT" > "$sum"
cat "$sum"
! grep -q '^RESULT [a-z-]*: FAILED' "$sum"
