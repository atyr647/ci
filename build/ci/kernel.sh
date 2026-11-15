#!/bin/sh
# kernel.sh - Ribbon's kernel, its module and firmware kits, and erofs-utils, built in CI only (build/ci/kernel.yml).
# Third-party source (the kernel, erofs-utils, the out-of-tree modules) is never built on a development machine.
#
# One build per key: the key is a hash of everything that goes into the build (srcpkgs/ribbon-kernel,
# srcpkgs/erofs-utils, build/kernel/config, this script, and kitpack with its Mk4tcl, which pack the kits); its
# result is the CI repository's release named by `kernel.sh tag`, which the image job fetches (`kernel.sh fetch`)
# instead of building the kernel itself.
#
#   kernel.sh key                    the build key (64 hex digits)
#   kernel.sh tag                    the release tag: kernel-<version>_<revision>-<first 12 digits of the key>
#   kernel.sh kver                   the kernel release the template builds: <version>-ribbon_<revision>
#   kernel.sh prepare VP             copy the templates into the void-packages tree VP, with build/kernel/config as
#                                    srcpkgs/ribbon-kernel/files/config
#   kernel.sh build OUT              (Void, as a member of xbuilder) bootstrap xbps-src in out/void-packages, build
#                                    erofs-utils and ribbon-kernel, and index them in OUT/repo
#   kernel.sh modules OUT            (Void, root) build the out-of-tree modules Ribbon supports (MODULE_KITS) with DKMS
#                                    against ribbon-kernel-headers; their trees go to OUT/trees/<kit>
#   kernel.sh firmware OUT           (Void, root) the firmware (FIRMWARE_PKGS) without the datacenter, switch and
#                                    access-point files (FIRMWARE_DROP), recompressed to xz, in OUT/trees/firmware
#   kernel.sh images OUT             (Void, root) one erofs image per tree (OUT/images/<kit>.erofs) with the mkfs.erofs
#                                    just built, each verified in full against its tree (D68 A)
#   kernel.sh fw-xz TREE             recompress TREE's .zst firmware to .xz in place (links follow their targets)
#   kernel.sh verify-image IMG TREE  extract IMG with fsck.erofs and compare it with TREE: every file, link, mode
#   kernel.sh manifest KIT VERSION KVER   the kit manifest of OUT/trees/KIT (on stdout)
#   kernel.sh kits OUT               (Ubuntu) pack every image as a system kit (OUT/kits/*.kit) with kitpack, and
#                                    verify each one with kitfmt (KITFMT_MK4TCL: a built Mk4tcl)
#   kernel.sh initramfs OUT CPIO     (Ubuntu) the boot test's initramfs: busybox, kmod, the test script, the kits
#   kernel.sh boot OUT               (Ubuntu) boot the kernel in QEMU with that initramfs; RESULT kernel-boot
#   kernel.sh boot-verdict OUT       that RESULT line from OUT/boot-serial.log
#   kernel.sh boot-init              the test script the initramfs runs as /init
#   kernel.sh void-ci OUT            (Void container, root) build as the user builder, then modules, firmware, images;
#                                    logs in OUT/logs
#   kernel.sh mk4tcl OUT             (Ubuntu) Mk4tcl for kitpack, from the checked Metakit tarball (build-mk4tcl.sh)
#   kernel.sh fetch DIR              (the image job) download this tree's release into DIR (an xbps repository
#                                    directory), waiting up to FETCH_SECONDS (default 0) for kernel.yml to publish it;
#                                    with no release for the key it says so and fetches nothing (exit 0): the image
#                                    then has Void's linux6.18 only (build-packages.sh does not build ribbon-kernel)
#   kernel.sh publish OUT            (Ubuntu, gh) the release: packages, kits, SHA256SUMS, summary
#
# Results: OUT/kernel-summary.txt holds one RESULT line per stage (build, modules, firmware, images, kits, boot).
set -eu
H=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$H/../.." && pwd)
CONFIG_DIR=$ROOT/build/kernel/config
KCONFIG=$ROOT/srcpkgs/ribbon-kernel/files/kconfig.sh
# out-of-tree modules shipped as prebuilt kits (D47 C: everything else stays with DKMS): kit, Void package with the
# DKMS source, DKMS module name
MODULE_KITS="nvidia nvidia-dkms nvidia
zfs zfs zfs
bcachefs bcachefs-dkms bcachefs"
# the firmware Ribbon installs today (docs/STACK.md: Firmware)
FIRMWARE_PKGS="linux-firmware-amd linux-firmware-intel linux-firmware-network linux-firmware-broadcom
linux-firmware-nvidia sof-firmware wifi-firmware wireless-regdb"
# what no desktop or laptop loads: datacenter NICs and switches, Wi-Fi 7 access points (docs/STACK.md 2.11, 215 MiB)
FIRMWARE_DROP="mellanox mrvl/prestera qed cxgb4 bnx2x liquidio mediatek/mt7996 netronome qlogic"
EROFS_MIN=${KERNEL_EROFS_MIN:-1.9}
CI_REPO=${RIBBON_CI_REPO:-atyr647/ci}
die() { echo "kernel.sh: $*" >&2; exit 1; }
result() { # OUT STAGE VERDICT
	echo "RESULT kernel-$2: $3" | tee -a "$1/kernel-summary.txt"
}

