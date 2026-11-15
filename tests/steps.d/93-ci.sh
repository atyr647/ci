#!/bin/sh
# CI (build/ci): what goes to the public CI repository and what the check job there needs.
#   1. build/ci/export.sh --list: only srcpkgs, build, config, the kit libraries, LICENSE and the test suite it names
#      (tests, Makefile, kitfmt's test kits and key, kittrust's tools), the workflow from HEAD; never docs or boards;
#      a commit holding a private key, a token, or a test key that something shipped trusts is refused (in a clone);
#   2. every command and pkg-config module the tests look for is in build/ci/check-tools.txt, and on ubuntu-24.04
#      (the runner) every package that file names exists;
#   3. the workflows: ribbon-image.yml's check job runs build/ci/check.sh, the image job does not wait for it
#      (decision 6), the boot job publishes its results; build.yml's check job runs the same script;
#   4. build/ci/build-mk4tcl.sh refuses a tarball that is not the template's distfile (nothing is built here);
#   5. make install-mk4tcl (build/install/manifests/mk4tcl.manifest) with a built Mk4tcl (KITFMT_MK4TCL, as CI and
#      tests/run.sh set it): the template's files, Mk4tcl loads from the installed tree and kit reads a kit with it;
#      without a build the package is skipped.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---- 1. the export
if git rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git ls-files build/ci/export.sh)" ]; then
	if sh build/ci/export.sh --list > "$T/list" 2>"$T/list.err"; then
		bad=$(grep -vE '^(srcpkgs|build|config|tests)/|^(LICENSE|Makefile|README\.md|RIBBON_REVISION|\.github/workflows/(ribbon-image|kernel|labwc020-tests)\.yml)$|^kit/kitfmt/(kitfmt\.tcl|sha256\.tcl|pkgIndex\.tcl|kitpack|tests/.*)$|^kit/kittrust/(kittrust\.tcl|pkgIndex\.tcl|cli\.tcl|kitindex|kitkey|kitseal|publish\.tcl)$|^design/tools/gen_lock_osd\.py$' "$T/list" | head -n5)
		[ -z "$bad" ] && ok "the export holds only the shipped sources and the named test suite ($(wc -l < "$T/list") files)" ||
			fail "the export holds more: $(echo "$bad" | tr '\n' ' ')"
		miss=
		for f in tests/run.sh tests/steps.d/93-ci.sh Makefile build/ci/check.sh build/ci/check-tools.txt \
			build/ci/build-mk4tcl.sh kit/kittrust/kitkey kit/kitfmt/tests/golden/app.kit LICENSE; do
			grep -qx "$f" "$T/list" || miss="$miss $f"
		done
		[ -z "$miss" ] && ok "the export has what the check job runs (tests/run.sh, Makefile, build/ci/check.sh, kit test data)" ||
			fail "the export lacks$miss"
		grep -vx 'design/tools/gen_lock_osd.py' "$T/list" | grep -qE '^(docs|design|wip|systemdinit|out)/' &&
			fail "docs, boards or work in progress exported" || ok "no docs, design boards, wip or out/ exported"
		# every committed file an exported test reads (a path on a line, not after a #) is exported, or the check job
		# fails on it
		git ls-files | LC_ALL=C sort | LC_ALL=C comm -23 - "$T/list" > "$T/unexported"
		if python3 - "$T/unexported" "$T/list" > "$T/needs" 2>&1 <<'PY'
import subprocess, sys
paths = [p for p in open(sys.argv[1]).read().split("\n") if "/" in p]
exported = set(open(sys.argv[2]).read().split("\n"))
need = set()
for f in subprocess.run(["git", "ls-files", "tests", "Makefile"], capture_output=True, text=True).stdout.split():
    if f not in exported:  # not in the CI repository: never run there
        continue
    if f == "tests/steps.d/93-ci.sh":  # this file names paths to check them; its build.yml check skips in CI
        continue
    try:
        lines = open(f, encoding="utf-8").read().split("\n")
    except (OSError, UnicodeDecodeError):
        continue
    for i, l in enumerate(lines):
        for p in paths:
            j = l.find(p)
            if j >= 0 and "#" not in l[:j]:
                need.add(f"{p} ({f}:{i + 1})")
