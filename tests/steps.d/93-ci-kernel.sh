#!/bin/sh
# Ribbon's kernel (srcpkgs/ribbon-kernel, build/kernel/config), erofs-utils (srcpkgs/erofs-utils) and their CI job
# (build/ci/kernel.yml, build/ci/kernel.sh): what can be checked without building third-party source.
#   1. the configuration: Void's base is the pinned file; the fragments lint; merged, every fragment line is in place
#      and check passes; on Void's base unchanged, check names what Ribbon changes (deflate erofs, sched_ext, xz
#      modules, the trims); a setting olddefconfig drops fails check, a "not set" option that is gone holds; lint
#      refuses an unknown option, two values and a malformed line; the trims keep VM storage and laptop Wi-Fi;
#   2. the template: Void's kernel version and distfiles, the release <version>-ribbon_<revision>, the fallback kernel
#      and the headers as dependencies, the subpackages and their links; its do_configure, run with a stand-in make,
#      writes a .config with every fragment and the release, and stops when olddefconfig drops a fragment line or
#      the configuration is missing; modules are compressed with xz, never zstd (D38);
#   3. erofs-utils: 1.9 or later (D68), pinned, deflate through libdeflate, no zstd;
#   4. kernel.sh: the tag and key (a fragment changed is a new key), prepare into a void-packages tree, fw-xz
#      (xz with CRC32, links follow), verify-image (an image matches its tree; a changed tree is refused), the
#      manifests, kits (packed and verified with kitfmt when KITFMT_MK4TCL is set), the boot verdicts, the test
#      initramfs's /init;
#   5. the workflow: on the ribbon-image push, the build in Void's container, kits and the boot test after it, the
#      release only when they passed, every kernel.sh command it runs exists; shellcheck on the scripts.
# word splitting of the file lists (paths without spaces) is intended throughout
# shellcheck disable=SC2046,SC2086
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
K=srcpkgs/ribbon-kernel/files/kconfig.sh
S=build/ci/kernel.sh
C=build/kernel/config
Y=build/ci/kernel.yml

# ---- 1. the configuration
base=$(awk '!/^#/ && NF { print $1; exit }' $C/SOURCE)
want=$(awk '!/^#/ && NF { print $2; exit }' $C/SOURCE)
[ -n "$base" ] && [ "$(sha256sum "$C/$base" | cut -d' ' -f1)" = "$want" ] &&
	ok "the base is Void's linux6.18 configuration as pinned in SOURCE ($base)" || fail "the base $C/$base does not match SOURCE"
