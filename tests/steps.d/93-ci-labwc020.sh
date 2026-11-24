#!/bin/sh
# CI's labwc 0.20 and installed-image jobs (build/ci/labwc020-tests.yml), what can be checked of them here:
#   1. the workflow: the labwc020 job makes the root and runs build/ci/labwc020.sh; the installed job waits for this
#      commit's ISO and runs build/ci/installed-test.sh; the results go to their own branch, not ribbon-results;
#   2. labwc020.sh runs the five test halves named in the audit (80-alttab-native, alttab-native/run.sh with PROFILE,
#      65-settings-input-live, 65-term, 57-hud-surface) and the wlr-randr key check, each against the root;
#   3. its verdicts: a FAIL, an exit status, a skip or a labwc 0.7 fallback under the root each fail a check;
#   4. randr-keys under the host's headless labwc with a stand-in wlr-randr: the fixture's keys pass, a missing key
#      fails and is named;
#   5. check-root on made-up roots (a static busybox and stand-ins): labwc 0.20.3 and foot 1.28 pass, labwc 0.7.1, foot
#      1.16 or a missing wish8.6 are refused; 57-hud-surface.sh fails on a HUD_ROOT it cannot use (root only: chroot);
#   6. installed-test.sh: the extra initramfs archive (newc, root's files, no /lib entry), its pre-pivot hook putting
#      the install service in a stand-in live root only with ribbon.ci.install=1, the services' commands where the
#      hook puts them, the RESULT lines from serial logs, the installer options the guest uses (all known to
#      ribbon-install) and its secrets as secrets.tcl reads them;
#   7. shellcheck (warnings) on the new scripts.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
LP=
trap 'kill $LP 2>/dev/null; rm -rf "$T"' EXIT
L=build/ci/labwc020.sh; I=build/ci/installed-test.sh; Y=build/ci/labwc020-tests.yml

# ---- 1. the workflow
if python3 - "$Y" > "$T/yml" 2>&1 <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get("on", d.get(True))
assert on["push"]["branches"] == ["ribbon-image"], "not run on the ribbon-image push"
j = d["jobs"]
run = lambda n: "\n".join(s.get("run", "") for s in j[n]["steps"])
assert "labwc020.sh root out/root" in run("labwc020") and "labwc020.sh run out/root out/results" in run("labwc020"), "labwc020 job"
assert "installed-test.sh fetch-iso iso" in run("installed") and "installed-test.sh iso/*.iso out/installed" in run("installed"), "installed job"
assert set(j["publish"]["needs"]) == {"labwc020", "installed"} and j["publish"].get("if") == "always()", "publish job"
p = run("publish")
assert "ribbon-results-labwc020:ribbon-results-labwc020" in p and " ribbon-results:" not in p, "results branch"
assert d["permissions"].get("actions") == "read", "actions: read (the ISO of the other workflow)"
PY
then ok "the workflow: root, checks, installed image, results on ribbon-results-labwc020"; else sed 's/^/       /' "$T/yml"; fail "the workflow"; fi

# ---- 2. the checks it runs
want='alttab-native|ALTTAB_ROOT="$ROOT" sh tests/steps.d/80-alttab-native.sh
alttab-profile|PROFILE=5 sh tests/alttab-native/run.sh "$ROOT"
settings-input-live|TERM_ROOT="$ROOT" sh tests/steps.d/65-settings-input-live.sh
term|TERM_ROOT="$ROOT" sh tests/steps.d/65-term.sh
hud-surface|HUD_ROOT="$ROOT" sh tests/steps.d/57-hud-surface.sh
randr-keys|sh build/ci/labwc020.sh randr-keys "$ROOT"'
got=$(sed -n "/^CHECKS='/,/'\$/p" "$L" | sed "1s/^CHECKS='//; \$s/'\$//")
[ "$got" = "$want" ] && ok "labwc020.sh runs the five test halves and the wlr-randr key check against the root" || fail "labwc020.sh's checks: $got"
for f in tests/steps.d/80-alttab-native.sh tests/alttab-native/run.sh tests/steps.d/65-settings-input-live.sh tests/steps.d/65-term.sh tests/term/run.sh tests/steps.d/57-hud-surface.sh tests/hud-native/run.sh; do
	[ -f "$f" ] || fail "$f, which labwc020.sh runs, is missing"