for n in sorted(need):
    print(n)
sys.exit(1 if need else 0)
PY
		then ok "every repository file the tests read is exported"
		else fail "the tests read files the export lacks: $(tr '\n' ' ' < "$T/needs")"; fi
	else
		sed 's/^/       /' "$T/list.err"; fail "export.sh --list"
	fi
	# a commit with a secret in it, in a throwaway clone (the export script of this tree run against the clone's HEAD)
	if git clone -q --no-checkout --local "$ROOT" "$T/clone" 2>/dev/null; then
		mkdir -p "$T/clone/build/ci" && cp build/ci/export.sh "$T/clone/build/ci/export.sh"
		commit_with() { # PATH CONTENT: a commit on the clone's HEAD with PATH set to CONTENT
			(cd "$T/clone" && git read-tree HEAD && b=$(printf '%s\n' "$2" | git hash-object -w --stdin) &&
				git update-index --add --cacheinfo "100644,$b,$1" &&
				git -c user.name=t -c user.email=t@localhost commit -q -m "test $1" >/dev/null)
		}
		refused() { # WHAT: the export of the clone's HEAD is refused
			if (cd "$T/clone" && sh build/ci/export.sh --list) >/dev/null 2>"$T/ref.err"; then
				fail "export.sh exported $1"
			elif grep -q 'nothing exported' "$T/ref.err"; then
				ok "export.sh refuses $1 ($(head -n1 "$T/ref.err" | sed 's/^export.sh: //'))"
			else
				sed 's/^/       /' "$T/ref.err"; fail "export.sh failed otherwise on $1"
			fi
			(cd "$T/clone" && git reset -q --soft HEAD~1 && git read-tree HEAD)
		}
		pem=$(printf -- '-----BEGIN %s-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\n-----END %s-----' \
			'RSA PRIVATE KEY' 'RSA PRIVATE KEY')
		commit_with srcpkgs/ribbon-base/files/deploy.pem "$pem" && refused "a private key in srcpkgs"
		commit_with tests/fixtures/token.txt "token=ghp_$(printf 'a%.0s' $(seq 36))" && refused "an access token in tests"
		commit_with tests/fixtures/other/stray.key "$(cat tests/fixtures/kittrust/test-root.key)" &&
			refused "a secret key that is not one of the named test keys"
		commit_with tests/kit-embedded.tcl "set key {$(cat tests/fixtures/kittrust/test-root.key)}" &&
			refused "a secret key pasted into a test script"
		commit_with srcpkgs/ribbon-kit/files/etc/trusted-root.pub "$(cat tests/fixtures/kittrust/test-root.pub)" &&
			refused "a test key that a shipped file trusts"
		if (cd "$T/clone" && sh build/ci/export.sh --list) >/dev/null 2>&1; then ok "the clone's own HEAD still exports"; else
			fail "the clone's HEAD does not export"; fi
	else
		echo "  skip the export refusals (cannot clone this checkout)"
	fi
else
	echo "  skip the export (not a git checkout: CI runs the exported tree)"
fi

# ---- 2. the tools the check job installs
if python3 - "$ROOT" > "$T/tools" 2>&1 <<'PY'
import os, re, sys
root = sys.argv[1]
names, pcs = {}, {}
dirs = [os.path.join(root, "tests")] + [os.path.join(root, "srcpkgs", p, "files", "tests") for p in os.listdir(os.path.join(root, "srcpkgs"))]
mk = [os.path.join(d, f) for d, _, fs in os.walk(os.path.join(root, "srcpkgs")) for f in fs if f == "Makefile"]
def add(tab, n, where):
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9._+-]*", n):
        tab.setdefault(n, where)
for d in dirs:
    for dp, _, fs in os.walk(d):
        if "/fixtures" in dp:
            continue
        for f in fs:
            p = os.path.join(dp, f)
            try:
                lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
            except OSError:
                continue
            rel = os.path.relpath(p, root)
            for i, l in enumerate(lines):
                for m in re.finditer(r"command -v ([A-Za-z0-9_.+-]+)|auto_execok ([A-Za-z0-9_.+-]+)", l):
                    add(names, m.group(1) or m.group(2), rel)
                m = re.search(r"for (\w+) in ([A-Za-z0-9 ._+-]+); do", l)
                if m and re.search(r'(command -v|auto_execok) "?\$\{?' + m.group(1) + r"\b", "\n".join(lines[i:i + 3])):
                    for n in m.group(2).split():
                        add(names, n, rel)
                for m in re.finditer(r"pkg-config (?:--\S+ )+([a-z][a-z0-9 ._+-]*)", l):
                    for n in m.group(1).split():
                        add(pcs, n, rel)