grep -q '^# Linux/x86_64 6\.18\.[0-9]* Kernel Configuration' "$C/$base" && ok "the base is a 6.18 x86_64 configuration" || fail "the base is not 6.18 x86_64"
set -- $(sh $K dir $C)
[ "$1" = "$C/$base" ] && [ $# -ge 3 ] && ok "kconfig.sh dir: the base, then $(($# - 1)) fragments in order" || fail "kconfig.sh dir: $*"
frags=$(sh $K dir $C | tail -n +2)
if sh $K lint $(sh $K dir $C) > "$T/lint" 2>&1; then ok "the fragments lint (well formed, known to the base, one value each)"; else fail "lint: $(head -n3 "$T/lint")"; fi
sh $K merge $(sh $K dir $C) > "$T/merged"
if sh $K check "$T/merged" $frags > "$T/check" 2>&1; then ok "merged, every fragment line is in place"; else fail "check after merge: $(head -n3 "$T/check")"; fi
# every option is in the merged file once
dups=$(sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p; s/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p' "$T/merged" | sort | uniq -d | head -n3)
[ -z "$dups" ] && ok "merged, no option is set twice" || fail "merged has options twice: $dups"
sh $K check "$C/$base" $frags > "$T/onbase" 2>&1 && fail "check passes on Void's base unchanged" || {
	miss=
	for s in EROFS_FS_ZIP_DEFLATE SCHED_CLASS_EXT MODULE_COMPRESS_XZ INFINIBAND MEDIA_DIGITAL_TV_SUPPORT GFS2_FS NET_VENDOR_MELLANOX; do
		grep -q "^CONFIG_$s: wanted" "$T/onbase" || miss="$miss $s"
	done
	[ -z "$miss" ] && ok "on Void's base, check names what Ribbon changes (deflate erofs, sched_ext, xz modules, the trims)" ||
		fail "check on the base does not name:$miss"
}
grep -v '^CONFIG_SCHED_CLASS_EXT=y$' "$T/merged" > "$T/dropped"
sh $K check "$T/dropped" $frags > "$T/drop" 2>&1 && fail "check passes when olddefconfig dropped sched_ext" ||
	{ grep -q '^CONFIG_SCHED_CLASS_EXT: wanted y, olddefconfig made it n$' "$T/drop" && ok "a setting olddefconfig dropped fails check, by name" || fail "check's message: $(cat "$T/drop")"; }
sed 's/^CONFIG_MODULE_COMPRESS_XZ=y$/CONFIG_MODULE_COMPRESS_XZ=m/' "$T/merged" > "$T/changed"
sh $K check "$T/changed" $frags >/dev/null 2>&1 && fail "check passes a changed value" || ok "a changed value fails check"
grep -v '^# CONFIG_INFINIBAND is not set$' "$T/merged" > "$T/gone"
sh $K check "$T/gone" $frags >/dev/null 2>&1 && ok "a \"not set\" option that olddefconfig removed holds" || fail "check refuses a not-set option that is gone"
printf 'CONFIG_EROFS_FS_ZIP_DEFLATTE=y\n' > "$T/typo.config"
sh $K lint "$C/$base" "$T/typo.config" > "$T/l1" 2>&1 && fail "lint passes an option the base does not know" ||
	{ grep -q 'unknown to the base: CONFIG_EROFS_FS_ZIP_DEFLATTE' "$T/l1" && ok "lint refuses an option the base does not know (a typo)" || fail "lint typo: $(cat "$T/l1")"; }
printf '# CONFIG_SCHED_CLASS_EXT is not set\n' > "$T/two.config"
sh $K lint "$C/$base" $frags "$T/two.config" > "$T/l2" 2>&1 && fail "lint passes two values for one option" ||
	{ grep -q 'two values for CONFIG_SCHED_CLASS_EXT' "$T/l2" && ok "lint refuses two values for one option" || fail "lint two: $(cat "$T/l2")"; }
printf 'CONFIG_EROFS_FS = y\n' > "$T/bad.config"
sh $K lint "$C/$base" "$T/bad.config" > "$T/l3" 2>&1 && fail "lint passes a malformed line" ||
	{ grep -q 'malformed' "$T/l3" && ok "lint refuses a malformed line" || fail "lint malformed: $(cat "$T/l3")"; }
# an option with no prompt unless a gate is on keeps its default in olddefconfig (CI run 43770307058: the media types
# are all y unless CONFIG_MEDIA_SUPPORT_FILTER=y); lint refuses the fragments without the gate, by name
mkdir -p "$T/nogate" && for f in $frags; do grep -vx 'CONFIG_MEDIA_SUPPORT_FILTER=y' "$f" > "$T/nogate/$(basename "$f")"; done
sh $K lint "$C/$base" "$T"/nogate/*.config > "$T/l4" 2>&1 && fail "lint passes the digital TV trim without the media filter" ||
	{ grep -qx 'not user-visible: CONFIG_MEDIA_DIGITAL_TV_SUPPORT=n needs CONFIG_MEDIA_SUPPORT_FILTER=y (without it olddefconfig makes it y)' "$T/l4" &&
		ok "lint refuses an option without its prompt (the media types without CONFIG_MEDIA_SUPPORT_FILTER=y), by name" || fail "lint gate: $(cat "$T/l4")"; }
grep -qx 'CONFIG_MEDIA_SUPPORT_FILTER=y' "$T/merged" && grep -qx '# CONFIG_MEDIA_DIGITAL_TV_SUPPORT is not set' "$T/merged" &&
	grep -qx 'CONFIG_MEDIA_CAMERA_SUPPORT=y' "$T/merged" && grep -qx 'CONFIG_MEDIA_ANALOG_TV_SUPPORT=y' "$T/merged" &&
	ok "merged: the media filter on, digital TV off, cameras and analog TV kept" || fail "merged media settings"
printf 'CONFIG_MEDIA_CAMERA_SUPPORT=y\n' > "$T/dflt.config"
sh $K lint "$C/$base" "$T/dflt.config" >/dev/null 2>&1 && ok "lint passes a gated option set to the default it keeps without its gate" ||
	fail "lint refuses a gated option at its default"
# what the trims must keep: storage in virtual machines, laptop Wi-Fi and cameras from staging, desktop 10 GbE
kept=
for s in SCSI_VIRTIO VMWARE_PVSCSI HYPERV_STORAGE FUSION SCSI_SYM53C8XX_2 ISCSI_TCP RTL8723BS INTEL_ATOMISP VIDEO_IPU3_IMGU IXGBE I40E STAGING SCSI_LOWLEVEL; do
	grep -qE "^(# )?CONFIG_${s}[= ]" $frags && kept="$kept $s"
	grep -qE "^CONFIG_$s=[ym]$" "$T/merged" || kept="$kept $s(off)"
done
[ -z "$kept" ] && ok "the trims keep VM storage, laptop Wi-Fi and cameras, desktop 10 GbE" || fail "the trims touch:$kept"

# ---- 2. the template
tv() { bash -c 'XBPS_CROSS_BASE= KERNEL_SITE=https://cdn.kernel.org/pub/linux . srcpkgs/ribbon-kernel/template >/dev/null 2>&1; eval "printf \"%s\\n\" \"\${$1}\""' tv "$1"; }
bv=$(awk '!/^#/ && NF { print $5; exit }' $C/SOURCE)
[ "$(tv pkgname)" = ribbon-kernel ] && [ "$(tv version)" = "$bv" ] &&
	ok "the template builds ribbon-kernel $(tv version), the version Void's base configuration is for" || fail "template version $(tv version), base $bv"
[ "$(tv _kernver)" = "$(tv version)-ribbon_$(tv revision)" ] && [ "$(sh $S kver)" = "$(tv _kernver)" ] &&
	ok "the release is $(tv _kernver) (never Void's <version>_<revision>)" || fail "release $(tv _kernver)"
df=$(tv distfiles | tr '\n' ' '); n=$(tv checksum | wc -w)
case $df in *"/v6.x/linux-6.18.tar.xz"*"/v6.x/patch-$(tv version).xz"*) [ "$n" = 2 ] && ok "distfiles: linux-6.18 and patch-$(tv version), both pinned" || fail "checksums: $n";; *) fail "distfiles: $df";; esac
[ "$(tv checksum | tr -s ' \n' '  ' | sed 's/^ //; s/ $//')" = "9106a4605da9e31ff17659d958782b815f9591ab308d03b0ee21aad6c7dced4b 535d4a3587af51157d3fca4adb871f1190218d3ad1095336b720431360c41ad6" ] &&
	ok "the checksums are Void's for linux 6.18 and patch-6.18.63" || fail "checksums differ from Void's: $(tv checksum)"
dep=$(tv depends | tr -s ' \n' '\n\n' | grep .)
for d in linux6.18 linux6.18-headers "ribbon-kernel-headers>=$(tv version)_$(tv revision)"; do echo "$dep" | grep -qxF -- "$d" || dep="MISSING $d"; done
case $dep in MISSING*) fail "depends: $dep";; *) ok "depends: Void's linux6.18 (the fallback entry) and the headers DKMS needs";; esac
[ "$(tv triggers)" = kernel-hooks ] && [ "$(tv kernel_hooks_version)" = "$(tv _kernver)" ] && ok "kernel-hooks run for $(tv _kernver) (initramfs, Limine)" || fail "triggers"
for p in ribbon-kernel-headers ribbon-kernel-dbg; do
	bash -c ". srcpkgs/ribbon-kernel/template >/dev/null 2>&1; declare -F ${p}_package" >/dev/null && [ "$(readlink srcpkgs/$p)" = ribbon-kernel ] ||
		fail "subpackage $p (function and srcpkgs link)"
done && ok "subpackages ribbon-kernel-headers and ribbon-kernel-dbg, linked in srcpkgs as void-packages has them"
for p in fix-ccache fixdep-largefile fix-musl-btf-ids fix-musl-objtool; do [ -f srcpkgs/ribbon-kernel/patches/$p.patch ] || fail "patch $p missing"; done
# do_configure in a stand-in build directory: make is a stand-in olddefconfig (keeps the file, or drops a line)
mkdir -p "$T/vp/srcpkgs" && cp -a srcpkgs/ribbon-kernel "$T/vp/srcpkgs/" && mkdir -p "$T/vp/srcpkgs/ribbon-kernel/files/config" &&
	cp $C/* "$T/vp/srcpkgs/ribbon-kernel/files/config/"
conf() { # DIR DROP: run do_configure in DIR; DROP is a line the stand-in olddefconfig removes
	mkdir -p "$1"
	(cd "$1" && FILESDIR=$T/vp/srcpkgs/ribbon-kernel/files DROP=$2 bash -c '
		. "$FILESDIR/../template" >/dev/null 2>&1
		pkgver=ribbon-kernel-$version_$revision makejobs=
		make() { [ -z "$DROP" ] || { grep -vx -- "$DROP" .config > .c; mv .c .config; }; }
		msg_error() { printf "%b" "$*" >&2; exit 1; }
		do_configure') > "$1.log" 2>&1
}
if conf "$T/c1" ""; then
	grep -qx 'CONFIG_LOCALVERSION="-ribbon_1"' "$T/c1/.config" && sh $K check "$T/c1/.config" $frags >/dev/null &&
		ok "do_configure writes a .config with every fragment and the release -ribbon_1" || fail "do_configure's .config"
else fail "do_configure failed: $(tail -n3 "$T/c1.log")"; fi
conf "$T/c2" "CONFIG_EROFS_FS_ZIP_DEFLATE=y" && fail "do_configure goes on when olddefconfig drops a fragment line" ||
	{ grep -q 'CONFIG_EROFS_FS_ZIP_DEFLATE' "$T/c2.log" && ok "do_configure stops, naming it, when olddefconfig drops a fragment line" || fail "do_configure's message: $(cat "$T/c2.log")"; }
rm -rf "$T/vp/srcpkgs/ribbon-kernel/files/config"
conf "$T/c3" "" && fail "do_configure goes on without build/kernel/config" ||
	{ grep -q 'files/config is missing' "$T/c3.log" && ok "do_configure stops when build/kernel/config was not copied in" || fail "c3: $(cat "$T/c3.log")"; }
grep -q '^xz --check=crc32 --lzma2=dict=1MiB' srcpkgs/ribbon-kernel/files/mv-debug && ! grep -qE '^[^#]*zstd' srcpkgs/ribbon-kernel/files/mv-debug &&
	ok "modules are compressed with xz the way the kernel reads them, never zstd (D38)" || fail "mv-debug's compression"

# ---- 3. erofs-utils
ev() { bash -c '. srcpkgs/erofs-utils/template >/dev/null 2>&1; eval "printf \"%s\\n\" \"\${$1}\""' ev "$1"; }
v=$(ev version)
[ "$(printf '1.9\n%s\n' "$v" | sort -V | head -n1)" = 1.9 ] && ok "erofs-utils $v (1.9 or later, D68)" || fail "erofs-utils $v is older than 1.9"
echo "$(ev checksum)" | grep -qE '^[0-9a-f]{64}$' && case $(ev distfiles) in *"erofs-utils-$v.tar.gz") true;; *) false;; esac &&
	ok "erofs-utils is pinned (its snapshot tarball and checksum)" || fail "erofs-utils distfile or checksum"
a=" $(ev configure_args | tr '\n' ' ') "
case $a in *" --with-libdeflate "*) case $a in *" --without-libzstd "*) ok "erofs-utils: deflate through libdeflate, no zstd";; *) fail "erofs-utils links zstd";; esac;; *) fail "erofs-utils without libdeflate";; esac

# ---- 4. kernel.sh
tg=$(sh $S tag)
echo "$tg" | grep -qE "^kernel-$(tv version)_$(tv revision)-[0-9a-f]{12}\$" && ok "tag: $tg" || fail "tag: $tg"
mkdir -p "$T/tree/build/ci" "$T/tree/srcpkgs" "$T/tree/build/kernel" "$T/tree/kit/kitfmt" && cp $S build/ci/build-mk4tcl.sh "$T/tree/build/ci/" &&
	cp -a srcpkgs/ribbon-kernel srcpkgs/erofs-utils srcpkgs/mk4tcl "$T/tree/srcpkgs/" && cp -a $C "$T/tree/build/kernel/" &&
	cp kit/kitfmt/kitfmt.tcl kit/kitfmt/kitpack kit/kitfmt/sha256.tcl "$T/tree/kit/kitfmt/"
k1=$(sh "$T/tree/$S" key 2>"$T/key.err"); k0=$(sh $S key)
echo "# CONFIG_CAN is not set" >> "$T/tree/$C/20-desktop.config"
k2=$(sh "$T/tree/$S" key)
[ "$k1" = "$k0" ] && [ "$k1" != "$k2" ] && [ ! -s "$T/key.err" ] && ok "the key follows the inputs (a fragment changed is a new build)" || fail "key: $k0 $k1 $k2 $(cat "$T/key.err")"
# the kits in the release are written by kitpack: a change to the kit format's writer is a new build too
echo "# changed" >> "$T/tree/kit/kitfmt/kitfmt.tcl"
k3=$(sh "$T/tree/$S" key)
[ "$k3" != "$k2" ] && ok "the key follows kitpack (kitfmt.tcl changed is a new build: the cached kits would be stale)" || fail "key ignores kitfmt.tcl: $k3"
mkdir -p "$T/void/srcpkgs/erofs-utils" && echo old > "$T/void/srcpkgs/erofs-utils/template"
if sh $S prepare "$T/void" > "$T/prep" 2>&1 && [ -f "$T/void/srcpkgs/ribbon-kernel/files/config/SOURCE" ] &&
	cmp -s "$T/void/srcpkgs/erofs-utils/template" srcpkgs/erofs-utils/template && [ "$(readlink "$T/void/srcpkgs/ribbon-kernel-headers")" = ribbon-kernel ]; then
	ok "prepare: both templates replace Void's, build/kernel/config goes in as files/config, the subpackage links"
else fail "prepare: $(cat "$T/prep")"; fi
mkdir -p "$T/fw/a" && printf 'firmware %.0s' $(seq 1 100) > "$T/fw/a/x.bin" && zstd -q --rm "$T/fw/a/x.bin" &&
	ln -s x.bin.zst "$T/fw/a/y.bin.zst" && ln -s a/x.bin.zst "$T/fw/z.bin.zst"
if sh $S fw-xz "$T/fw" 2>"$T/fw.err" && [ "$(readlink "$T/fw/a/y.bin.xz")" = x.bin.xz ] &&
	[ "$(readlink "$T/fw/z.bin.xz")" = a/x.bin.xz ] && [ -z "$(find "$T/fw" -name '*.zst')" ] &&
	xz -lv "$T/fw/a/x.bin.xz" | grep -q 'Check: *CRC32' && xz -dc "$T/fw/a/x.bin.xz" | grep -q '^firmware'; then
	ok "fw-xz: zstd firmware becomes xz with CRC32 (FW_LOADER_COMPRESS_XZ), and its links follow"
else fail "fw-xz: $(cat "$T/fw.err" 2>/dev/null)"; fi
# a damaged (truncated) .zst must fail fw-xz and stay as it was, never become an empty or short .xz
mkdir -p "$T/fwbad" && printf 'firmware %.0s' $(seq 1 100) | zstd -q -c | head -c 20 > "$T/fwbad/t.bin.zst"
if sh $S fw-xz "$T/fwbad" >/dev/null 2>&1; then fail "fw-xz passes a truncated firmware file ($(ls "$T/fwbad"))"
elif [ -f "$T/fwbad/t.bin.zst" ] && [ ! -e "$T/fwbad/t.bin.xz" ]; then ok "fw-xz refuses a damaged firmware file and leaves it as it was"
else fail "fw-xz on a damaged file left: $(ls "$T/fwbad")"; fi
mk=$T/tree/build/ci/out
km=6.18.63-ribbon_1
mkdir -p "$mk/trees/bcachefs/lib/modules/$km/extra/bcachefs" "$mk/images"
printf 'not a module\n' | xz --check=crc32 > "$mk/trees/bcachefs/lib/modules/$km/extra/bcachefs/bcachefs.ko.xz"
echo 1.36.1 > "$mk/trees/bcachefs.version"
# fsck.erofs comes with mkfs.erofs (erofs-utils)
if command -v mkfs.erofs >/dev/null; then
	mkfs.erofs --quiet -T0 --all-root -Enoinline_data "$mk/images/bcachefs.erofs" "$mk/trees/bcachefs" >/dev/null 2>&1
	sh $S verify-image "$mk/images/bcachefs.erofs" "$mk/trees/bcachefs" 2>"$T/vi" && ok "verify-image: an image matches its tree" || fail "verify-image: $(cat "$T/vi")"
	echo x > "$mk/trees/bcachefs/lib/stray"
	sh $S verify-image "$mk/images/bcachefs.erofs" "$mk/trees/bcachefs" 2>/dev/null && fail "verify-image passes a tree the image lacks a file of" ||
		ok "verify-image refuses an image that lacks a file of its tree"
	rm "$mk/trees/bcachefs/lib/stray"
	printf 'not a modulE\n' | xz --check=crc32 > "$mk/trees/bcachefs/lib/modules/$km/extra/bcachefs/bcachefs.ko.xz"
	sh $S verify-image "$mk/images/bcachefs.erofs" "$mk/trees/bcachefs" 2>/dev/null && fail "verify-image passes changed bytes" ||
		ok "verify-image refuses changed bytes"
	printf 'not a module\n' | xz --check=crc32 > "$mk/trees/bcachefs/lib/modules/$km/extra/bcachefs/bcachefs.ko.xz"
else echo "  note no erofs-utils here: verify-image and kits not run"; fi
sh $S manifest bcachefs 1.36.1 $km > "$T/m1"
grep -qx 'name org.ribbon.kmod.bcachefs  version 1.36.1+6.18.63_1  kind system' "$T/m1" && grep -qx 'needs {{org.ribbon.kernel =6.18.63_1}}' "$T/m1" &&
	grep -qx "effects {{module lib/modules/$km/extra/bcachefs}}" "$T/m1" && ok "a module kit's manifest: system kind, its kernel kit exactly (D47), the module effect" ||
	fail "module manifest: $(cat "$T/m1")"
sh $S manifest firmware 20261115 $km | grep -qx 'effects {{firmware lib/firmware}}' && ok "the firmware kit's manifest has the firmware effect" || fail "firmware manifest"
if [ -n "${KITFMT_MK4TCL:-}" ] && [ -s "$mk/images/bcachefs.erofs" ]; then
	if KITPACK_VERITY=auto sh $S kits "$mk" > "$T/kits" 2>&1 && [ -s "$mk/kits/org.ribbon.kmod.bcachefs.kit" ] &&
		grep -q 'image ok' "$T/kits"; then
		ok "kits: the image packed as a system kit and verified with kitfmt (every chunk, the image, the root)"
	else fail "kits: $(tail -n3 "$T/kits")"; fi
else echo "  note no Mk4tcl (KITFMT_MK4TCL): kits not packed here"; fi
bv() { mkdir -p "$T/bv"; : > "$T/bv/kernel-summary.txt"; printf '%b' "$1" > "$T/bv/boot-serial.log"; sh $S boot-verdict "$T/bv"; }
case $(bv "KBOOT release $km\r\nKBOOT ok sched_ext\r\nKBOOT ok kit x\r\nKBOOT done\r\n") in "RESULT kernel-boot: ok ($km: 2 checks)") ok "boot verdict: every check ok and done passes";; *) fail "boot ok: $(bv "KBOOT release $km\nKBOOT ok a\nKBOOT done\n")";; esac
case $(bv "KBOOT release $km\nKBOOT ok a\nKBOOT FAIL erofs deflate\nKBOOT done\n") in *"FAILED (erofs deflate;)") ok "boot verdict: a FAIL line fails, by name";; *) fail "boot FAIL";; esac
case $(bv "KBOOT release $km\nKBOOT ok a\n") in *"FAILED"*"did not finish"*) ok "boot verdict: a test that did not finish fails";; *) fail "boot unfinished";; esac
case $(bv "KBOOT release 6.18.63_1\nKBOOT done\n") in *"FAILED (the kernel did not reach the test"*) ok "boot verdict: another kernel's release fails";; *) fail "boot release";; esac
sh $S boot-init > "$T/init" && sh -n "$T/init" && grep -q 'modinfo -F vermagic' "$T/init" && grep -q 'losetup -r -o' "$T/init" &&
	ok "the test initramfs's /init parses, checks every module's vermagic and mounts each kit at its offset" || fail "boot-init"

# ---- 5. the workflow
if python3 - "$Y" "$S" > "$T/yml" 2>&1 <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True) or d.get("on")
assert on["push"]["branches"] == ["ribbon-image"], on
j = d["jobs"]
assert set(j) == {"key", "build", "kits", "publish"}, list(j)
b = " ".join(str(s.get("run", "")) for s in j["build"]["steps"])
assert "ghcr.io/void-linux/void-glibc-full" in b and "kernel.sh void-ci" in b, "build: Void's container and void-ci"
assert j["build"]["needs"] == "key" and "cached" in j["build"]["if"], "build is skipped for a published key"
assert j["kits"]["needs"] == "build", "kits after build"
k = " ".join(str(s.get("run", "")) for s in j["kits"]["steps"])
assert "kernel.sh kits" in k and "kernel.sh boot" in k, "kits packs and boots"
p = [s for s in j["publish"]["steps"] if "kernel.sh publish" in str(s.get("run", ""))]
assert p and p[0].get("if") == "needs.kits.result == 'success'", "the release only when kits passed"
assert d["permissions"]["contents"] == "write" and d["permissions"]["actions"] == "write"
r = [s for s in j["publish"]["steps"] if "gh workflow run ribbon-image.yml" in str(s.get("run", ""))]
assert r and r[0].get("if") == "needs.kits.result == 'success'", "the image build runs again once the release exists"
cmds = set(re.findall(r"kernel\.sh ([a-z0-9-]+)", open(sys.argv[1]).read()))
case = set(re.findall(r"^([a-z0-9-]+)\) ", open(sys.argv[2]).read(), re.M))
assert cmds <= case, f"kernel.yml runs commands kernel.sh lacks: {cmds - case}"
print(len(cmds))
PY
then ok "kernel.yml: on the ribbon-image push; Void's container builds, kits and the boot test follow, the release only after them ($(cat "$T/yml") kernel.sh commands, all known)"
else fail "kernel.yml: $(tail -n2 "$T/yml")"; fi
# the image build uses the release: ribbon-image.yml fetches it before the packages, build-packages.sh takes the
# prebuilt kernel instead of building it (and lays out the config and the subpackage links when it does build it),
# and export.sh sends kernel.yml with the image workflow
if python3 - build/ci/ribbon-image.yml > "$T/img" 2>&1 <<'PY'
import sys, yaml
st = yaml.safe_load(open(sys.argv[1]))["jobs"]["image"]["steps"]
names = [s.get("name") for s in st]
f = names.index("Fetch Ribbon's kernel")
assert f < names.index("Build packages"), "fetch after the packages"
assert "kernel.sh fetch out/repo" in st[f]["run"], st[f]["run"]
assert st[f].get("env", {}).get("RIBBON_CI_REPO") == "${{ github.repository }}", "fetch: RIBBON_CI_REPO"
assert not st[f].get("continue-on-error"), "fetch: its own exit status says whether the image can go on"
PY
then ok "ribbon-image.yml: the image job fetches the kernel's release into out/repo before it builds the packages"
else fail "ribbon-image.yml's kernel fetch: $(tail -n2 "$T/img")"; fi
BP=build/build-packages.sh
grep -qF 'cp build/kernel/config/* "$VP/srcpkgs/$p/files/config/"' $BP && grep -qF 'ln -s ribbon-kernel "$VP/srcpkgs/$s"' $BP &&
	grep -qF '"$p"-headers-[0-9]*.xbps' $BP && ok "build-packages.sh lays out ribbon-kernel's config and subpackage links, collects headers" ||
	fail "build-packages.sh does not lay out ribbon-kernel (config, subpackage links, headers)"
# build-packages.sh in a copy of the tree, with git, xbps-src and xbps-rindex stood in for: it never builds
# ribbon-kernel; without a fetched release nothing it builds depends on it, with one ribbon-base keeps it
mkdir -p "$T/bp/build" "$T/bp/kit" "$T/bp/build/overrides" "$T/bin" && cp -a config srcpkgs LICENSE "$T/bp/" && cp $BP "$T/bp/build/" &&
	cp -a build/kernel "$T/bp/build/" && cp -a kit/kitfmt kit/kittrust "$T/bp/kit/" &&
	for o in base-files wlroots0.20; do mkdir -p "$T/bp/build/overrides/$o" && echo 'exit 0' > "$T/bp/build/overrides/$o/apply.sh"; done
cat > "$T/bin/git" <<'EOF'
#!/bin/sh
[ "$1" = clone ] || exit 0
for a; do vp=$a; done
mkdir -p "$vp/.git" "$vp/etc" "$vp/srcpkgs"
printf '#!/bin/sh\necho "$*" >> "$XS_LOG"\n' > "$vp/xbps-src" && chmod +x "$vp/xbps-src"
EOF
printf '#!/bin/sh\necho "rindex $*" >> "$XS_LOG"\n' > "$T/bin/xbps-rindex"
chmod +x "$T/bin/git" "$T/bin/xbps-rindex"
bp() { : > "$T/xs.log"; (cd "$T/bp" && PATH=$T/bin:$PATH XS_LOG=$T/xs.log RIBBON_REPO_DIR=$T/bp/out/repo bash build/build-packages.sh) > "$T/bp.log" 2>&1; }
deps() { bash -c '. "$1" >/dev/null 2>&1; echo $depends' deps "$T/bp/out/void-packages/srcpkgs/$1/template" | tr ' ' '\n'; }
if bp && ! grep -q 'pkg ribbon-kernel' "$T/xs.log" && grep -qx -- '-E pkg ribbon-base' "$T/xs.log" &&
	grep -q "ribbon-kernel: no release fetched, not built here" "$T/bp.log" && ! deps ribbon-base | grep -qx ribbon-kernel &&
	deps ribbon-base | grep -qx ribbon-dinit && deps ribbon-base | grep -qx ribbon-tools; then
	ok "build-packages.sh without a kernel release: ribbon-kernel is not built, and ribbon-base does not depend on it"
else fail "build-packages.sh without a release: $(grep ribbon-kernel "$T/xs.log" "$T/bp.log" | head -n3) $(tail -n2 "$T/bp.log")"; fi
mkdir -p "$T/bp/out/repo" && : > "$T/bp/out/repo/ribbon-kernel-$(tv version)_$(tv revision).x86_64.xbps"
# xbps-src looks for ribbon-base's run-time dependencies in its own repository only: the release is indexed there first
kx=ribbon-kernel-$(tv version)_$(tv revision).x86_64.xbps
if bp && ! grep -q 'pkg ribbon-kernel' "$T/xs.log" && grep -q 'ribbon-kernel: prebuilt' "$T/bp.log" && deps ribbon-base | grep -qx ribbon-kernel &&
	[ -f "$T/bp/out/void-packages/hostdir/binpkgs/$kx" ] &&
	awk -v k="rindex -a out/void-packages/hostdir/binpkgs/$kx" '$0 == k { i = NR } $0 == "-E pkg ribbon-base" { b = NR } END { exit !(i && b && i < b) }' "$T/xs.log"; then
	ok "build-packages.sh with the release fetched: the prebuilt ribbon-kernel is used (indexed in xbps-src's repository before ribbon-base), and ribbon-base depends on it"
else fail "build-packages.sh with a release: $(grep ribbon-kernel "$T/xs.log" "$T/bp.log" | head -n3) $(tail -n2 "$T/bp.log")"; fi
# kernel.sh fetch with the release lookup stood in for (curl): none for the key (404) is a notice and nothing
# fetched, exit 0; a release is downloaded and checked; GitHub unreachable fails
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
o= w= f=
while [ $# -gt 1 ]; do case $1 in -o) o=$2; shift ;; -w) w=$2; shift ;; -f*) f=1 ;; esac; shift; done
case $CURL_MODE in down) exit 7 ;; esac
src=$CURL_DIR/$(basename "$1")
if [ "$CURL_MODE" = served ] && [ -f "$src" ]; then cp "$src" "$o"; code=200; else echo 'Not Found' > "$o"; code=404; fi
[ -z "$w" ] || printf '%s' "$code"
[ "$code" = 200 ] || [ -z "$f" ] || exit 22
EOF
chmod +x "$T/bin/curl"
fe() { PATH=$T/bin:$PATH CURL_MODE=$1 CURL_DIR=$T/rel sh $S fetch "$2" > "$2.out" 2> "$2.err"; }
if fe none "$T/f1" && [ "$(cat "$T/f1.out")" = "no Ribbon kernel release for $tg: this image uses Void's linux6.18 only" ] &&
	[ -z "$(ls -A "$T/f1")" ]; then ok "fetch: no release for the key is one notice line, nothing fetched, exit 0 (Void's linux6.18 only)"
else fail "fetch without a release: $(cat "$T/f1.out" "$T/f1.err" 2>/dev/null) [$(ls -A "$T/f1" 2>/dev/null)]"; fi
mkdir -p "$T/rel" && echo pkg > "$T/rel/ribbon-kernel-$(tv version)_$(tv revision).x86_64.xbps" &&
	(cd "$T/rel" && sha256sum -- *.xbps > SHA256SUMS)
if fe served "$T/f2" && [ -s "$T/f2/ribbon-kernel-$(tv version)_$(tv revision).x86_64.xbps" ] && grep -qx "fetch: $tg into $T/f2" "$T/f2.out" &&
	! grep -q 'no Ribbon kernel release' "$T/f2.out"; then ok "fetch: a published release is downloaded into the repository and checked"
else fail "fetch with a release: $(cat "$T/f2.out" "$T/f2.err")"; fi
echo corrupt > "$T/rel/ribbon-kernel-$(tv version)_$(tv revision).x86_64.xbps"
fe served "$T/f3" && fail "fetch passes a release whose package does not match SHA256SUMS" || ok "fetch refuses a corrupt release"
fe down "$T/f4" && fail "fetch passes when the release cannot be looked up (network)" ||
	{ grep -q 'could not be looked up' "$T/f4.err" && ok "fetch fails when GitHub cannot be reached (only a 404 means no release)" || fail "fetch down: $(cat "$T/f4.err")"; }
if sh build/ci/export.sh --list 2>/dev/null | grep -qx '.github/workflows/kernel.yml'; then
	ok "export.sh sends kernel.yml as .github/workflows/kernel.yml"
else fail "export.sh does not export kernel.yml"; fi
if command -v shellcheck >/dev/null; then
	shellcheck -S warning $S $K tests/steps.d/93-ci-kernel.sh > "$T/sc" 2>&1 && ok "shellcheck (warnings): kernel.sh, kconfig.sh, this step" || fail "shellcheck: $(head -n5 "$T/sc")"
fi

[ $fails -eq 0 ] || exit 1