done

# the root's packages hold what the checks run in it: ffmpeg (as ribbon-desktop's ffmpeg6) for the HUD's art
pk=$(sed -n '/^ROOT_PKGS="/,/"$/p' "$L" | tr -d '"' | sed 's/^ROOT_PKGS=//')
grep -q 'ffmpeg6' srcpkgs/ribbon-desktop/template && echo " $pk " | tr '\n' ' ' | grep -q ' ffmpeg6 ' && ok "the root has ffmpeg6, as ribbon-desktop depends on it (the HUD's game art)" || fail "the root's packages lack ffmpeg6: $pk"

# ---- 3. verdicts
v() { printf '%b' "$3" > "$T/v.log"; sh "$L" verdict "$1" "$2" "$T/v.log"; }
case $(v term 0 '  ok   a\n  ok   b\n  note key: mean 5.0 ms\n') in "RESULT term: ok (2 ok)") ok "verdict: ok lines and notes pass";; *) fail "verdict ok: $(v term 0 '  ok   a\n')";; esac
case $(v term 0 '  ok   a\n  FAIL b\n') in "RESULT term: FAILED"*) ok "verdict: a FAIL line fails";; *) fail "verdict FAIL";; esac
case $(v term 1 '  ok   a\n') in "RESULT term: FAILED (exit 1"*) ok "verdict: an exit status fails";; *) fail "verdict exit";; esac
case $(v alttab-native 0 '  skip alttab native: labwc 0.7 here\n') in *"FAILED (skipped under the root: alttab native: labwc 0.7 here)") ok "verdict: a skip under the root fails";; *) fail "verdict skip: $(v alttab-native 0 '  skip x\n')";; esac
case $(v alttab-native 0 '  ok   a\n  note this labwc has no ext-image-copy-capture: cards stay icons (the fallback)\n') in *"FAILED (the labwc 0.7 fallback ran"*) ok "verdict: the no-capture fallback under the root fails";; *) fail "verdict capture fallback";; esac
case $(v term 0 '  ok   a\n  note labwc 0.7 has no ForEach / If: ...\n') in *"FAILED (the labwc 0.7 fallback ran"*) ok "verdict: the no-ForEach fallback under the root fails";; *) fail "verdict ForEach fallback";; esac
case $(v term 0 '  ok   a\n  note foot 1.16 has no [desktop-notifications] command\n') in *"FAILED (the labwc 0.7 fallback ran"*) ok "verdict: the old-foot fallback under the root fails";; *) fail "verdict foot fallback";; esac
case $(v hud-surface 0 '  note nothing\n') in *"FAILED (no check ran)") ok "verdict: a check that ran nothing fails";; *) fail "verdict empty";; esac
# parts a script leaves out with only a note (no ribbon-shell-watch, no Xvfb) fail under the root too
case $(v hud-surface 0 '  ok   a\n  note S12-S15 skipped (no ribbon-shell-watch)\n') in *"FAILED (a part was left out under the root: S12-S15 skipped"*) ok "verdict: a part skipped with a note fails";; *) fail "verdict note-skip: $(v hud-surface 0 '  ok   a\n  note S12-S15 skipped (no ribbon-shell-watch)\n')";; esac
case $(v hud-surface 0 '  ok   a\n  note ribbon-shell-watch does not build here: no game detection checks\n') in *"FAILED (a part was left out"*) ok "verdict: a helper that does not build fails";; *) fail "verdict no-build note";; esac
case $(v settings-input-live 0 '  ok   a\n  note no Xvfb: labwc runs headless, with no keyboard; the keymap checks are skipped\n') in *"FAILED (a part was left out"*) ok "verdict: the headless fallback of the input checks fails";; *) fail "verdict no-Xvfb note";; esac
case $(v term 0 '  ok   a\n  note Esc did not reach the sheet under labwc 0.20; it is cancelled by hand\n') in *"FAILED (a part was left out"*) ok "verdict: a key that did not reach the sheet (cancelled by hand) fails";; *) fail "verdict Esc note";; esac
case $(v hud-surface 0 '  ok   a\n  note S10 is not run against a root (it needs the repo tree and xvfb on the host)\n') in "RESULT hud-surface: ok (1 ok)") ok "verdict: S10's host-only note is not a skip";; *) fail "verdict S10 note";; esac
# the timing run has no ok lines: it passes only with cold and warm measurements
case $(v alttab-profile 0 '  cold: \n  warm: \n') in *"FAILED (no timing measured"*) ok "verdict: a timing run that measured nothing fails";; *) fail "verdict empty profile: $(v alttab-profile 0 '  cold: \n')";; esac
case $(v alttab-profile 0 '') in *"FAILED"*) ok "verdict: an empty timing log fails";; *) fail "verdict empty profile log";; esac
case $(v alttab-profile 0 '  cold: key=0 shown=152 \n  warm: key=0 shown=61 \n') in "RESULT alttab-profile: ok"*) ok "verdict: cold and warm timings pass";; *) fail "verdict profile: $(v alttab-profile 0 '  cold: key=0 shown=152 \n  warm: key=0 shown=61 \n')";; esac

