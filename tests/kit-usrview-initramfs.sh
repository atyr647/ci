#!/bin/sh
# The initramfs mounts the merged erofs /usr view of the system kits (srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview,
# docs/SYSTEM-UPDATES.md 7.2): its pre-pivot hook run on a fake root with stand-ins for losetup and mount that log
# what they are asked. The current view's kits attached read-only at their offsets in the device list's order, the
# view mounted on the root's /usr with them as its devices, the devices detached again (autoclear); nothing done
# without a view; a bad or missing list, a path that is not plain, a kit file that is gone, a device that does not
# attach (the ones before it detached) and a mount that fails each leave /usr as it is and say why. With dracut
# installed, the module's check() is also run. Runs as any user; changes nothing outside its temporary directory.
set -u
cd "$(dirname "$0")/.." || exit 1
HOOK=$PWD/srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview/ribbon-usrview.sh
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
# losetup: --find ... prints the next /dev/loopN (fails for a path named in $T/fail-attach); -d logs
cat > "$T/bin/losetup" <<'SH'
#!/bin/sh
echo "losetup $*" >> "$STANDIN/log"
case $1 in
-d) exit 0 ;;
esac
for a in "$@"; do last=$a; done
if [ -f "$STANDIN/fail-attach" ] && [ "$(cat "$STANDIN/fail-attach")" = "$last" ]; then echo "losetup: $last: failed to set up loop device" >&2; exit 1; fi
n=$(cat "$STANDIN/next" 2>/dev/null || echo 0)
echo $((n + 1)) > "$STANDIN/next"
echo "/dev/loop$n"
SH
cat > "$T/bin/mount" <<'SH'
#!/bin/sh
echo "mount $*" >> "$STANDIN/log"
[ -f "$STANDIN/fail-mount" ] && { echo "mount: wrong fs type" >&2; exit 32; }
exit 0
SH
chmod 755 "$T/bin/losetup" "$T/bin/mount"
tab=$(printf '\t')
# a fresh fake root; view N over the kits given as NAME:OFFSET:LENGTH
newroot() {
	rm -rf "$T/root" "$T/run" "$T/log" "$T/next" "$T/kmsg" "$T/fail-attach" "$T/fail-mount"
	mkdir -p "$T/root/var/lib/kit/system/usr" "$T/root/usr/bin" "$T/run"
	: > "$T/log"
}
view() {
	n=$1; shift
	d=$T/root/var/lib/kit/system/usr
	echo "$n" > "$d/current"
	echo erofs > "$d/view-$n.erofs"
	echo "ribbon-usr-view 1" > "$d/view-$n.erofs.devices"
	for k in "$@"; do
		name=${k%%:*}; rest=${k#*:}; off=${rest%%:*}; len=${rest#*:}
		mkdir -p "$T/root/var/lib/kit/store/r-$name"
		echo kit > "$T/root/var/lib/kit/store/r-$name/kit"
		printf 'kit%s%s%s%s%s%s%s%s%s%s%s%s\n' "$tab" "/var/lib/kit/store/r-$name/kit" "$tab" "$off" "$tab" "$len" "$tab" "r-$name" "$tab" "org.ribbon.$name" "$tab" "1.0" \
			>> "$d/view-$n.erofs.devices"
	done
}
hook() { STANDIN=$T PATH=$T/bin:$PATH NEWROOT=$T/root RIBBON_RUN=$T/run RIBBON_KMSG=$T/kmsg sh "$HOOK" 2>>"$T/stderr"; }
says() { grep -q "$1" "$T/kmsg" 2>/dev/null; }
logged() { grep -qxF "$1" "$T/log"; }
lines() { grep -c "$1" "$T/log"; }
R=$T/root

# no view yet: nothing is touched
newroot
hook
if [ ! -s "$T/log" ] && [ ! -f "$T/run/usr-view" ]; then ok "no view (no system kit yet): nothing attached or mounted, /usr left as it is"; else bad "no view: $(cat "$T/log")"; fi

# the current view of two kits
newroot
view 3 glibc:4096:8192 openssl:12288:409600
echo 2 > "$R/var/lib/kit/system/usr/view-2.erofs"   # an older view: not the current one
hook
if logged "losetup --find --show --read-only --offset 4096 --sizelimit 8192 $R/var/lib/kit/store/r-glibc/kit" &&
	logged "losetup --find --show --read-only --offset 12288 --sizelimit 409600 $R/var/lib/kit/store/r-openssl/kit" &&
	[ "$(sed -n 1p "$T/log")" = "losetup --find --show --read-only --offset 4096 --sizelimit 8192 $R/var/lib/kit/store/r-glibc/kit" ]; then
	ok "each kit's image attached read-only at its sealed offset and length, in the list's order"
else bad "attach: $(cat "$T/log")"; fi
if logged "mount -t erofs -o ro,device=/dev/loop0,device=/dev/loop1 $R/var/lib/kit/system/usr/view-3.erofs $R/usr"; then
	ok "the current view (3) mounted read-only on the new root's /usr, its devices named in order"
else bad "mount: $(cat "$T/log")"; fi
if [ "$(sed -n '$p' "$T/log")" = "losetup -d /dev/loop1" ] && logged "losetup -d /dev/loop0" && [ "$(grep -n '^mount' "$T/log" | cut -d: -f1)" -lt "$(grep -n 'losetup -d' "$T/log" | head -1 | cut -d: -f1)" ]; then
	ok "the loop devices detached after the mount (autoclear: the mount keeps them)"
else bad "detach: $(cat "$T/log")"; fi
if [ "$(cat "$T/run/usr-view")" = 3 ] && says "/usr is view 3 (2 system kits)"; then ok "what the boot did: /run/ribbon/usr-view and the kernel log"; else bad "record: $(cat "$T/run/usr-view" "$T/kmsg" 2>&1)"; fi

# the device list as kitd writes it (lib/mount.tcl DevicesText) is the one the hook reads
if command -v tclsh8.6 >/dev/null 2>&1; then
	newroot
	mkdir -p "$R/var/lib/kit/store/r-a" "$R/var/lib/kit/store/r-b"
	: > "$R/var/lib/kit/store/r-a/kit"; : > "$R/var/lib/kit/store/r-b/kit"
	echo 7 > "$R/var/lib/kit/system/usr/current"; : > "$R/var/lib/kit/system/usr/view-7.erofs"
	cat > "$T/devices.tcl" <<'TCL'
lassign $argv lib out
source -encoding utf-8 $lib/core.tcl
::kit::need mount
set f [open $out w]
puts -nonewline $f [::kit::mount::DevicesText [list \
	[dict create path /var/lib/kit/store/r-a/kit offset 8192 length 4096 root r-a name org.ribbon.a version 1.2] \
	[dict create path /var/lib/kit/store/r-b/kit offset 4096 length 12288 root r-b name org.ribbon.b version 3]]]
close $f
TCL
	tclsh8.6 "$T/devices.tcl" "$PWD/srcpkgs/ribbon-kit/files/lib" "$R/var/lib/kit/system/usr/view-7.erofs.devices"
	hook
	if logged "mount -t erofs -o ro,device=/dev/loop0,device=/dev/loop1 $R/var/lib/kit/system/usr/view-7.erofs $R/usr" &&
		logged "losetup --find --show --read-only --offset 8192 --sizelimit 4096 $R/var/lib/kit/store/r-a/kit"; then
		ok "a device list written by kitd's mount.tcl is the one the hook mounts"
	else bad "mount.tcl's list: $(cat "$T/log" "$T/kmsg" 2>&1)"; fi
fi

# refusals: nothing attached, nothing mounted, /usr as it is
refused() { # what, reason-in-kmsg
	if [ ! -s "$T/log" ] && says "$2" && grep -q '^none: ' "$T/run/usr-view"; then ok "$1: nothing attached or mounted, and it says why"; else bad "$1: log=$(cat "$T/log") kmsg=$(cat "$T/kmsg" 2>/dev/null)"; fi
}
newroot; view 4 glibc:4096:8192; echo "4x" > "$R/var/lib/kit/system/usr/current"; hook
refused "current is not a number" "holds no view number"
newroot; view 4 glibc:4096:8192; rm "$R/var/lib/kit/system/usr/view-4.erofs.devices"; hook
refused "the view's device list is missing" "its files are missing"
newroot; view 4 glibc:4096:8192; sed -i '1s/.*/ribbon-usr-view 2/' "$R/var/lib/kit/system/usr/view-4.erofs.devices"; hook
refused "another device list version" "not a view's device list"
newroot; view 4 glibc:4096:8192; sed -i '2s/\t4096\t/\t-1\t/' "$R/var/lib/kit/system/usr/view-4.erofs.devices"; hook
refused "an offset that is not a number" "a bad line"
newroot; view 4 glibc:4096:8192; printf 'kit\t/var/lib/kit/../../etc/shadow\t0\t4096\tr\tx\t1\n' >> "$R/var/lib/kit/system/usr/view-4.erofs.devices"; hook
refused "a path with .. in it" "is not plain"
newroot; view 4 glibc:4096:8192; printf 'kit\tvar/lib/kit/store/r-glibc/kit\t0\t4096\tr\tx\t1\n' >> "$R/var/lib/kit/system/usr/view-4.erofs.devices"; hook
refused "a relative path" "is not absolute"
newroot; view 4 glibc:4096:8192 openssl:12288:409600; rm "$R/var/lib/kit/store/r-openssl/kit"; hook
refused "a kit file that is gone" "org.ribbon.openssl (/var/lib/kit/store/r-openssl/kit) is missing"
newroot; view 4; hook
refused "a view that names no kit" "names no kit"

# a device that does not attach: the ones before it are detached, nothing mounted
newroot; view 5 glibc:4096:8192 openssl:12288:409600 zlib:4096:4096
echo "$R/var/lib/kit/store/r-openssl/kit" > "$T/fail-attach"
hook
if logged "losetup -d /dev/loop0" && [ "$(lines '^mount')" = 0 ] && [ "$(lines 'r-zlib')" = 0 ] && says "org.ribbon.openssl's image could not be attached"; then
	ok "a kit that does not attach: the devices before it detached, nothing mounted, the rest not tried"
else bad "attach failure: $(cat "$T/log")"; fi

# the mount fails: its devices are detached all the same
newroot; view 6 glibc:4096:8192 openssl:12288:409600
: > "$T/fail-mount"
hook
if logged "losetup -d /dev/loop0" && logged "losetup -d /dev/loop1" && says "could not be mounted" && grep -q '^none: view 6 could not be mounted' "$T/run/usr-view"; then
	ok "a view that does not mount: its devices detached, /usr left as it is, and why"
else bad "mount failure: $(cat "$T/log")"; fi

# the dracut module: shell that parses; dracut's own check() where dracut is installed
for f in srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview/*.sh; do
	if bash -n "$f"; then ok "$(basename "$f") parses"; else bad "$f does not parse"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -s sh "$HOOK" && shellcheck srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview/module-setup.sh; then ok "shellcheck: the hook and module-setup.sh are clean"; else bad "shellcheck"; fi
fi
exit $fail
