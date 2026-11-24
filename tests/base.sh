# tests/base.sh - which base the build is for, for the checks that hold
# Ribbon to one base's packaging (sourced by tests/steps.d and tests/run.sh).
# Decision 5 (docs/DECISIONS-DELEGATED.md): Void for the first image, so a
# build is for Void unless RIBBON_BASE (the environment, else
# config/ribbon.conf) names another base.
#
#   ribbon_base           void | another base's name
#   base_only BASE WHAT   0 when the build is for BASE; else prints a skip for WHAT
ribbon_base() {
	if [ -n "${RIBBON_BASE:-}" ]; then echo "$RIBBON_BASE"; return; fi
	b=$(sed -n 's/^: "\${RIBBON_BASE:=\([A-Za-z0-9_-]*\)}"$/\1/p' config/ribbon.conf 2>/dev/null | head -n1)
	echo "${b:-void}"
}
base_only() {
	[ "$(ribbon_base)" = "$1" ] && return 0
	echo "  skip $2 (base-specific: $1 packaging; this build is for $(ribbon_base))"
	return 1
}