# ---- 4. randr-keys with the host's labwc and a stand-in wlr-randr
if command -v labwc >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
	mkdir -p "$T/stub" "$T/tmp"
	printf '#!/bin/sh\ncase "$1" in --version) echo "stand-in 0.4";; --json) cat "%s";; esac\n' "$T/out.json" > "$T/stub/wlr-randr"; chmod +x "$T/stub/wlr-randr"
	cp tests/fixtures/display-outputs.json "$T/out.json"
	if TMPDIR=$T/tmp PATH=$T/stub:$PATH timeout 60 sh "$L" randr-keys > "$T/rk" 2>&1 && grep -q '^  ok   randr-keys' "$T/rk"; then ok "randr-keys: wlr-randr --json with every fixture key passes (headless labwc)"; else sed 's/^/       /' "$T/rk"; fail "randr-keys on the fixture"; fi
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [o.pop("adaptive_sync") for o in d]; json.dump(d, open(sys.argv[1], "w"))' "$T/out.json"
	if TMPDIR=$T/tmp PATH=$T/stub:$PATH timeout 60 sh "$L" randr-keys > "$T/rk" 2>&1; then fail "randr-keys passed without adaptive_sync"
	elif grep -q 'FAIL randr-keys: .*does not have: \[\]\.adaptive_sync$' "$T/rk"; then ok "randr-keys: a key Settings → Display reads that wlr-randr lacks fails, and is named"
	else sed 's/^/       /' "$T/rk"; fail "randr-keys failed otherwise"; fi
	# the headless labwc it started is gone once it returns (it was started through a function: a kill of that
	# subshell alone leaves labwc running)
	i=0; while pgrep -f "labwc -C $T/tmp/rkeys" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	if pgrep -f "labwc -C $T/tmp/rkeys" >/dev/null 2>&1; then fail "randr-keys left its labwc running: $(pgrep -af "labwc -C $T/tmp/rkeys" | tr '\n' ' ')"; pkill -f "labwc -C $T/tmp/rkeys"
	else ok "randr-keys stops the labwc it started"; fi
else
	echo "  skip randr-keys (no labwc or python3)"
fi