for p in mk:
    s = open(p).read()
    for m in re.finditer(r"^\s*LIBS\s*:?=\s*(.*)$", s, re.M):
        for n in m.group(1).split():
            if re.fullmatch(r"[a-z][a-z0-9._+-]*", n):
                add(pcs, n, os.path.relpath(p, root))
    for m in re.finditer(r"\$\(PKG_CONFIG\) (?:--\S+ )+([a-z][a-z0-9 ._+-]*)", s):
        for n in m.group(1).split():
            add(pcs, n, os.path.relpath(p, root))
have = set()
for l in open(os.path.join(root, "build/ci/check-tools.txt")):
    w = l.split()
    if w and not l.startswith("#") and w[0] != "+":
        have.add(w[0])
miss = [f"{n} ({w})" for n, w in sorted(names.items()) if n not in have] + \
       [f"pc:{n} ({w})" for n, w in sorted(pcs.items()) if "pc:" + n not in have]
print(f"{len(names)} commands, {len(pcs)} pkg-config modules")
for m in miss:
    print("MISSING " + m)
sys.exit(1 if miss else 0)
PY
then
	ok "check-tools.txt names every command and pkg-config module the tests look for ($(head -n1 "$T/tools"))"
else
	sed 's/^/       /' "$T/tools" | head -n 20; fail "build/ci/check-tools.txt misses what tests look for"
fi
if [ "$(. /etc/os-release 2>/dev/null; echo "${ID:-}-${VERSION_ID:-}")" = ubuntu-24.04 ] && command -v apt-cache >/dev/null 2>&1 &&
	apt-cache show bash >/dev/null 2>&1; then
	sh build/ci/check.sh packages > "$T/pkgs"
	# shellcheck disable=SC2046
	apt-cache policy $(cat "$T/pkgs") 2>/dev/null | awk '/^[^ ]/ { p = $1; sub(/:$/, "", p) } /Candidate:/ && $2 != "(none)" { print p }' |
		LC_ALL=C sort -u > "$T/have"
	miss=$(LC_ALL=C comm -23 "$T/pkgs" "$T/have" | tr '\n' ' ')
	[ -z "$miss" ] && ok "every package check.sh installs exists on ubuntu-24.04 ($(sh build/ci/check.sh packages | wc -l))" ||
		fail "not on ubuntu-24.04:$miss"
else
	echo "  skip the package names (not an ubuntu-24.04 host with apt lists)"
fi

# ---- 3. the workflows
if python3 -c 'import yaml' 2>/dev/null; then
	if python3 - > "$T/wf" 2>&1 <<'PY'
import subprocess, sys, yaml
bad = []
w = yaml.safe_load(open("build/ci/ribbon-image.yml"))
jobs = w.get("jobs", {})
if list(jobs)[:1] != ["check"]:
    bad.append("ribbon-image.yml: the check job is not the first job")
run = lambda j: "\n".join(s.get("run", "") for s in jobs.get(j, {}).get("steps", []))
if "build/ci/check.sh deps" not in run("check") or "build/ci/check.sh run" not in run("check"):
    bad.append("ribbon-image.yml: the check job does not run build/ci/check.sh deps and run")
if jobs.get("check", {}).get("runs-on") != "ubuntu-24.04":
    bad.append("ribbon-image.yml: the check job is not on ubuntu-24.04 (check-tools.txt names its packages)")
if "check" in str(jobs.get("image", {}).get("needs", "")):
    bad.append("ribbon-image.yml: the image job waits for the checks (decision 6: side by side while bringing up)")
needs = jobs.get("boot", {}).get("needs", [])
if sorted(needs if isinstance(needs, list) else [needs]) != ["check", "image"]:
    bad.append("ribbon-image.yml: the boot job (which publishes the results) does not wait for check and image")
