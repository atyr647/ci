#!/bin/sh
# The recipes held to each other (build/kits/kit-lint.sh): Ribbon's own recipes pass, and each thing the lint is for
# fails on a fixture set.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
KL=$ROOT/build/kits/kit-lint.sh
if sh "$KL" >"$T/log" 2>&1; then ok "Ribbon's recipes: $(sed 's/^kit-lint: //' "$T/log")"; else bad "Ribbon's recipes: $(cat "$T/log")"; fi
rec() { # NAME KIT NEEDS BUILD_NEEDS
	mkdir -p "$T/r/$1"
	printf 'name=%s\nkit=%s\nversion=1\nrevision=1\nsummary="x"\nlicense="MIT"\nneeds="%s"\nbuild_needs="%s"\nstage() { :; }\n' "$1" "$2" "$3" "$4" > "$T/r/$1/recipe"
}
fresh() { rm -rf "$T/r"; rec sh org.test.sh "" "org.test.sh org.test.cc"; rec cc org.test.cc "org.test.sh" "org.test.sh org.test.cc"
	rec app org.test.app "org.test.sh org.test.later org.ribbon.kit" "org.test.cc"; printf 'sh\ncc\n' > "$T/r/BASE"; echo org.test.later > "$T/r/WANTED"; }
refused() { # WHAT MESSAGE
	if sh "$KL" "$T/r" >"$T/log" 2>&1 || ! grep -q "$2" "$T/log"; then bad "$1: $(cat "$T/log")"; else ok "$1"; fi
}
fresh
if sh "$KL" "$T/r" >"$T/log" 2>&1; then ok "a set in which every need is a recipe's, Ribbon's own or wanted passes (a base set that needs itself too)"; else bad "the fixture set: $(cat "$T/log")"; fi
: > "$T/r/WANTED"; refused "a need nothing makes and WANTED does not list is refused" "app: needs names org.test.later, which no recipe makes"
fresh; rec later org.test.later "" "org.test.cc"; refused "a WANTED line a recipe makes now is stale" "WANTED lists org.test.later, which a recipe makes now"
fresh; echo org.test.never >> "$T/r/WANTED"; refused "a WANTED line no recipe names is stale" "WANTED lists org.test.never, which no recipe names"
fresh; rec two org.test.app "" "org.test.cc"; refused "two recipes that make one kit are refused" "both make the kit org.test.app"
fresh; rec cc org.test.cc "org.test.sh" "org.test.sh org.test.app"; refused "a base recipe that needs a kit outside the base set is refused" "cc is of the base set and needs org.test.app, which is not"
fresh; rec app org.test.app "org.test.sh" ""; refused "a recipe without build_needs is refused (it would be built against the host)" "app has no build_needs"
fresh; rec sh org.test.sh "" ""; refused "  and so is a base recipe" "sh has no build_needs"
fresh; rec bootstrap org.test.bootstrap "" ""
if sh "$KL" "$T/r" >"$T/log" 2>&1; then ok "  but not the stand-in (bootstrap), which is built against the host"; else bad "the stand-in without build_needs: $(cat "$T/log")"; fi
fresh; echo gone >> "$T/r/BASE"; refused "a BASE line without a recipe is refused" "BASE names gone: no such recipe"
fresh; rec app org.test.app "org.test.sh" "org.ribbon.bootstrap"; refused "a recipe that names the stand-in's kit is refused" "app names the stand-in's kit"
fresh; sed -i 's/^version=1/version=/' "$T/r/app/recipe"; refused "a recipe that does not read is refused" "no version"
exit $fail