# ---- 5. made-up roots (chroot: root only)
fake_root() { # DIR LABWC-VERSION FOOT-VERSION [TOOL-LEFT-OUT]
	r=$1; mkdir -p "$r/bin" "$r/usr/bin" "$r/tmp"
	cp "$(command -v busybox)" "$r/bin/busybox"
	for t in sh sleep grep sed tail; do ln -sf busybox "$r/bin/$t"; done
	for t in labwc Xwayland foot footclient grim wlr-randr tclsh8.6 wish8.6 xset xkbcomp ffmpeg; do
		[ "$t" = "${4:-}" ] && continue
		printf '#!/bin/sh\n' > "$r/usr/bin/$t"; chmod +x "$r/usr/bin/$t"
	done
	printf '#!/bin/sh\necho "labwc %s (+xwayland +nls +rsvg +libsfdo)"\n' "$2" > "$r/usr/bin/labwc"
	printf '#!/bin/sh\necho "foot version: %s -pgo +ime +graphemes"\n' "$3" > "$r/usr/bin/foot"
	[ "${4:-}" = tclsh8.6 ] || printf '#!/bin/sh\necho 8.6.16\n' > "$r/usr/bin/tclsh8.6"
	[ "${4:-}" = labwc ] && rm -f "$r/usr/bin/labwc"
	chmod +x "$r/usr/bin/"*
}
if [ "$(id -u)" = 0 ] && command -v busybox >/dev/null 2>&1 && busybox --help >/dev/null 2>&1 && ! ldd "$(command -v busybox)" >/dev/null 2>&1; then
	fake_root "$T/r20" 0.20.3 1.28.0
	if PATH=/usr/local/bin:/usr/bin:/bin sh "$L" check-root "$T/r20" > "$T/cr" 2>&1 && grep -q 'labwc 0.20.3, foot 1.28.0' "$T/cr"; then ok "check-root: labwc 0.20.3 and foot 1.28.0 with every tool pass"; else sed 's/^/       /' "$T/cr"; fail "check-root on a good root"; fi
	fake_root "$T/r07" 0.7.1 1.28.0
	if sh "$L" check-root "$T/r07" > "$T/cr" 2>&1; then fail "check-root took labwc 0.7.1"; else grep -q 'labwc 0.7.1 .*0.8 or later' "$T/cr" && ok "check-root refuses labwc 0.7.1" || { sed 's/^/       /' "$T/cr"; fail "check-root's refusal of 0.7.1"; }; fi
	fake_root "$T/rf" 0.20.3 1.16.2
	if sh "$L" check-root "$T/rf" > "$T/cr" 2>&1; then fail "check-root took foot 1.16"; else grep -q 'foot 1.16.2' "$T/cr" && ok "check-root refuses foot 1.16 (no notification mark)" || fail "check-root's refusal of foot 1.16"; fi
	fake_root "$T/rw" 0.20.3 1.28.0 wish8.6
	if sh "$L" check-root "$T/rw" > "$T/cr" 2>&1; then fail "check-root took a root without wish8.6"; else grep -q 'lacks: wish8.6' "$T/cr" && ok "check-root names a missing wish8.6" || fail "check-root's refusal without wish8.6"; fi
	# the HUD's game art is made by ffmpeg in the root (hud-art.tcl; ribbon-desktop depends on ffmpeg6): without it
	# S12's header art fails, so the root must have it
	fake_root "$T/rx" 0.20.3 1.28.0 ffmpeg
	if sh "$L" check-root "$T/rx" > "$T/cr" 2>&1; then fail "check-root took a root without ffmpeg"; else grep -q 'lacks: ffmpeg' "$T/cr" && ok "check-root names a missing ffmpeg (the HUD's game art)" || fail "check-root's refusal without ffmpeg"; fi
	# the run: root check, each check's log, its RESULT line, the notes, and the exit status (stand-in checks)
	mkdir -p "$T/cp/build/ci"
	awk 'BEGIN { q = sprintf("%c", 39) } /^CHECKS=/ { print "CHECKS=" q "good|echo \"  ok   one\"; echo \"  note took 5 ms\""; print "skips|echo \"  ok   two\"; echo \"  skip three\"" q; skip = 1; next }
		skip && /\x27$/ { skip = 0; next } skip { next } { print }' "$L" > "$T/cp/build/ci/labwc020.sh"
	sh "$T/cp/build/ci/labwc020.sh" run "$T/r20" "$T/res" > "$T/run" 2>&1; st=$?
	if [ $st -ne 0 ] && grep -q '^RESULT labwc020-root: ok' "$T/res/labwc020-summary.txt" && grep -qx 'RESULT good: ok (1 ok)' "$T/res/labwc020-summary.txt" &&
		grep -q '^RESULT skips: FAILED (skipped under the root: three)' "$T/res/labwc020-summary.txt" && grep -q 'note took 5 ms' "$T/res/labwc020-notes.txt" && [ -s "$T/res/good.log" ]; then
		ok "run: the root is checked, each check gets a log and a RESULT line, notes are kept, a failed check fails the run"
	else sed 's/^/       /' "$T/run"; fail "run with stand-in checks (exit $st)"; fi
	sh "$T/cp/build/ci/labwc020.sh" run "$T/r07" "$T/res7" > "$T/run" 2>&1 && fail "run went on with a labwc 0.7.1 root" ||
		{ grep -q '^RESULT labwc020-root: FAILED' "$T/res7/labwc020-summary.txt" && [ ! -e "$T/res7/good.log" ] && ok "run stops at a root that check-root refuses" || fail "run on a refused root"; }
	# the HUD step's root switch: an unusable HUD_ROOT fails at once, never runs the host's labwc instead
	out=$(HUD_ROOT=$T/none sh tests/steps.d/57-hud-surface.sh 2>&1); st=$?
	[ $st -ne 0 ] && echo "$out" | grep -q 'FAIL Game HUD surface: HUD_ROOT=.* has no usr/bin/labwc' && ! echo "$out" | grep -q 'hud-native\|  ok' &&
		ok "57-hud-surface: a HUD_ROOT without labwc fails the step" || { echo "$out" | sed 's/^/       /'; fail "57-hud-surface on a HUD_ROOT without labwc"; }
	out=$(HUD_ROOT=$T/r07 sh tests/steps.d/57-hud-surface.sh 2>&1); st=$?
	[ $st -ne 0 ] && echo "$out" | grep -q 'has labwc 0.7.1; a root is for labwc 0.8 or later' &&
		ok "57-hud-surface: a HUD_ROOT with labwc 0.7 fails the step" || { echo "$out" | sed 's/^/       /'; fail "57-hud-surface on a labwc 0.7 HUD_ROOT"; }
