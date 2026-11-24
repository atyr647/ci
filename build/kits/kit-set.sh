#!/bin/sh
# kit-set.sh - build a set of recipes in the order they need each other (docs/RECIPES.md).
#
#   build/kits/kit-set.sh OUT [RECIPES-DIR [NAME...]]     (default: recipes/, every recipe in it)
#
# A recipe comes after the recipes that make the kits it needs to build (build_needs) and to run (needs); a circle is
# refused, and so is a build_needs that no recipe of the set and no kit already in OUT provides. Each recipe is built by
# kit-build.sh (which skips a build whose inputs have not changed). Then no path may be in two of OUT's kits, and
#   OUT/kits.txt    "KIT VERSION FILE" for every kit in OUT
#   OUT/unmet.txt   "KIT NEEDS" for every run-time need that no kit in OUT meets (such a kit cannot be installed yet)
# The base set (the names in RECIPES-DIR/BASE) and the stand-in it starts from (bootstrap) need each other in a circle:
# they are bootstrap.sh's to build and are left out here unless named; their kits, once in OUT, are what the other
# recipes' roots are made of. With KIT_SEED=DIR (kit-build.sh) every build need comes from DIR, an earlier stage, so
# build needs give no order and may run in a circle.
# With KIT_SET_KEEP_GOING=1 a recipe that cannot be built (a missing source, a failed build) is said and left out, with
# everything that needs it to build; the exit status is still 1. Environment otherwise as kit-build.sh's.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "kit-set: $*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: kit-set.sh OUT [RECIPES-DIR [NAME...]]"
mkdir -p "$1"; OUT=$(cd "$1" && pwd); shift
RDIR=$ROOT/recipes
if [ $# -ge 1 ]; then RDIR=$(cd "$1" 2>/dev/null && pwd) || die "no recipes directory $1"; shift; fi
KB=$ROOT/build/kits/kit-build.sh
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
if [ $# -eq 0 ]; then
	base=" bootstrap $(grep -v '^#' "$RDIR/BASE" 2>/dev/null | tr '\n' ' ')"
	for d in "$RDIR"/*/; do
		[ -f "$d/recipe" ] || continue
		case $base in *" $(basename "$d") "*) continue ;; esac
		set -- "$@" "$(basename "$d")"
	done
fi
[ $# -ge 1 ] || die "no recipes in $RDIR"

# ---- every recipe's kit, needs and build_needs ---------------------------------------------------------------------
: > "$T/kits"
for n; do
	[ -f "$RDIR/$n/recipe" ] || die "no recipe $n in $RDIR"
	sh "$KB" --info "$RDIR/$n" > "$T/$n.info" || exit 1
	k=$(sed -n 's/^kit //p' "$T/$n.info")
	other=$(awk -F'\t' -v k="$k" '$2 == k { print $1 }' "$T/kits")
	[ -z "$other" ] || die "$n and $other both make the kit $k"
	printf '%s\t%s\n' "$n" "$k" >> "$T/kits"
done
recipe_of() { awk -F'\t' -v k="$1" '$2 == k { print $1 }' "$T/kits"; }
in_out() { grep -qs "^name $1  *version " "$OUT"/src/*.manifest 2>/dev/null; }
: > "$T/edges"
for n; do
	echo "$n $n" >> "$T/edges"
	# shellcheck disable=SC2013
	for k in $(sed -n 's/^build_needs //p' "$T/$n.info"); do
		[ -z "${KIT_SEED:-}" ] || continue
		r=$(recipe_of "$k")
		if [ -n "$r" ]; then echo "$r $n" >> "$T/edges"
		elif ! in_out "$k"; then die "$n needs $k to build: no recipe of this set makes it and $OUT holds no such kit"; fi
	done
	# shellcheck disable=SC2013
	for k in $(sed -n 's/^needs //p' "$T/$n.info"); do
		[ -z "${KIT_SEED:-}" ] || continue
		r=$(recipe_of "$k"); [ -z "$r" ] || echo "$r $n" >> "$T/edges"
	done
done
order=$(tsort "$T/edges" 2>"$T/tsort.err") || die "the recipes need each other in a circle: $(sed -n 's/^tsort: *//p' "$T/tsort.err" | grep -v 'input contains a loop' | tr '\n' ' ')"

# ---- build, in order -------------------------------------------------------------------------------------------------
failed=
for n in $order; do
	# what needs a failed recipe to build cannot be built either
	blocked=
	# shellcheck disable=SC2013
	for k in $(sed -n 's/^build_needs //p' "$T/$n.info"); do
		[ -z "${KIT_SEED:-}" ] || continue
		r=$(recipe_of "$k"); case " $failed " in *" ${r:-/} "*) blocked=$r ;; esac
	done
	if [ -n "$blocked" ]; then echo "kit-set: $n left out: it needs $blocked to build" >&2; failed="$failed $n"; continue; fi
	if sh "$KB" "$RDIR/$n" "$OUT"; then :
	elif [ -n "${KIT_SET_KEEP_GOING:-}" ]; then echo "kit-set: $n left out (above)" >&2; failed="$failed $n"
	else die "$n did not build; nothing after it was tried"; fi
done

# ---- the set as a whole ------------------------------------------------------------------------------------------------
cd "$ROOT"
. build/kits/lib.sh
trees=$(for m in "$OUT"/src/*.manifest; do [ -f "$m" ] && [ -d "$OUT/trees/$(basename "$m" .manifest)" ] && basename "$m" .manifest; done)
# shellcheck disable=SC2086
clash=$(kit_clashes "$OUT/trees" $trees)
[ -z "$clash" ] || { echo "$clash" >&2; die "two kits bring the same path (above)"; }
: > "$OUT/kits.txt"; : > "$OUT/unmet.txt"
for t in $trees; do
	m=$OUT/src/$t.manifest
	k=$(sed -n 's/^name \([^ ]*\)  *version \([^ ]*\).*/\1/p' "$m"); v=$(sed -n 's/^name \([^ ]*\)  *version \([^ ]*\).*/\2/p' "$m")
	[ -f "$OUT/kits/$k-$v.kit" ] || continue
	printf '%s\t%s\t%s\n' "$k" "$v" "$OUT/kits/$k-$v.kit" >> "$OUT/kits.txt"
done
for t in $trees; do
	m=$OUT/src/$t.manifest
	k=$(sed -n 's/^name \([^ ]*\) .*/\1/p' "$m")
	# shellcheck disable=SC2013
	for need in $(sed -n 's/^needs //p' "$m" | tr '{}' '  ' | tr ' ' '\n' | grep -E '^[a-z0-9-]+(\.[a-z0-9-]+)+$' || :); do
		cut -f1 "$OUT/kits.txt" | grep -qx "$need" || printf '%s\t%s\n' "$k" "$need" >> "$OUT/unmet.txt"
	done
done
echo "kit-set: $(wc -l < "$OUT/kits.txt") kits in $OUT/kits; $(wc -l < "$OUT/unmet.txt") run-time needs not met by any of them (unmet.txt)${failed:+; NOT built:$failed}"
[ -z "$failed" ]
