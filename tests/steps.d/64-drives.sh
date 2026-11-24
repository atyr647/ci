#!/bin/bash
# ribbon-drives (srcpkgs/ribbon-tools/files/bin/ribbon-drives) on a fake root with stand-ins for blkid and a "device"
# file: every drive mounts nosuid,nodev; a label of . or .. cannot make the mount point /mnt/games/.. (= /mnt); an
# fstab without a final newline keeps its last line intact; fixup-fstab replaces the file whole and keeps its mode.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=1; }
mkdir -p "$T/bin" "$T/root/etc" "$T/lib"
cp srcpkgs/ribbon-tools/files/lib/*.sh "$T/lib/"
# the test runs as whoever runs the suite (CI's runner is not root): need_root lets the fake root through
printf '\nneed_root() { :; }\n' >> "$T/lib/common.sh"
# the script reads its library from /usr/lib/ribbon and wants a block device: the copy reads $T/lib and a plain file
sed -e "s|/usr/lib/ribbon/common.sh|$T/lib/common.sh|" -e 's/\[ -b "\$dev" \]/[ -e "$dev" ]/' \
	srcpkgs/ribbon-tools/files/bin/ribbon-drives > "$T/ribbon-drives"
cat > "$T/bin/blkid" <<'EOS'
#!/bin/sh
# blkid -s TYPE|UUID|LABEL -o value DEV: the answers are in files beside the device file
f=$3; k=$2
cat "$DEV_ANSWERS/$k" 2>/dev/null; exit 0
EOS
sed -i 's|^f=\$3; k=\$2|k=$2|' "$T/bin/blkid"
chmod +x "$T/bin/blkid"
touch "$T/dev1"
run() { # TYPE UUID LABEL [name]
	mkdir -p "$T/ans"; printf '%s' "$1" > "$T/ans/TYPE"; printf '%s' "$2" > "$T/ans/UUID"; printf '%s' "$3" > "$T/ans/LABEL"
	DEV_ANSWERS=$T/ans PATH=$T/bin:$PATH RIBBON_ROOT=$T/root SUDO_USER=root bash "$T/ribbon-drives" add "$T/dev1" ${4:+"$4"} 2>&1
}
# session_user is the real library's: SUDO_USER=root makes it the current user, whose uid lookups always work
printf 'UUID=aaaa / btrfs defaults 0 0\n' > "$T/root/etc/fstab"
out=$(run ext4 1111 Games Big 2>&1) || { echo "$out"; bad "add ext4 failed"; }
line=$(grep 'ribbon-drives:Big' "$T/root/etc/fstab")
case $line in *,nosuid,nodev,*) ok "an ext4 drive mounts nosuid,nodev" ;; *) bad "ext4 options: $line" ;; esac
for fs in btrfs exfat vfat ntfs; do
	rm -f "$T/root/etc/fstab"; printf 'UUID=aaaa / btrfs defaults 0 0\n' > "$T/root/etc/fstab"
	run $fs 2222 L X >/dev/null 2>&1
	l=$(grep 'ribbon-drives:X' "$T/root/etc/fstab")
	case $l in *,nosuid,nodev,*) ok "a $fs drive mounts nosuid,nodev" ;; *) bad "$fs options: $l" ;; esac
done
for lab in .. . ''; do
	printf 'UUID=aaaa / btrfs defaults 0 0\n' > "$T/root/etc/fstab"
	run ext4 3333 "$lab" >/dev/null 2>&1
	l=$(grep 'ribbon-drives:' "$T/root/etc/fstab" | awk '{print $2}')
	case $l in /mnt/games/games) ok "label '$lab' becomes the name games, not a path up from /mnt/games" ;; *) bad "label '$lab' gave mount point '$l'" ;; esac
done
printf 'UUID=aaaa / btrfs defaults 0 0\nUUID=bbbb /boot vfat defaults 0 2' > "$T/root/etc/fstab"   # no final newline
run ext4 4444 Games Z >/dev/null 2>&1
if [ "$(sed -n 2p "$T/root/etc/fstab")" = "UUID=bbbb /boot vfat defaults 0 2" ] && [ "$(sed -n 3p "$T/root/etc/fstab" | cut -d' ' -f2)" = /mnt/games/Z ]; then
	ok "an fstab with no final newline keeps its last line apart from the new entry"
else bad "the new entry joined the last line: $(cat "$T/root/etc/fstab")"; fi
printf 'UUID=aaaa / btrfs defaults 0 0\nUUID=cccc /mnt/games/Old ext4 defaults 0 0\n' > "$T/root/etc/fstab"
chmod 640 "$T/root/etc/fstab"
ino=$(stat -c %i "$T/root/etc/fstab")
PATH=$T/bin:$PATH RIBBON_ROOT=$T/root bash "$T/ribbon-drives" fixup-fstab >/dev/null 2>&1
if grep -q '^UUID=cccc /mnt/games/Old ext4 defaults,nofail 0 0$' "$T/root/etc/fstab" && [ "$(stat -c %a "$T/root/etc/fstab")" = 640 ] \
	&& [ "$(stat -c %i "$T/root/etc/fstab")" != "$ino" ] && [ ! -e "$T/root/etc/fstab.ribbon-tmp" ]; then
	ok "fixup-fstab adds nofail, replaces the file whole (renamed in), keeps its mode, leaves no temp file"
else bad "fixup-fstab: $(cat "$T/root/etc/fstab") mode $(stat -c %a "$T/root/etc/fstab")"; fi
exit $fails