else
	echo "  skip check-root and the HUD root switch (needs root's rights and a static busybox)"
fi

# ---- 6. the installed-image test's pieces
if sh "$I" initrd-extra "$T/x" "$T/x.cpio" 2>"$T/xe"; then
	if python3 - "$T/x.cpio" > "$T/xl" 2>&1 <<'PY'
import sys
b = open(sys.argv[1], "rb").read(); i = 0; names = []
while True:
    assert b[i:i + 6] == b"070701", "not newc at %d" % i
    f = [int(b[i + 6 + 8 * k:i + 14 + 8 * k], 16) for k in range(13)]
    mode, uid, gid, size, nlen = f[1], f[2], f[3], f[6], f[11]
    name = b[i + 110:i + 110 + nlen - 1].decode()
    i += 110 + nlen; i += (4 - i % 4) % 4
    if name == "TRAILER!!!":
        break
    assert uid == 0 and gid == 0, name + " is not root's"
    names.append(name); i += size; i += (4 - i % 4) % 4
# the hook where dracut-ng (Void's dracut 112) sources hooks from: /var/lib/dracut/hooks, not /lib/dracut/hooks
want = ["ribbon-ci", "ribbon-ci/install", "ribbon-ci/probe", "ribbon-ci/ribbon-ci-install", "ribbon-ci/ribbon-ci-installed",
        "var/lib/dracut/hooks/pre-pivot/99-ribbon-ci.sh"]
assert names == want, names
PY
	then ok "initrd-extra: a newc archive of root's files: ribbon-ci/ and the pre-pivot hook in dracut-ng's hook directory, no /var or /lib entry"; else sed 's/^/       /' "$T/xl"; fail "initrd-extra's archive"; fi
	hk=$T/x/var/lib/dracut/hooks/pre-pivot/99-ribbon-ci.sh
	mkdir -p "$T/nr/etc/dinit.d"; echo 'root=live:CDLABEL=X ro' > "$T/cmd0"; echo 'root=live:CDLABEL=X ro ribbon.ci.install=1' > "$T/cmd1"
	NEWROOT=$T/nr RIBBON_CI_SRC=$T/x/ribbon-ci RIBBON_CI_CMDLINE=$T/cmd0 RIBBON_CI_KMSG=$T/kmsg sh "$hk"
	[ ! -e "$T/nr/etc/dinit.d/ribbon-ci-install" ] && [ ! -e "$T/nr/usr/lib/ribbon-ci" ] && ok "the hook does nothing without ribbon.ci.install=1" || fail "the hook acted without ribbon.ci.install=1"
	NEWROOT=$T/nr RIBBON_CI_SRC=$T/x/ribbon-ci RIBBON_CI_CMDLINE=$T/cmd1 RIBBON_CI_KMSG=$T/kmsg sh "$hk"
	if [ "$(readlink "$T/nr/etc/dinit.d/boot.d/ribbon-ci-install")" = ../ribbon-ci-install ] && [ -x "$T/nr/usr/lib/ribbon-ci/install" ] && [ -x "$T/nr/usr/lib/ribbon-ci/probe" ] &&
		cmp -s "$T/nr/usr/lib/ribbon-ci/probe" build/ci/installed/probe && [ -f "$T/nr/usr/lib/ribbon-ci/ribbon-ci-installed" ]; then
		ok "with ribbon.ci.install=1 the hook enables the install service in the live root and brings the probe"
	else find "$T/nr" | sed 's/^/       /'; fail "the hook with ribbon.ci.install=1"; fi
	c1=$(sed -n 's/^command = //p' "$T/nr/etc/dinit.d/ribbon-ci-install"); c2=$(sed -n 's/^command = //p' "$T/nr/usr/lib/ribbon-ci/ribbon-ci-installed")
	[ "$c1" = /usr/lib/ribbon-ci/install ] && [ "$c2" = /usr/lib/ribbon-ci/probe ] && grep -q '^type = process' "$T/nr/etc/dinit.d/ribbon-ci-install" &&
		grep -q 'H=/usr/lib/ribbon-ci' build/ci/installed/install && ok "the services run the scripts where the hook and the install put them" || fail "service commands: $c1 / $c2"
