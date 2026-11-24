#!/bin/sh
# Is the FUSE server still needed?  The same payload served the other ways that are open to app
# kits, measured with reads.py bench (docs/MKKITFS.md, "Is the FUSE server still needed?").
#
#   sh alternatives.sh MKKITFS KIT PAYLOAD_DIR WORKDIR      (as root: drop_caches, loop mounts)
#
#   extract     `mkkitfs extract` into a store directory (unprivileged), then plain files
#   erofs       an erofs image (lz4hc) mounted read-only through a loop device (root), and
#               whether an unprivileged user namespace may mount it
#   squashfuse  a squashfs image (gzip) served by squashfuse (unprivileged FUSE, upstream code)
#   mkkitfs     the kit through mkkitfsd + mkkitfs
# composefs is not measured: it needs fs-verity in the kernel and the composefs tools, and the
# script says which of them this machine lacks.
set -u
M=$1 KIT=$2 PAY=$3 W=$4
here=$(cd "$(dirname "$0")" && pwd)
tcldir=$here/../tcl
mkdir -p "$W"
ms() { python3 -c 'import sys,time; print("%.0f" % ((time.time() - float(sys.argv[1])) * 1000))' "$1"; }
now() { python3 -c 'import time; print(time.time())'; }
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
echo "== payload: $(find "$PAY" -type f | wc -l) files, $(du -sm "$PAY" | cut -f1) MB; kit $(du -m "$KIT" | cut -f1) MB"

echo "== extract (unprivileged; integrity checked once, at extraction)"
rm -rf "$W/x"; mkdir -p "$W/x"; drop; t=$(now)
"$M" extract "$KIT" "$W/x" >/dev/null 2>&1 || echo "  (extract refused: $("$M" extract "$KIT" "$W/x2" 2>&1 | tail -1))"
sync; echo "  extract, cold: $(ms "$t") ms; on disk: $(du -sm "$W/x" | cut -f1) MB beside the $(du -m "$KIT" | cut -f1) MB kit"

echo "== erofs, loop mount (root)"
if command -v mkfs.erofs >/dev/null 2>&1; then
	rm -f "$W/p.erofs"; t=$(now)
	mkfs.erofs -zlz4hc -T 1700000000 "$W/p.erofs" "$PAY" >/dev/null 2>&1
	echo "  mkfs.erofs -zlz4hc: $(ms "$t") ms, image $(du -m "$W/p.erofs" | cut -f1) MB"
	mkdir -p "$W/e"
	if command -v unshare >/dev/null 2>&1; then
		r=$(unshare -Urm sh -c "mount -t erofs -o ro,loop '$W/p.erofs' '$W/e' 2>&1 && echo mounted" 2>&1 | head -1)
		echo "  unprivileged (user namespace) mount: $r"
	fi
	drop; t=$(now)
	mount -t erofs -o ro,loop "$W/p.erofs" "$W/e" && echo "  mount (loop setup included), cold: $(ms "$t") ms"
	printf '#!/bin/sh\numount %s && mount -t erofs -o ro,loop %s %s\n' "$W/e" "$W/p.erofs" "$W/e" > "$W/e.remount"; chmod +x "$W/e.remount"
	python3 "$here/reads.py" bench "$W/e" "$PAY" "$W/e.remount"
	umount "$W/e"
fi

echo "== squashfuse (unprivileged FUSE, squashfs gzip)"
if command -v mksquashfs >/dev/null 2>&1 && command -v squashfuse >/dev/null 2>&1; then
	rm -f "$W/p.sqfs"; mksquashfs "$PAY" "$W/p.sqfs" -comp gzip -quiet -no-progress >/dev/null 2>&1
	echo "  image $(du -m "$W/p.sqfs" | cut -f1) MB"
	mkdir -p "$W/q"; drop; t=$(now)
	squashfuse "$W/p.sqfs" "$W/q" && echo "  mount, cold: $(ms "$t") ms"
	printf '#!/bin/sh\nfusermount3 -u %s 2>/dev/null || umount %s; squashfuse %s %s\n' "$W/q" "$W/q" "$W/p.sqfs" "$W/q" > "$W/q.remount"; chmod +x "$W/q.remount"
	python3 "$here/reads.py" bench "$W/q" "$PAY" "$W/q.remount"
	fusermount3 -u "$W/q" 2>/dev/null || umount "$W/q"
fi

echo "== mkkitfs (mkkitfsd: one FUSE server per session)"
MKKITFS=$M tclsh "$tcldir/mkkitfsd" serve -socket "$W/s" -mountpoint "$W/mnt" -linger 0 -log "$W/log" 2>>"$W/log" &
i=0; while [ ! -S "$W/s" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
ctl() { tclsh "$tcldir/mkkitfsd" ctl -socket "$W/s" "$@"; }
drop; t=$(now)
d=$(ctl mount "$KIT" | tr '\t' '\n' | sed -n '/^dir$/{n;p;}')
echo "  mount (seal, isolated parse, index, root), cold: $(ms "$t") ms"
ln -sfn "$d" "$W/cur"
cat > "$W/k.remount" <<EOF
#!/bin/sh
tclsh $tcldir/mkkitfsd ctl -socket $W/s unmount $KIT now 1 >/dev/null
d=\$(tclsh $tcldir/mkkitfsd ctl -socket $W/s mount $KIT | tr '\t' '\n' | sed -n '/^dir\$/{n;p;}')
ln -sfn "\$d" $W/cur
EOF
chmod +x "$W/k.remount"
python3 "$here/reads.py" bench "$W/cur" "$PAY" "$W/k.remount"
ctl quit >/dev/null

echo "== composefs"
missing=""
[ -r /proc/config.gz ] && ! zcat /proc/config.gz | grep -q '^CONFIG_FS_VERITY=y' && missing="$missing fs-verity (CONFIG_FS_VERITY is off)"
command -v mkcomposefs >/dev/null 2>&1 || missing="$missing mkcomposefs (not installed)"
grep -q erofs /proc/filesystems || missing="$missing erofs"
if [ -n "$missing" ]; then echo "  not measured: this machine lacks$missing"; else echo "  available, not measured by this script"; fi
