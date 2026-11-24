#!/bin/sh
# kit-lint.sh - hold the recipes to each other, without building anything (docs/RECIPES.md).
#
#   build/kits/kit-lint.sh [RECIPES-DIR]        (default recipes/)
#
# Every recipe reads (kit-build.sh --info); no two make one kit; every kit a recipe needs, to run or to build, is made
# by a recipe, is one of Ribbon's own (org.ribbon.*, build/kits/ribbon-kits.sh), or is in RECIPES-DIR/WANTED: the
# kits recipes name that nothing makes yet, one per line (a kit that needs one of them cannot be installed yet). A
# WANTED line that a recipe makes, or that no recipe names, is stale and fails. BASE names recipes, each once; a
# recipe of the base set is built with the base set alone (its build_needs are all the set's kits); every recipe but the
# stand-in names build_needs (kit-build.sh refuses one without, unless told KIT_BUILD_HOST=1); the stand-in
# (bootstrap) is not in the set and nothing needs its kit.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RDIR=${1:-$ROOT/recipes}
RDIR=$(cd "$RDIR" 2>/dev/null && pwd) || { echo "kit-lint: no recipes directory ${1:-recipes}" >&2; exit 1; }
KB=$ROOT/build/kits/kit-build.sh
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
bad=0
say() { echo "kit-lint: $*" >&2; bad=1; }
: > "$T/kits"
for d in "$RDIR"/*/; do
	[ -f "$d/recipe" ] || { say "$(basename "$d") has no recipe"; continue; }
	n=$(basename "$d")
	if ! sh "$KB" --info "$d" > "$T/$n.info" 2> "$T/err"; then say "$(cat "$T/err")"; rm -f "$T/$n.info"; continue; fi
	k=$(sed -n 's/^kit //p' "$T/$n.info")
	other=$(awk -F'\t' -v k="$k" '$2 == k { print $1 }' "$T/kits")
	[ -z "$other" ] || say "$n and $other both make the kit $k"
	printf '%s\t%s\n' "$n" "$k" >> "$T/kits"
done
made() { cut -f2 "$T/kits" | grep -qx "$1"; }
wanted=$(grep -v '^#' "$RDIR/WANTED" 2>/dev/null | tr '\n' ' ' || :)
base=$(grep -v '^#' "$RDIR/BASE" 2>/dev/null | tr '\n' ' ' || :)
named=
for f in "$T"/*.info; do
	[ -f "$f" ] || continue
	n=$(basename "$f" .info)
	for kind in needs build_needs; do
		# shellcheck disable=SC2013
		for k in $(sed -n "s/^$kind //p" "$f"); do
			named="$named $k"
			[ "$k" != org.ribbon.bootstrap ] || { say "$n names the stand-in's kit in its $kind: nothing needs it, bootstrap.sh puts it under stage 1"; continue; }
			made "$k" && continue
			case $k in org.ribbon.*) continue ;; esac
			case " $wanted " in *" $k "*) continue ;; esac
			say "$n: $kind names $k, which no recipe makes (write its recipe, or list it in WANTED)"
		done
	done
done
for f in "$T"/*.info; do
	[ -f "$f" ] || continue
	n=$(basename "$f" .info)
	[ "$n" = bootstrap ] || [ -n "$(sed -n 's/^build_needs //p' "$f")" ] ||
		say "$n has no build_needs: a kit is built in a root of the kits it names (only the stand-in, bootstrap, is built against the host)"
done
for k in $wanted; do
	if made "$k"; then say "WANTED lists $k, which a recipe makes now: take the line out"; fi
	case " $named " in *" $k "*) ;; *) say "WANTED lists $k, which no recipe names" ;; esac
done
basekits=
for n in $base; do
	[ -f "$T/$n.info" ] || { say "BASE names $n: no such recipe"; continue; }
	[ "$n" != bootstrap ] || say "BASE names bootstrap: the stand-in is not of the set"
	[ "$(echo "$base" | tr ' ' '\n' | grep -cx "$n")" = 1 ] || say "BASE names $n more than once"
	basekits="$basekits $(sed -n 's/^kit //p' "$T/$n.info")"
done
for n in $base; do
	[ -f "$T/$n.info" ] || continue
	# shellcheck disable=SC2013
	for k in $(sed -n 's/^build_needs //p; s/^needs //p' "$T/$n.info"); do
		case " $basekits " in *" $k "*) ;; *) say "$n is of the base set and needs $k, which is not: the set is built with itself alone" ;; esac
	done
done
[ "$bad" = 0 ] || exit 1
echo "kit-lint: $(wc -l < "$T/kits") recipes ($(echo "$base" | wc -w) of the base set), $(echo "$wanted" | wc -w) kits wanted"
