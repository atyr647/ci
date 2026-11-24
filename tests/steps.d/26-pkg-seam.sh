#!/bin/sh
# The package manager's seam (pkg.sh, pkg.tcl, pkg-names.xbps; tests/pkg-seam.sh), and the base-specific steps
# (tests/base.sh): Void's packaging checks run for a build for Void (decision 5) and skip for any other base.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v bash >/dev/null 2>&1 || { echo "  skip package seam (no bash)"; exit 0; }
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip package seam (no tclsh8.6)"; exit 0; }
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
bash tests/pkg-seam.sh || fails=$((fails + 1))

echo "base-specific steps"
. tests/base.sh
[ "$(RIBBON_BASE='' ribbon_base)" = void ] && ok "the build is for Void unless a base is named (decision 5)" || fail "default base is $(RIBBON_BASE='' ribbon_base)"
out=$(RIBBON_BASE=elsewhere sh tests/steps.d/05-drop-in.sh 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q '^  skip drop-in' && ! printf '%s\n' "$out" | grep -q '  ok   '; then
	ok "05-drop-in skips for another base"
else
	fail "05-drop-in on another base: rc $rc, $out"
fi
if grep -q '^VOID=0; base_only void ' tests/steps.d/90-install.sh && grep -q '\[ "\$VOID" = 1 \] || { ok "\$p installs alone"; continue; }' tests/steps.d/90-install.sh; then
	ok "90-install holds packages to their templates only for Void (each still installs alone)"
else
	fail "90-install's template comparison is not base-specific"
fi
grep -qxF ': "${RIBBON_BASE:=void}"' config/ribbon.conf && [ "$(RIBBON_BASE='' ribbon_base)" = void ] &&
	ok "config/ribbon.conf names the base (RIBBON_BASE, the form tests/base.sh reads)" || fail "config/ribbon.conf does not name RIBBON_BASE"
if grep -q '^\. tests/base.sh' tests/run.sh && grep -qF 'if base_only void "the runit -> dinit generator"; then run sh tests/test-sv2dinit.sh; fi' tests/run.sh &&
	grep -qF 'if ! base_only void "Void'"'"'s package names"; then :' tests/run.sh; then
	ok "run.sh runs the runit generator and Void's package-name check only for Void"
else
	fail "run.sh's runit generator or package-name check is not base-specific"
fi
# check-packages.py takes the names from the seam's map (the tools now carry ids, which Void does not have)
cp_names=$(python3 -c 'import importlib.util as u, sys; s = u.spec_from_file_location("cp", "build/tools/check-packages.py"); m = u.module_from_spec(s); s.loader.exec_module(m); print(" ".join(sorted({n for w, n in m.wanted() if w == "pkg-names.xbps"})))' 2>&1)
map_names=$(sed 's/#.*//' srcpkgs/ribbon-tools/files/lib/pkg-names.xbps | awk 'NF >= 2 { for (i = 2; i <= NF; i++) print $i }' | sort -u | tr '\n' ' ')
[ "$cp_names " = "$map_names" ] && ok "check-packages.py checks exactly the map's Void names" || fail "check-packages.py names: $cp_names; map: $map_names"
[ "$fails" -eq 0 ] || { echo "package seam step: $fails failure(s)"; exit 1; }
