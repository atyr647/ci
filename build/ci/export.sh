#!/bin/sh
# export.sh - send what the image build needs to the CI repository, and so start a CI run.
#
# Ribbon's repository is private and has no Actions minutes; its CI runs in the owner's public repository
# (atyr647/ci by default), on a branch of its own (ribbon-image) that holds nothing but one commit: the committed
# state of srcpkgs/, build/, config/, recipes/ (decision 141), the kit reader and trust library that ribbon-kit ships, LICENSE, the test
# suite with what it runs (TESTS below, named one by one), and the workflow build/ci/ribbon-image.yml as
# .github/workflows/ribbon-image.yml. A push to that branch runs the workflow (the checks, packages, ISO, boot test);
# its results come back on the branch ribbon-results (build/ci/results.sh fetches them). Docs, design boards and
# the rest of the repository are not exported. Only committed files are (git archive HEAD). The export is refused
# when it holds a private key or an access token anywhere but in the named test-only key fixtures (KEYS), or when
# one of those fixtures' public keys is trusted by anything shipped (srcpkgs, build, config).
#
#   build/ci/export.sh [CI-CLONE]      CI-CLONE: a clone of the CI repository (default ../ci)
#   build/ci/export.sh --list          print what would be exported (after the same checks); nothing is pushed
set -eu
cd "$(dirname "$0")/../.."
SHIPPED="srcpkgs build config recipes LICENSE
kit/kitfmt/kitfmt.tcl kit/kitfmt/sha256.tcl kit/kitfmt/pkgIndex.tcl kit/kitfmt/kitpack
kit/kittrust/kittrust.tcl kit/kittrust/pkgIndex.tcl"
# the test suite (build/ci/check.sh runs it): tests/, the Makefile its install step drives, kitfmt's golden kits and
# test key, kittrust's publishing tools (kitkey, kitindex, kitseal) that the kit tests sign with, and the lock and
# OSD boards' generator, whose geometry tests/test-ribbon-lock.sh reads (no board itself)
TESTS="tests Makefile kit/kitfmt/tests
kit/kittrust/cli.tcl kit/kittrust/kitindex kit/kittrust/kitkey kit/kittrust/kitseal kit/kittrust/publish.tcl
design/tools/gen_lock_osd.py"
# left out: the coordination documents' own tests (docs-state; the wording of docs/TERMINAL.md and the native test
# scripts) and the Mail boards' generator test (docs/ and design/ are not
# exported, so they have nothing to read there)
NOTTESTS="tests/test-docs-state.py tests/steps.d/96-docs-state.sh tests/steps.d/63-mail-boards.sh
tests/steps.d/12-test-root-wording.sh"
# the only private keys the export may hold: minisign keys made for the tests, trusted by nothing that ships
KEYS="tests/fixtures/kittrust/*.key kit/kitfmt/tests/keys/test.key"
list=
case ${1:-} in --list) list=1; shift ;; esac
CI=${1:-../ci}
BRANCH=${RIBBON_CI_BRANCH:-ribbon-image}
[ -n "$list" ] || [ -d "$CI/.git" ] || { echo "export.sh: $CI is not a clone of the CI repository" >&2; exit 1; }
rev=$(git rev-parse --short HEAD)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/tree"
# shellcheck disable=SC2086
git archive HEAD -- $SHIPPED $TESTS | tar -x -C "$T/tree"
for f in $NOTTESTS; do rm -f "$T/tree/$f"; done
bad=0
# the files that hold a private key (a PEM block, a minisign secret key file or its key line anywhere) or an access
# token (GitHub, AWS, Slack)
(cd "$T/tree" && {
	grep -rlaE -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|RW(RTY0Iy|QAAEIy)[A-Za-z0-9+/]{200}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}' . || :
	find . -type f -exec awk 'FNR == 1 && /^untrusted comment: minisign .*secret key/ { print FILENAME } { nextfile }' {} +
}) | sed 's|^\./||' | LC_ALL=C sort -u > "$T/secrets"
while IFS= read -r f; do
	fixture=
	for k in $KEYS; do
		# shellcheck disable=SC2254
		case $f in $k) fixture=1 ;; esac
	done
	if [ -z "$fixture" ]; then
		echo "export.sh: $f holds a private key or an access token" >&2; bad=1; continue
	fi
	pub=$T/tree/${f%.key}.pub
	[ -f "$pub" ] || { echo "export.sh: test key $f has no ${f%.key}.pub beside it" >&2; bad=1; continue; }
	if (cd "$T/tree" && grep -rlF "$(tail -n1 "$pub")" srcpkgs build config) >/dev/null 2>&1; then
		echo "export.sh: the test key ${f%.key}.pub is trusted by shipped files" >&2; bad=1
	fi
done < "$T/secrets"
[ "$bad" = 0 ] || { echo "export.sh: nothing exported" >&2; exit 1; }
mkdir -p "$T/tree/.github/workflows"
cp "$T/tree/build/ci/ribbon-image.yml" "$T/tree/.github/workflows/ribbon-image.yml"
cp "$T/tree/build/ci/kernel.yml" "$T/tree/.github/workflows/kernel.yml"
cp "$T/tree/build/ci/labwc020-tests.yml" "$T/tree/.github/workflows/labwc020-tests.yml"
printf '%s\n' "# Ribbon OS image build" "" \
	"An export of the Ribbon OS sources (MIT) at revision $rev, for the image build workflow. Not a development" \
	"repository: the branch is replaced on every export." > "$T/tree/README.md"
echo "$rev" > "$T/tree/RIBBON_REVISION"
[ -z "$list" ] || { (cd "$T/tree" && find . ! -type d ! -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort); exit 0; }
# one commit, no history: the branch is replaced each time
url=$(git -C "$CI" remote get-url origin)
git -C "$T/tree" init -q -b "$BRANCH"
git -C "$T/tree" add -A
git -C "$T/tree" -c user.name="Ribbon CI export" -c user.email="noreply@anthropic.com" commit -q -m "Ribbon $rev: image build export"
git -C "$T/tree" push -q -f "$url" "$BRANCH:$BRANCH"
echo "exported $rev to $url ($BRANCH): $(git -C "$T/tree" ls-files | wc -l) files"