dl = [s.get("with", {}).get("name") for s in jobs.get("boot", {}).get("steps", []) if "download-artifact" in s.get("uses", "")]
if "ribbon-check-results" not in dl:
    bad.append("ribbon-image.yml: the boot job does not take the checks' results")
if "check-summary.txt" not in run("boot") or "RESULT check: ok" not in run("boot"):
    bad.append("ribbon-image.yml: summary.txt does not carry the checks' RESULT, or the verdict ignores it")
import os
if os.path.exists(".github/workflows/build.yml"):  # not exported: the CI repository runs only ribbon-image.yml
    b = yaml.safe_load(open(".github/workflows/build.yml"))
    crun = "\n".join(s.get("run", "") for s in b["jobs"]["check"]["steps"])
    if "build/ci/check.sh deps" not in crun or "build/ci/check.sh run" not in crun:
        bad.append("build.yml: the check job does not run build/ci/check.sh")
elif os.path.exists(".git") and subprocess.run(["git", "ls-files", "--error-unmatch", ".github/workflows/build.yml"],
                                               capture_output=True).returncode == 0:
    bad.append("build.yml is committed but missing")
for x in bad:
    print(x)
sys.exit(1 if bad else 0)
PY
	then ok "ribbon-image.yml: check job first (build/ci/check.sh), image beside it, boot publishes both; build.yml the same"
	else sed 's/^/       /' "$T/wf"; fail "the workflows"; fi
else
	echo "  skip the workflows (no python3-yaml)"
fi

# ---- 4. build-mk4tcl.sh takes only the template's tarball
printf 'not metakit\n' > "$T/x" && tar czf "$T/fake.tar.gz" -C "$T" x
if sh build/ci/build-mk4tcl.sh "$T/fake.tar.gz" "$T/mkout" > "$T/b.out" 2>&1; then fail "build-mk4tcl.sh took a tarball that is not the template's"
elif grep -q "is not the template's distfile" "$T/b.out" && [ ! -e "$T/mkout" ]; then ok "build-mk4tcl.sh refuses a tarball that is not the template's distfile"
else sed 's/^/       /' "$T/b.out"; fail "build-mk4tcl.sh failed otherwise"; fi
mkdir -p "$T/notmk"
if sh build/ci/build-mk4tcl.sh "$T/notmk" "$T/mkout" > "$T/b.out" 2>&1; then fail "build-mk4tcl.sh took a directory that is not the Metakit source"
elif grep -q 'is not the Metakit source' "$T/b.out"; then ok "build-mk4tcl.sh refuses a directory that is not the Metakit source"
else sed 's/^/       /' "$T/b.out"; fail "build-mk4tcl.sh failed otherwise"; fi

# ---- 5. make install-mk4tcl
ver=$(XBPS_CROSS_BASE='' bash -c '. "$1" >/dev/null 2>&1; echo $version' _ srcpkgs/mk4tcl/template)
O=$T/o D=$T/root
if O=$O DESTDIR=$D sh build/install/install.sh install mk4tcl --if-built > "$T/i.out" 2>&1 && [ ! -e "$D" ] &&
	grep -q 'mk4tcl skipped' "$T/i.out"; then
	ok "make install without a built Mk4tcl skips mk4tcl and installs nothing of it"
else
	sed 's/^/       /' "$T/i.out"; fail "install mk4tcl --if-built without a build"