# ---- the template's version and the build key
tvar() { # TEMPLATE VAR: a variable of srcpkgs/TEMPLATE/template (templates are bash: their subpackage functions'
	# names have hyphens)
	bash -c 'XBPS_CROSS_BASE= KERNEL_SITE= . "$1" >/dev/null 2>&1; eval "printf \"%s\\n\" \"\${$2}\""' tvar "$ROOT/srcpkgs/$1/template" "$2"
}
kver() { echo "$(tvar ribbon-kernel version)-ribbon_$(tvar ribbon-kernel revision)"; }
key() {
	# the kits are packed by kitpack with Mk4tcl, so the kit format's writer is an input too
	(cd "$ROOT" && find srcpkgs/ribbon-kernel srcpkgs/erofs-utils build/kernel/config build/ci/kernel.sh \
		kit/kitfmt/kitfmt.tcl kit/kitfmt/kitpack kit/kitfmt/sha256.tcl srcpkgs/mk4tcl build/ci/build-mk4tcl.sh -type f |
		LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"; done) |
		sha256sum | cut -d' ' -f1
}
tag() { k=$(key); echo "kernel-$(tvar ribbon-kernel version)_$(tvar ribbon-kernel revision)-$(echo "$k" | cut -c1-12)"; }

# ---- void-packages
prepare() {
	vp=$1
	[ -d "$vp/srcpkgs" ] || die "$vp is not a void-packages tree"
	for p in ribbon-kernel erofs-utils; do
		rm -rf "$vp/srcpkgs/$p"
		cp -a "$ROOT/srcpkgs/$p" "$vp/srcpkgs/$p"
	done
	# the subpackages' links, as void-packages has them
	for p in ribbon-kernel-headers ribbon-kernel-dbg; do rm -rf "$vp/srcpkgs/$p"; ln -s ribbon-kernel "$vp/srcpkgs/$p"; done
	mkdir -p "$vp/srcpkgs/ribbon-kernel/files/config"
	cp "$CONFIG_DIR"/* "$vp/srcpkgs/ribbon-kernel/files/config/"
	cp "$ROOT/LICENSE" "$vp/srcpkgs/ribbon-kernel/files/LICENSE" 2>/dev/null || :
	# shellcheck disable=SC2046
	sh "$KCONFIG" lint $(sh "$KCONFIG" dir "$vp/srcpkgs/ribbon-kernel/files/config") || die "the kernel configuration does not lint"
}

build() {
	out=$1; vp=$ROOT/out/void-packages
	mkdir -p "$out/repo"
	. "$ROOT/config/ribbon.conf"
	[ -d "$vp/.git" ] || git clone --depth 1 "$VOID_PACKAGES_GIT" "$vp"
	echo XBPS_ALLOW_RESTRICTED=yes > "$vp/etc/conf"
	[ -z "${RIBBON_XBPS_CHROOT_CMD:-}" ] || echo "XBPS_CHROOT_CMD=$RIBBON_XBPS_CHROOT_CMD" >> "$vp/etc/conf"
	echo "XBPS_MAKEJOBS=$(nproc)" >> "$vp/etc/conf"
	"$vp/xbps-src" binary-bootstrap
	prepare "$vp"
	ok=1
	for p in erofs-utils ribbon-kernel; do
		"$vp/xbps-src" -E pkg "$p" || { ok=0; break; }
	done
	cp "$vp"/hostdir/binpkgs/erofs-utils-[0-9]*.xbps "$vp"/hostdir/binpkgs/ribbon-kernel-*.xbps "$out/repo/" 2>/dev/null || :
	if [ "$ok" != 1 ] || ! ls "$out/repo"/ribbon-kernel-headers-*.xbps >/dev/null 2>&1; then
		result "$out" build "FAILED (see the build log)"; return 1
	fi
	xbps-rindex -a "$out/repo"/*.xbps
	result "$out" build "ok ($(kver), erofs-utils $(tvar erofs-utils version))"
}

# ---- the module kits (D47 C)
modules() {
	out=$1; k=$(kver)
	. "$ROOT/config/ribbon.conf"
	R="-R $out/repo -R $VOID_MIRROR/current -R $VOID_MIRROR/current/nonfree"
	# shellcheck disable=SC2086
	xbps-install -Sy $R ribbon-kernel-headers dkms xz kmod >&2
	[ -d "/usr/lib/modules/$k/build" ] || { result "$out" modules "FAILED (no headers for $k)"; return 1; }
	bad=
	echo "$MODULE_KITS" | while read -r kit pkg mod; do
		# shellcheck disable=SC2086
		xbps-install -y $R "$pkg" >&2 || { echo "$kit: $pkg does not install" >&2; echo "$kit" >> "$out/modules.failed"; continue; }
		ver=$(find /usr/src -mindepth 1 -maxdepth 1 -name "$mod-*" | sed "s|^/usr/src/$mod-||" | sort -V | tail -n1)
		[ -n "$ver" ] || { echo "$kit: no DKMS source in /usr/src" >&2; echo "$kit" >> "$out/modules.failed"; continue; }
		dkms build --force -m "$mod" -v "$ver" -k "$k" >&2 || { echo "$kit: dkms build failed" >&2; echo "$kit" >> "$out/modules.failed"; continue; }
		t=$out/trees/$kit/lib/modules/$k/extra/$kit
		mkdir -p "$t"
		find "/var/lib/dkms/$mod/$ver/$k" -name '*.ko*' -path '*/module/*' | while IFS= read -r f; do
			b=$(basename "$f"); b=${b%.xz}; b=${b%.zst}; b=${b%.gz}; b=${b%.ko}
			case $f in
			*.ko.xz) cp "$f" "$t/$b.ko.xz" ;;
			*.ko.zst) to_xz zstd "$f" 1MiB "$t/$b.ko.xz" ;;
			*.ko.gz) to_xz gzip "$f" 1MiB "$t/$b.ko.xz" ;;
			*.ko) xz --check=crc32 --lzma2=dict=1MiB -c "$f" > "$t/$b.ko.xz" ;;
			esac || exit 1
		done || { echo "$kit: a module does not recompress" >&2; echo "$kit" >> "$out/modules.failed"; continue; }
		ls "$t"/*.ko.xz >/dev/null 2>&1 || { echo "$kit: dkms built nothing" >&2; echo "$kit" >> "$out/modules.failed"; continue; }
		echo "$ver" > "$out/trees/$kit.version"
		echo "$kit $ver: $(find "$t" -name '*.ko.xz' | wc -l) modules" >&2
	done
	[ -f "$out/modules.failed" ] && bad=$(tr '\n' ' ' < "$out/modules.failed")
	if [ -n "$bad" ]; then result "$out" modules "FAILED ($bad)"; return 1; fi
	result "$out" modules "ok ($(echo "$MODULE_KITS" | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//'))"
}

# ---- the firmware kit
to_xz() { # DECOMPRESSOR FILE DICT OUT: FILE decompressed in full (a damaged one fails, and OUT is not left behind)
	# and written to OUT as xz with CRC32, the way the kernel reads it
	raw=$4.raw
	if "$1" -dcq -- "$2" > "$raw" && xz --check=crc32 --lzma2=dict="$3" -c "$raw" > "$4"; then rm -f "$raw"; return 0; fi
	echo "kernel.sh: $2 does not decompress" >&2; rm -f "$raw" "$4"; return 1
}

fw_xz() { # TREE: every .zst file becomes .xz (the kernel's xz: CRC32, 2 MiB dictionary); links are renamed with it
	t=$1
	find "$t" -type f -name '*.zst' | while IFS= read -r f; do
		to_xz zstd "$f" 2MiB "${f%.zst}.xz" && touch -r "$f" "${f%.zst}.xz" && rm -f "$f" || exit 1
	done || { echo "fw-xz: a firmware file does not decompress" >&2; return 1; }
	find "$t" -type l -name '*.zst' | while IFS= read -r l; do
		to=$(readlink "$l")
		case $to in *.zst) to=${to%.zst}.xz ;; esac
		ln -sfn "$to" "${l%.zst}.xz" && rm -f "$l"
	done
	# a link whose target is gone (or still .zst) is an error: the kernel would not find the file
	bad=$(find "$t" -name '*.zst'; find "$t" -xtype l)
	[ -z "$bad" ] || { echo "fw-xz: left behind: $bad" >&2; return 1; }
}

firmware() {
	out=$1; r=$out/fwroot
	. "$ROOT/config/ribbon.conf"
	mkdir -p "$r"
	# shellcheck disable=SC2086
	XBPS_ARCH=x86_64 xbps-install -Sy -r "$r" -R "$VOID_MIRROR/current" -R "$VOID_MIRROR/current/nonfree" $FIRMWARE_PKGS >&2 ||
		{ result "$out" firmware "FAILED (the firmware packages do not install)"; return 1; }
	t=$out/trees/firmware/lib/firmware
	mkdir -p "$t"
	cp -a "$r/usr/lib/firmware/." "$t/"
	before=$(du -sm "$t" | cut -f1)
	for d in $FIRMWARE_DROP; do rm -rf "${t:?}/$d"; done
	# links into what was dropped go with it
	find "$t" -xtype l -delete
	fw_xz "$t" || { result "$out" firmware "FAILED (recompressing)"; return 1; }
	date -u +%Y%m%d > "$out/trees/firmware.version"
	result "$out" firmware "ok ($before MiB from Void's packages, $(du -sm "$t" | cut -f1) MiB kept, xz)"
}

# ---- images (D68 A: erofs-utils >= 1.9, every image verified in full)
erofs_version() { mkfs.erofs -V 2>&1 | sed -n 's/^mkfs.erofs[^0-9]*\([0-9][0-9.]*\).*/\1/p' | head -n1; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

verify_image() { # IMG TREE
	img=$1 tree=$2 x=$(mktemp -d)
	fsck.erofs --extract="$x/t" "$img" >/dev/null 2>"$x/err" || { cat "$x/err" >&2; rm -rf "$x"; return 1; }
	# names, types, modes and link targets, then every file's bytes
	( cd "$tree" && find . -printf '%y %m %p %l\n' | LC_ALL=C sort ) > "$x/want"
	( cd "$x/t" && find . -printf '%y %m %p %l\n' | LC_ALL=C sort ) > "$x/got"
	if ! cmp -s "$x/want" "$x/got"; then
		echo "verify-image: the tree and the image differ:" >&2; diff "$x/want" "$x/got" | head -n 20 >&2; rm -rf "$x"; return 1
	fi
	if ! diff -r --no-dereference "$tree" "$x/t" >"$x/diff" 2>&1; then
		echo "verify-image: contents differ:" >&2; head -n 20 "$x/diff" >&2; rm -rf "$x"; return 1
	fi
	rm -rf "$x"
}

uuid_for() { # NAME: a fixed UUID per kit name (reproducible images)
	printf '%s' "$1" | sha256sum | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\).*/\1-\2-\3-\4-\5/'
}

images() {
	out=$1
	. "$ROOT/config/ribbon.conf"
	xbps-install -Sy -R "$out/repo" -R "$VOID_MIRROR/current" erofs-utils >&2 || :
	# Ribbon's build, not Void's package of the same name and version
	case $(xbps-query -p repository erofs-utils 2>/dev/null) in
	"$out/repo"*) ;;
	*) result "$out" images "FAILED (erofs-utils is not the one built here: $(xbps-query -p repository erofs-utils 2>&1))"; return 1 ;;
	esac
	v=$(erofs_version)
	version_ge "${v:-0}" "$EROFS_MIN" || { result "$out" images "FAILED (mkfs.erofs ${v:-missing}; $EROFS_MIN or later is needed, D68)"; return 1; }
	mkdir -p "$out/images"
	bad=
	for d in "$out"/trees/*/; do
		kit=$(basename "$d")
		# uncompressed, no inline data: what the merged /usr view's rebuild mode needs (KIT-FORMAT.md 8.4)
		mkfs.erofs --quiet -T0 --all-root -U "$(uuid_for "$kit")" -Enoinline_data "$out/images/$kit.erofs" "$d" &&
			verify_image "$out/images/$kit.erofs" "$d" || bad="$bad $kit"
	done
	if [ -n "$bad" ]; then result "$out" images "FAILED (${bad# })"; return 1; fi
	result "$out" images "ok (mkfs.erofs $v, $(find "$out/images" -name '*.erofs' | wc -l) images verified in full)"
}

# ---- kits
manifest() { # KIT VERSION KVER
	kit=$1 ver=$2 k=$3 kv=$(echo "$3" | sed 's/-ribbon_\([0-9]*\)$/_\1/')
	case $kit in
	firmware)
		printf 'name org.ribbon.firmware  version %s  kind system\n' "$ver"
		printf 'summary {Firmware for the hardware Ribbon supports, xz-compressed (no datacenter, switch or access-point firmware)}\n'
		printf 'license {various: see the linux-firmware WHENCE file}\n'
		printf 'effects {{firmware lib/firmware}}\n' ;;
	*)
		printf 'name org.ribbon.kmod.%s  version %s+%s  kind system\n' "$kit" "$ver" "$kv"
		printf 'summary {The %s kernel modules, prebuilt for Ribbon'"'"'s kernel %s}\n' "$kit" "$k"
		case $kit in nvidia) printf 'license {NVIDIA proprietary}\n' ;; zfs) printf 'license CDDL-1.0\n' ;; *) printf 'license GPL-2.0-only\n' ;; esac
		# the kernel kit this tree was built against, and nothing else (a module kit moves with its kernel, D47)
		printf 'needs {{org.ribbon.kernel =%s}}\n' "$kv"
		printf 'x-kernel-release %s\n' "$k"
		printf 'effects {{module lib/modules/%s/extra/%s}}\n' "$k" "$kit" ;;
	esac
}

kits() {
	out=$1 k=$(kver)
	[ -n "${KITFMT_MK4TCL:-}" ] || die "kits: KITFMT_MK4TCL (a built Mk4tcl) is needed"
	mkdir -p "$out/kits" "$out/kits.src"
	bad=
	for img in "$out"/images/*.erofs; do
		kit=$(basename "$img" .erofs)
		ver=$(cat "$out/trees/$kit.version" 2>/dev/null || echo 0)
		manifest "$kit" "$ver" "$k" > "$out/kits.src/$kit.manifest"
		mkdir -p "$out/kits.src/$kit"
		name=$(sed -n 's/^name \([^ ]*\) .*/\1/p' "$out/kits.src/$kit.manifest")
		if tclsh "$ROOT/kit/kitfmt/kitpack" -q -mk4tcl "$KITFMT_MK4TCL" -manifest "$out/kits.src/$kit.manifest" \
			-image "$img" -fs erofs -verity "${KITPACK_VERITY:-yes}" "$out/kits.src/$kit" "$out/kits/$name.kit" >&2 &&
			kit_verify "$out/kits/$name.kit" >&2; then
			echo "$kit: $out/kits/$name.kit" >&2
		else bad="$bad $kit"; fi
	done
	if [ -n "$bad" ]; then result "$out" kits "FAILED (${bad# })"; return 1; fi
	result "$out" kits "ok ($(cd "$out/kits" && find . -name '*.kit' | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'))"
}