else
	sed 's/^/       /' "$T/xe"; fail "initrd-extra"
fi
# RESULT lines from serial logs
mkdir -p "$T/s"
{ echo 'junk RIBBON-CI ok   install: ribbon-install finished in 300 s'; echo 'RIBBON-CI info install| ==> Done'; } > "$T/s/installed-1.log"
for a in boot postinstall swap reserve doctor update; do printf 'RIBBON-CI ok   [%s] x\r\n' "$a"; done > "$T/s/installed-2.log"
{ echo 'RIBBON-CI ok   [boot] dinit is PID 1'; echo 'RIBBON-CI ok   [after-update] marked good'; } > "$T/s/installed-3.log"
sh "$I" summarize "$T/s" > "$T/sum"
[ "$(grep -c ': ok (' "$T/sum")" = 8 ] && grep -qx 'RESULT installed-boot: ok (2 checks)' "$T/sum" && ok "summarize: one ok RESULT line per area" || { sed 's/^/       /' "$T/sum"; fail "summarize, all ok"; }
echo 'RIBBON-CI FAIL [reserve] a user file reaching into the reserve was taken' >> "$T/s/installed-2.log"; rm "$T/s/installed-3.log"
sh "$I" summarize "$T/s" > "$T/sum"
grep -qx 'RESULT installed-reserve: FAILED (\[reserve\] a user file reaching into the reserve was taken)' "$T/sum" && grep -qx 'RESULT installed-after-update: FAILED (no check ran)' "$T/sum" &&
	ok "summarize: a FAIL fails its area, an area with no check fails" || { sed 's/^/       /' "$T/sum"; fail "summarize with a failure"; }
# the probe's update checks against what ribbon-update and ribbon-snapshot really do: the snapshot ribbon-update takes
# first is of the type ribbon-snapshot's pre branch passes to snapper, and it arms the try counter the probe reads
RS=srcpkgs/ribbon-tools/files/bin/ribbon-snapshot; RU=srcpkgs/ribbon-tools/files/bin/ribbon-update
ptype=$(sed -n '/^[[:space:]]*pre)/,/;;/p' "$RS" | sed -n 's/.*snap_create "[^"]*" \([a-z]*\)).*/\1/p' | head -n1)
pdesc=$(sed -n 's/.*ribbon-snapshot pre "\(ribbon update\) .*/\1/p' "$RU" | head -n1)
eval "$(sed -n '/^update_snap() /p' build/ci/installed/probe)"
if [ -n "$ptype" ] && [ -n "$pdesc" ] && command -v update_snap >/dev/null 2>&1 && update_snap "7,$ptype,$pdesc 2026-11-15" && ! update_snap "6,single,Fresh install"; then
	ok "probe: the pre-update snapshot check takes ribbon-snapshot pre's snapper type ($ptype) and ribbon-update's description"