fi
lib=
[ -n "${KITFMT_MK4TCL:-}" ] && lib=$(find "$KITFMT_MK4TCL" -maxdepth 2 -name "libMk4tcl$ver.so" 2>/dev/null | head -n1)
if [ -n "$lib" ] && command -v tclsh8.6 >/dev/null 2>&1; then
	# O/mk4tcl as build/ci/build-mk4tcl.sh leaves it: the library, the template's pkgIndex.tcl line, license.terms
	mkdir -p "$O/mk4tcl"
	cp "$lib" "$O/mk4tcl/"
	# shellcheck disable=SC2016
	printf 'package ifneeded Mk4tcl %s [list load [file join $dir libMk4tcl%s.so] Mk4tcl]\n' "$ver" "$ver" > "$O/mk4tcl/pkgIndex.tcl"
	commit=$(XBPS_CROSS_BASE='' bash -c '. "$1" >/dev/null 2>&1; echo $_mkcommit' _ srcpkgs/mk4tcl/template)
	if [ -f "$(dirname "$lib")/license.terms" ]; then cp "$(dirname "$lib")/license.terms" "$O/mk4tcl/"
	elif [ -f "${KIT_METAKIT_TARBALL:-}" ]; then tar xzf "$KIT_METAKIT_TARBALL" -O "metakit-$commit/license.terms" > "$O/mk4tcl/license.terms"
	else : > "$O/mk4tcl/license.terms"; fi
	# ribbon-kit's own native part (kit-landlock) built into O as make build does
	if O=$O DESTDIR=$D sh build/install/install.sh install mk4tcl > "$T/i.out" 2>&1 &&
		O=$O sh build/install/build.sh ribbon-kit >> "$T/i.out" 2>&1 &&
		O=$O DESTDIR=$D sh build/install/install.sh install ribbon-kit >> "$T/i.out" 2>&1; then
		want="/usr/lib/Mk4tcl$ver d755
/usr/lib/Mk4tcl$ver/libMk4tcl$ver.so f755
/usr/lib/Mk4tcl$ver/pkgIndex.tcl f644
/usr/share/licenses/mk4tcl/license.terms f644"
		got=$(cd "$D" && find ./usr/lib/Mk4tcl* ./usr/share/licenses/mk4tcl/license.terms -printf '%p %y%m\n' 2>/dev/null | sed 's|^\./|/|' | LC_ALL=C sort)
		[ "$got" = "$want" ] && ok "make install-mk4tcl puts down the template's files (/usr/lib/Mk4tcl$ver, the license)" ||
			{ echo "$got" | sed 's/^/       /'; fail "make install-mk4tcl's files"; }
		cmp -s "$O/mk4tcl/pkgIndex.tcl" "$D/usr/lib/Mk4tcl$ver/pkgIndex.tcl" || fail "the installed pkgIndex.tcl is not the template's line"
		where=$(echo 'puts [lindex [package ifneeded Mk4tcl [package require Mk4tcl]] end-1]' |
			env -u KITFMT_MK4TCL TCLLIBPATH="$D/usr/lib" tclsh8.6 2>&1)
		[ "$where" = "$D/usr/lib/Mk4tcl$ver/libMk4tcl$ver.so" ] && ok "package require Mk4tcl loads the installed library" ||
			fail "package require Mk4tcl from the installed tree: $where"
		kitinfo() {
			env -u KITFMT_MK4TCL HOME="$T/h" XDG_DATA_HOME="$T/h/data" XDG_CACHE_HOME="$T/h/cache" KIT_LIB="$D/usr/lib/ribbon/kit" \
				TCLLIBPATH="$D/usr/lib" timeout 60 tclsh8.6 "$D/usr/bin/kit" info "$ROOT/kit/kitfmt/tests/golden/app.kit" 2>&1
		}
		out=$(kitinfo)
		echo "$out" | grep -q 'org.ribbon.golden.app' && ok "the installed kit reads a kit with the installed Mk4tcl (kit info)" ||
			{ echo "$out" | sed 's/^/       /' | head -n5; fail "kit info with the installed Mk4tcl"; }
		O=$O DESTDIR=$D sh build/install/install.sh uninstall mk4tcl > /dev/null 2>&1
		out=$(kitinfo)
		if [ ! -e "$D/usr/lib/Mk4tcl$ver" ] && echo "$out" | grep -q "can't find package Mk4tcl"; then
			ok "uninstalled again, kit cannot read the kit (Mk4tcl is what it read it with)"
		else
			echo "$out" | sed 's/^/       /' | head -n3; fail "uninstall mk4tcl"
		fi
	else
		sed 's/^/       /' "$T/i.out"; fail "install.sh install mk4tcl ribbon-kit with a built Mk4tcl"
	fi
else
	echo "  skip make install-mk4tcl with a built Mk4tcl (KITFMT_MK4TCL names no libMk4tcl$ver.so)"
fi

[ "$fails" = 0 ] && { echo "ci: all checks passed"; exit 0; }
echo "ci: $fails check(s) failed"
exit 1
