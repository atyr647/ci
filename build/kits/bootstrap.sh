#!/bin/sh
# bootstrap.sh - build the base set (recipes/BASE: the C library, the compiler, a shell, the usual tools) from nothing
# but the host's compiler, in stages, until the set has built itself (docs/RECIPES.md, "The bootstrap").
#
#   build/kits/bootstrap.sh OUT [0|1|2|3]      (default 3: every stage; a number stops after that stage)
#
#   stage 0   recipes/bootstrap, against the host: the stand-in system        -> OUT/bootstrap/stage0
#   stage 1   every recipe of the set, in BASE's order, in a root that is the stand-in with the set's kits laid over
#             it as they are built (kit-build.sh's KIT_BOOTSTRAP)              -> OUT/bootstrap/stage1
#   stage 2   every recipe again, each in a root made of stage 1's kits alone: nothing of the host and nothing of
#             the stand-in is in it (KIT_SEED)                                 -> OUT/bootstrap/stage2
#   stage 3   and again, in roots of stage 2's kits                            -> OUT (kits/, trees/, images/, src/)
# Stage 3's kits are the base set: built by a set that was itself built by the set. Then each image is held against
# stage 2's: OUT/bootstrap/same.txt names the kits that came out the same, byte for byte, and differ.txt the others
# (the exit status is 0 either way: the lists say how far the set repeats itself).
# A stage whose inputs have not changed is not built again (kit-build.sh's key), so a run that stopped is run again.
# Only stage 3's kits are signed (KIT_SIGN). Hours of compiling. Environment otherwise as kit-build.sh's.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "bootstrap: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: bootstrap.sh OUT [0|1|2|3]"
mkdir -p "$1"; OUT=$(cd "$1" && pwd)
last=${2:-3}
case $last in 0|1|2|3) ;; *) die "stage '$last': 0, 1, 2 or 3" ;; esac
RDIR=${RECIPES:-$ROOT/recipes}
KB=$ROOT/build/kits/kit-build.sh
[ -f "$RDIR/BASE" ] || die "no $RDIR/BASE (the base set's names, in the first stage's order)"
set=$(grep -v '^#' "$RDIR/BASE" | tr '\n' ' ')
[ -n "$set" ] || die "$RDIR/BASE names no recipe"
for n in bootstrap $set; do [ -f "$RDIR/$n/recipe" ] || die "no recipe $n in $RDIR"; done
S=$OUT/bootstrap
unset KIT_SEED KIT_BOOTSTRAP KIT_BUILD_HOST
sign=${KIT_SIGN:-}; unset KIT_SIGN

echo "bootstrap: stage 0 (the stand-in, against the host)"
KIT_BUILD_HOST=1 sh "$KB" "$RDIR/bootstrap" "$S/stage0" || die "stage 0 did not build"
[ "$last" -ge 1 ] || exit 0

echo "bootstrap: stage 1 (the set, over the stand-in)"
built=
for n in $set; do
	KIT_BOOTSTRAP=$S/stage0 KIT_BOOTSTRAP_BUILT=$built sh "$KB" "$RDIR/$n" "$S/stage1" || die "stage 1: $n did not build"
	built="$built $n"
done
[ "$last" -ge 2 ] || exit 0

echo "bootstrap: stage 2 (the set, in roots of stage 1's kits)"
for n in $set; do
	KIT_SEED=$S/stage1 sh "$KB" "$RDIR/$n" "$S/stage2" || die "stage 2: $n did not build"
done
[ "$last" -ge 3 ] || exit 0

echo "bootstrap: stage 3 (the set, in roots of stage 2's kits)"
for n in $set; do
	KIT_SEED=$S/stage2 KIT_SIGN=$sign sh "$KB" "$RDIR/$n" "$OUT" || die "stage 3: $n did not build"
done
: > "$S/same.txt"; : > "$S/differ.txt"
for n in $set; do
	if cmp -s "$S/stage2/images/$n.erofs" "$OUT/images/$n.erofs"; then echo "$n" >> "$S/same.txt"; else echo "$n" >> "$S/differ.txt"; fi
done
echo "bootstrap: the base set is in $OUT/kits: $(wc -l < "$S/same.txt") of $(echo "$set" | wc -w) kits are the same, byte for byte, as the stage before made them$([ -s "$S/differ.txt" ] && echo "; not the same: $(tr '\n' ' ' < "$S/differ.txt")")"