else fail "probe: the pre-update snapshot check (snapper type '$ptype', description '$pdesc')"; fi
grep -q 'arm "' "$RS" && sed -n '/^[[:space:]]*pre)/,/;;/p' "$RS" | grep -q 'arm ' && grep -q 's/^state=//p. /boot/ribbon/trying' build/ci/installed/probe &&
	grep -q '^TRYING=\$BOOTDIR/ribbon/trying' "$RS" && ok "probe: the update checks that the boot fallback was armed, so the cleared counter after it means something" ||
	fail "probe: no check that ribbon-update armed the try counter"
# the guest relays the end of the installer's log on the serial console: rsync's progress meter (carriage returns, one
# 4.9 MB "line" on 24 Nov) must not reach it, or printing outlasts the install's time limit
python3 -c 'import sys; sys.stdout.write("==> Copying the live system (rsync)\n" + "".join("  %d,000B  1%%  (xfr#%d, to-chk=%d/9)\r" % (i, i, i) for i in range(60000)) + "\nRIBBON DONE\n")' > "$T/ilog"
sed -n "/^tr '\\\\r'/,/done\$/p" build/ci/installed/install | sed "s|/tmp/ribbon-install.log|$T/ilog|" > "$T/relay.sh"
( say() { printf '%s\n' "$*"; }; . "$T/relay.sh" ) > "$T/relayed" 2>&1
if [ -s "$T/relay.sh" ] && [ "$(wc -c < "$T/relayed")" -lt 2000 ] && grep -q 'info install| RIBBON DONE' "$T/relayed" &&
	grep -q 'info install| ==> Copying the live system' "$T/relayed"; then
	ok "install: the log's end is relayed without rsync's progress meter ($(wc -c < "$T/relayed") bytes for a 3 MB meter)"
else fail "install: the relayed log is $(wc -c < "$T/relayed") bytes ($(head -c 200 "$T/relayed"))"; fi
# the guest's installer call: every option is one ribbon-install takes, and the secrets reach it as secrets.tcl reads them
RI=srcpkgs/ribbon-installer/files/bin/ribbon-install
opts=$(sed -n '/ribbon-install --disk/,/--secrets-stdin/p' build/ci/installed/install | grep -oE -- '--[a-z-]+' | sort -u)
bad=; for o in $opts; do grep -qE "^[[:space:]]+$o\)" "$RI" || bad="$bad $o"; done
[ -n "$opts" ] && [ -z "$bad" ] && ok "the guest's ribbon-install options are all ribbon-install's ($(echo $opts | wc -w))" || fail "options ribbon-install does not take:$bad"
if command -v tclsh8.6 >/dev/null 2>&1; then
	line=$(grep -E "^printf 'password %s" build/ci/installed/install | sed 's/ |$//')
	got=$(eval "$line" | tclsh8.6 srcpkgs/ribbon-installer/files/backend/secrets.tcl | tr '\0' '|')
	[ "$got" = 'ribbon-ci-pass||' ] && ok "the guest's secrets are read by secrets.tcl as the password" || fail "secrets.tcl read: $got"
else
	echo "  skip the secrets check (no tclsh8.6)"
fi

# ---- 6b. the ISO's path: taken as an absolute one (QEMU starts in another directory: the first CI run, given a
# relative path, found no ISO and every area said "no check ran"), and a missing ISO is said as that
if sh "$I" "$T/no-such.iso" "$T/it" > "$T/it.out" 2>&1 || ! grep -q "FAILED (no ISO at $T/no-such.iso)" "$T/it/installed-summary.txt" 2>/dev/null; then
	fail "installed-test.sh with no ISO: $(cat "$T/it.out")"
elif grep -q '^ISO=$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")$' "$I"; then ok "installed-test.sh takes the ISO by its absolute path, and says when there is none"
else fail "installed-test.sh does not make the ISO's path absolute"; fi

# ---- 7. shellcheck
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -S warning -s sh "$L" "$I" build/ci/installed/install tests/steps.d/57-hud-surface.sh "$0" > "$T/sc" 2>&1 &&
		shellcheck -S warning -s bash build/ci/installed/probe >> "$T/sc" 2>&1; then ok "shellcheck: no warnings in the new scripts"; else sed 's/^/       /' "$T/sc" | head -n 30; fail "shellcheck"; fi
else
	echo "  skip shellcheck (not installed)"
fi

[ $fails -eq 0 ] && echo "CI labwc 0.20 and installed image: all checks passed" || { echo "CI labwc 0.20 and installed image: $fails failed"; exit 1; }