kit_verify() { # KIT: kitfmt's full verify (every chunk, the image's segments, the root)
	TCLLIBPATH="$KITFMT_MK4TCL $ROOT/kit${TCLLIBPATH:+ $TCLLIBPATH}" tclsh <<-EOF
		package require kitfmt
		set h [kitfmt open [list $1] -signed 0]
		set r [kitfmt verify \$h]
		set i [kitfmt image \$h]
		kitfmt close \$h
		puts "verify: \$r"
		if {\$i eq "" || [dict get \$r ok] != 1 || [dict get \$r image] ne "ok" || [dict get \$r root] ne "ok"} { exit 1 }
	EOF
}

# ---- the boot test
boot_init() { # the initramfs's /init (busybox sh)
	cat <<-'EOF'
		#!/bin/sh
		# kernel.sh boot: Ribbon's kernel on its own, with its kits (CI only)
		export PATH=/bin:/sbin
		mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
		say() { echo "KBOOT $*" > /dev/console; }
		k=$(uname -r)
		say "release $k"
		[ -d /sys/kernel/sched_ext ] && say "ok sched_ext" || say "FAIL sched_ext: no /sys/kernel/sched_ext"
		[ -e /dev/ntsync ] && say "ok ntsync" || say "FAIL ntsync: no /dev/ntsync"
		# the modules this test needs from the kernel itself (loop, erofs), then a deflate image (D38)
		for m in $(cat /deps/base); do insmod "/deps/$m" 2>/dev/null; done
		grep -qw erofs /proc/filesystems && say "ok erofs" || say "FAIL erofs: not registered"
		mkdir -p /mnt/deflate && mount -t erofs -o ro,loop /test/deflate.erofs /mnt/deflate &&
			[ "$(cat /mnt/deflate/hello)" = "deflate ok" ] && say "ok erofs deflate" || say "FAIL erofs deflate"
		# each module kit: its image at its sealed offset, read-only, and one module loaded from it
		for kit in /kits/*.kit; do
			[ -e "$kit" ] || continue
			n=$(basename "$kit" .kit); off=$(cat "/kits/$n.offset")
			mkdir -p "/mnt/$n"
			dev=$(losetup -f) && losetup -r -o "$off" "$dev" "$kit" && mount -t erofs -o ro "$dev" "/mnt/$n" ||
				{ say "FAIL kit $n: does not mount"; continue; }
			# every module of the kit was built for this kernel
			for f in $(find "/mnt/$n" -name '*.ko*'); do
				v=$(modinfo -F vermagic "$f" | cut -d' ' -f1)
				[ "$v" = "$k" ] || say "FAIL kit $n: $(basename "$f") is for '$v'"
			done
			# and one that needs no hardware is loaded from it, after what it needs (from the kernel or the kit)
			if [ -f "/kits/$n.load" ]; then
				read -r mod < "/kits/$n.load"
				for d in $(cat "/kits/$n.deps"); do
					case $d in
					kernel:*) insmod "/deps/${d#kernel:}" 2>/dev/null ;;
					kit:*) insmod "$(find "/mnt/$n" -name "${d#kit:}" | head -n1)" 2>/dev/null ;;
					esac
				done
				f=$(find "/mnt/$n" -name "$mod.ko*" | head -n1)
				insmod "$f" && grep -q "^$mod " /proc/modules && say "ok kit $n: $mod loaded" || say "FAIL kit $n: $mod does not load"
			else
				say "ok kit $n: mounted ($(find "/mnt/$n" -type f | wc -l) files)"
			fi
		done
		say "done"
		poweroff -f
	EOF
}

initramfs() { # OUT CPIO
	out=$1 cpio=$2 k=$(kver) w=$(mktemp -d)
	mkdir -p "$w/r/bin" "$w/r/sbin" "$w/r/deps" "$w/r/kits" "$w/r/test" "$w/r/proc" "$w/r/sys" "$w/r/dev" "$w/r/mnt" "$w/k"
	cp "$(command -v busybox)" "$w/r/bin/busybox"
	for a in $("$w/r/bin/busybox" --list); do [ -e "$w/r/bin/$a" ] || ln -s busybox "$w/r/bin/$a"; done
	# kmod's insmod (xz modules; busybox's cannot read them), with its libraries
	rm -f "$w/r/bin/insmod"
	rm -f "$w/r/bin/modinfo"
	cp "$(command -v kmod)" "$w/r/bin/kmod" && ln -s kmod "$w/r/bin/insmod" && ln -s kmod "$w/r/bin/modinfo"
	ldd "$(command -v kmod)" | sed -n 's|.* => \(/[^ ]*\) .*|\1|p; s|^[[:space:]]*\(/[^ ]*\) .*|\1|p' | while IFS= read -r l; do
		mkdir -p "$w/r$(dirname "$l")" && cp -L "$l" "$w/r$l"
	done
	boot_init > "$w/r/init"; chmod 755 "$w/r/init"
	# the kernel package's modules, for the dependency lists (modprobe -d ... --show-depends)
	for p in "$out"/repo/ribbon-kernel-[0-9]*.xbps; do zstd -dcq "$p" | tar -x -C "$w/k"; done
	cp "$w/k/boot/vmlinuz-$k" "$out/vmlinuz"
	depends() { # MODULE...: the files to insmod, in order
		modprobe -d "$w/k/usr" -S "$k" --show-depends "$@" 2>/dev/null | sed -n 's/^insmod \([^ ]*\).*/\1/p'
	}
	depends loop erofs | while IFS= read -r f; do cp "$f" "$w/r/deps/"; basename "$f"; done > "$w/r/deps/base"
	# a deflate erofs image (D38: the kernel's deflate decompressor, CONFIG_EROFS_FS_ZIP_DEFLATE)
	mkdir -p "$w/d" && echo "deflate ok" > "$w/d/hello"
	mkfs.erofs --quiet -zdeflate "$w/r/test/deflate.erofs" "$w/d" >/dev/null
	for kit in "$out"/kits/*.kit; do
		n=$(basename "$kit" .kit)
		cp "$kit" "$w/r/kits/$n.kit"
		TCLLIBPATH="$KITFMT_MK4TCL $ROOT/kit" tclsh <<-EOF > "$w/r/kits/$n.offset"
			package require kitfmt
			puts [dict get [dict get [::kitfmt::Frame [list $kit]] st] image offset]
		EOF
		case $n in
		org.ribbon.kmod.*)
			m=${n#org.ribbon.kmod.}
			# the kit's modules beside the kernel's, to resolve what the loaded one needs
			mkdir -p "$w/k/usr/lib/modules/$k/extra"
			cp -a "$out/trees/$m/lib/modules/$k/extra/$m" "$w/k/usr/lib/modules/$k/extra/"
			depmod -b "$w/k/usr" "$k"
			# loaded in the test: the modules that load without their hardware (nvidia's needs a GPU: its
			# vermagic is checked instead)
			case $m in bcachefs | zfs) echo "$m" > "$w/r/kits/$n.load" ;; esac
			depends "$m" | while IFS= read -r f; do
				b=$(basename "$f")
				case $f in
				*/extra/$m/$m.ko*) ;;
				*/extra/$m/*) echo "kit:$b" ;;
				*) [ -e "$w/r/deps/$b" ] || cp "$f" "$w/r/deps/$b"; echo "kernel:$b" ;;
				esac
			done > "$w/r/kits/$n.deps" ;;
		esac
	done
	(cd "$w/r" && find . | cpio -o -H newc --quiet) | gzip -1 > "$cpio"
	rm -rf "$w"
}

boot() {
	out=$1
	initramfs "$out" "$out/initramfs.img"
	kvm=; [ -w /dev/kvm ] && kvm="-enable-kvm -cpu host"
	# shellcheck disable=SC2086
	timeout "${BOOT_SECONDS:-600}" qemu-system-x86_64 $kvm -m 3072 -smp 2 -nographic -no-reboot \
		-kernel "$out/vmlinuz" -initrd "$out/initramfs.img" -append "console=ttyS0 panic=-1 loglevel=4" \
		> "$out/boot-serial.log" 2>&1 || :
	boot_verdict "$out"
}

boot_verdict() { # OUT: RESULT kernel-boot from OUT/boot-serial.log
	out=$1
	grep 'KBOOT ' "$out/boot-serial.log" | sed 's/\r$//; s/^.*KBOOT /KBOOT /' > "$out/boot-lines.txt" || :
	rel=$(sed -n 's/^KBOOT release //p' "$out/boot-lines.txt" | head -n1)
	if [ "$rel" != "$(kver)" ]; then result "$out" boot "FAILED (the kernel did not reach the test: release '${rel}')"; return 1; fi
	if grep -q '^KBOOT FAIL' "$out/boot-lines.txt" || ! grep -q '^KBOOT done' "$out/boot-lines.txt"; then
		result "$out" boot "FAILED ($(sed -n 's/^KBOOT FAIL //p' "$out/boot-lines.txt" | tr '\n' ';')$(grep -q '^KBOOT done' "$out/boot-lines.txt" || echo ' the test did not finish'))"
		return 1
	fi
	result "$out" boot "ok ($rel: $(grep -c '^KBOOT ok' "$out/boot-lines.txt") checks)"
}

# ---- the CI stages
void_ci() { # OUT: inside the Void container (root): build as an unprivileged builder, then modules, firmware, images
	out=$1
	mkdir -p "$out/logs"
	xbps-install -Syu xbps >&2 && xbps-install -Syu >&2
	xbps-install -y git bash curl xz zstd kmod findutils diffutils coreutils >&2
	getent group xbuilder >/dev/null 2>&1 || groupadd xbuilder
	id builder >/dev/null 2>&1 || useradd -m -G xbuilder builder
	git config --global --add safe.directory "$ROOT"
	chown -R builder: "$ROOT"
	st=0
	# xbps-src's default chroot (user namespaces) is refused on the runner: xbps-uchroot (decision in ribbon-image.yml)
	su builder -c "RIBBON_XBPS_CHROOT_CMD=uchroot sh '$H/kernel.sh' build '$out'" > "$out/logs/build.log" 2>&1 || st=1
	tail -n 1 "$out/logs/build.log"
	if [ "$st" = 0 ]; then
		modules "$out" > "$out/logs/modules.log" 2>&1 || st=1
		firmware "$out" > "$out/logs/firmware.log" 2>&1 || st=1
		images "$out" > "$out/logs/images.log" 2>&1 || st=1
	fi
	grep '^RESULT' "$out/kernel-summary.txt" 2>/dev/null || :
	return $st
}

mk4tcl() { # OUT: Mk4tcl from the Metakit tarball srcpkgs/mk4tcl/template names (checked), as check.sh builds it
	o=$1
	url=$(tvar mk4tcl distfiles)
	mkdir -p "$ROOT/out/distfiles"
	t=$ROOT/out/distfiles/$(basename "$url")
	[ -f "$t" ] || curl -fsSL --retry 3 -o "$t" "$url"
	sh "$H/build-mk4tcl.sh" "$t" "$o"
}

# ---- the release
publish() {
	out=$1 t=$(tag)
	grep -q '^RESULT kernel-boot: ok' "$out/kernel-summary.txt" || die "publish: the boot test did not pass; nothing is published"
	mkdir -p "$out/release"
	cp "$out"/repo/*.xbps "$out"/kits/*.kit "$out/kernel-summary.txt" "$out/release/"
	(cd "$out/release" && sha256sum -- * > SHA256SUMS)
	echo "$t" > "$out/release/TAG"
	gh release delete "$t" -R "$CI_REPO" -y --cleanup-tag >/dev/null 2>&1 || :
	gh release create "$t" -R "$CI_REPO" --title "Ribbon kernel $(kver)" --notes-file "$out/kernel-summary.txt" "$out"/release/*
}

release_get() { # URL FILE: 0 when FILE was downloaded, 2 when there is no such file (HTTP 404: no release for
	# the tag), 1 for anything else (the network, the server)
	code=$(curl -sSL --retry 3 -o "$2" -w '%{http_code}' "$1" 2>/dev/null) || code=000
	case $code in
	2??) return 0 ;;
	404) rm -f "$2"; return 2 ;;
	*) rm -f "$2"; return 1 ;;
	esac
}

fetch() { # DIR: the release for this tree's key into DIR; with none (yet), Void's linux6.18 is the image's only kernel
	d=$1 t=$(tag) deadline=$(( $(date +%s) + ${FETCH_SECONDS:-0} ))
	base=https://github.com/$CI_REPO/releases/download/$t
	mkdir -p "$d"
	while :; do
		st=0; release_get "$base/SHA256SUMS" "$d/SHA256SUMS.kernel" || st=$?
		[ "$st" = 0 ] && break
		if [ "$(date +%s)" -ge "$deadline" ]; then
			if [ "$st" = 2 ]; then
				echo "no Ribbon kernel release for $t: this image uses Void's linux6.18 only"; return 0
			fi
			echo "fetch: the release $t could not be looked up (not a 404: the network or GitHub)" >&2; return 1
		fi
		sleep 60
	done
	grep '\.xbps$' "$d/SHA256SUMS.kernel" | while read -r sum f; do
		curl -fsSL -o "$d/$f" "$base/$f" || exit 1
		echo "$sum  $d/$f" | sha256sum -c --quiet - || exit 1
	done || { echo "fetch: $t is incomplete or corrupt" >&2; return 1; }
	echo "fetch: $t into $d"
}

cmd=${1:-}; [ $# -gt 0 ] && shift
# OUT and DIR arguments as absolute paths (the build runs under su, the kits job from another directory)
case $cmd in build | modules | firmware | images | kits | initramfs | boot | boot-verdict | void-ci | mk4tcl | fetch | publish)
	[ $# -ge 1 ] && case $1 in /*) ;; *) a=$PWD/$1; shift; set -- "$a" "$@" ;; esac ;;
esac
case $cmd in
key) key ;;
tag) tag ;;
kver) kver ;;
prepare) prepare "${1:?usage: kernel.sh prepare VP}" ;;
build) build "${1:?usage: kernel.sh build OUT}" ;;
modules) modules "${1:?usage: kernel.sh modules OUT}" ;;
firmware) firmware "${1:?usage: kernel.sh firmware OUT}" ;;
images) images "${1:?usage: kernel.sh images OUT}" ;;
fw-xz) fw_xz "${1:?usage: kernel.sh fw-xz TREE}" ;;
verify-image) verify_image "${1:?usage: kernel.sh verify-image IMG TREE}" "${2:?}" ;;
manifest) manifest "${1:?usage: kernel.sh manifest KIT VERSION KVER}" "${2:?}" "${3:?}" ;;
kits) kits "${1:?usage: kernel.sh kits OUT}" ;;
initramfs) initramfs "${1:?usage: kernel.sh initramfs OUT CPIO}" "${2:?}" ;;
boot) boot "${1:?usage: kernel.sh boot OUT}" ;;
boot-verdict) boot_verdict "${1:?usage: kernel.sh boot-verdict OUT}" ;;
fetch) fetch "${1:?usage: kernel.sh fetch DIR}" ;;
publish) publish "${1:?usage: kernel.sh publish OUT}" ;;
boot-init) boot_init ;;
void-ci) void_ci "${1:?usage: kernel.sh void-ci OUT}" ;;
mk4tcl) mk4tcl "${1:?usage: kernel.sh mk4tcl OUT}" ;;
*) echo "usage: kernel.sh key|tag|kver|prepare|build|modules|firmware|images|fw-xz|verify-image|manifest|kits|initramfs|boot|fetch|publish" >&2; exit 2 ;;
esac
