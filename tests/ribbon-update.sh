#!/bin/bash
# ribbon-update (srcpkgs/ribbon-tools/files/bin/ribbon-update) and the seam's update part (lib/pkg-update.sh), on
# stand-ins: xbps-install, xbps-query, ribbon-snapshot, ribbon-sv2dinit, ribbon-limine, flatpak, kit, runuser and id
# on PATH log what they are asked; the "installed" packages are a fixture file the stand-in xbps-install rewrites, and
# a kernel's install adds its /usr/lib/modules directory (RIBBON_MODULES). Checked:
#   1. the seam: pkg_updates reads xbps-install -Mun (no root, nothing changed) into NAME|OLD|NEW|BYTES|ACTION|TAGS,
#      with the installed version, the build revision dropped, restart on the kernel and firmware, a new package as
#      install; xbps first when it must update itself; nothing to update; a failure; kit and none answer 2;
#   2. ribbon update in a terminal: snapshot, sync, xbps, the rest, dinit services, boot menu, flatpak, then
#      kit check as the person who ran sudo (runuser), with -y as --yes; the kernel's update writes
#      RIBBON_RUN/reboot-required and the reboot line follows; no reboot line without one; run as root itself, kit
#      is not run for root;
#   3. --tcl (the desktop): the plan line kit's way (rows, question with the restart tail, checked) without root and
#      without changing anything; "Up to date"; --tcl --yes: the done line (switched rows, restart list, lines),
#      no kit and no flatpak; a failed update fails with no done line;
#   4. no xbps command or Void path in ribbon-update itself (the seam has them).
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
LIB=$REPO/srcpkgs/ribbon-tools/files/lib
RU=$REPO/srcpkgs/ribbon-tools/files/bin/ribbon-update
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
S=$T/stubs LOG=$T/log
mkdir -p "$S" "$T/modules/6.18.58_1" "$T/sv"
export STUB_LOG=$LOG STUB_DIR=$T

# ---- stand-ins -----------------------------------------------------------------
# installed: NAME VERSION per line. plan: xbps-install -n's lines. A -u (not -n) installs the plan's packages.
cat > "$S/xbps-install" <<'EOF'
#!/bin/sh
echo "xbps-install $* [RIBBON_NO_SNAPSHOT=${RIBBON_NO_SNAPSHOT:-}]" >> "$STUB_LOG"
case " $* " in
	*" -Mun xbps "*) cat "$STUB_DIR/plan-xbps"; exit 0 ;;
	*" -Mun "*)
		[ -e "$STUB_DIR/fail-check" ] && { echo "ERROR: [reposync] failed to fetch file \`https://repo/x86_64-repodata': Not Found" >&2; exit 1; }
		[ -e "$STUB_DIR/plan-xbps" ] && { echo "The 'xbps' package must be updated, please run \`xbps-install -u xbps\`" >&2; exit 16; }
		cat "$STUB_DIR/plan"; exit 0 ;;
	*" -S "*) exit 0 ;;
	*" -u -y xbps "*|*" -u xbps "*) exit 0 ;;
	*" -u "*)
		[ -e "$STUB_DIR/fail-update" ] && exit 1
		while read -r pv act rest; do
			n=${pv%-*}; v=${pv##*-}
			grep -v "^$n " "$STUB_DIR/installed" > "$STUB_DIR/i.new"; echo "$n $v" >> "$STUB_DIR/i.new"; mv "$STUB_DIR/i.new" "$STUB_DIR/installed"
			case "$n" in linux[0-9]*) mkdir -p "$STUB_DIR/modules/$v" ;; esac
		done < "$STUB_DIR/plan"
		exit 0 ;;
esac
exit 0
EOF
cat > "$S/xbps-query" <<'EOF'
#!/bin/sh
[ "$1" = -l ] || exit 2
while read -r n v; do [ -n "$n" ] && echo "ii $n-$v a package"; done < "$STUB_DIR/installed"
EOF
cat > "$S/ribbon-snapshot" <<'EOF'
#!/bin/sh
echo "ribbon-snapshot $*" >> "$STUB_LOG"
[ "$1" = backend ] && echo btrfs
exit 0
EOF
for c in ribbon-sv2dinit ribbon-limine flatpak; do printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\n' "$c" > "$S/$c"; done
printf '#!/bin/sh\necho "kit $* [HOME=$HOME]" >> "$STUB_LOG"\n' > "$S/kit"
printf '#!/bin/sh\necho "runuser $1 $2" >> "$STUB_LOG"\nshift 3\nexec "$@"\n' > "$S/runuser"
cat > "$S/id" <<'EOF'
#!/bin/sh
case "$*" in -u) echo "${STUB_UID:-0}" ;; -un) [ "${STUB_UID:-0}" = 0 ] && echo root || echo person ;; *) exec /usr/bin/id "$@" ;; esac
EOF
printf '#!/bin/sh\n[ "$1" = passwd ] && [ "$2" = person ] && echo "person:x:1000:1000::/home/person:/bin/sh"\n' > "$S/getent"
chmod +x "$S"/*
XPATH=$S:$PATH
NOX=$T/nox; mkdir -p "$NOX"
# a PATH without xbps (another base): the host's directories that have no xbps-install and no kit
NPATH=$S/../nox:$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/xbps-install" ] || [ -x "$d/kit" ] || printf '%s:' "$d"; done)
for c in id getent ribbon-snapshot ribbon-sv2dinit ribbon-limine; do cp "$S/$c" "$NOX/"; done

reset() {
	printf 'linux6.18 6.18.58_1\nmesa 25.2.7_1\nfirefox-esr 128.0_1\nlinux-firmware-amd 20251101_1\n' > "$T/installed"
	cat > "$T/plan" <<'EOF'
mesa-25.2.8_1 update x86_64 https://repo-default.voidlinux.org/current 41000000 16000000
linux6.18-6.18.60_1 update x86_64 https://repo-default.voidlinux.org/current 120000000 14000000
linux-firmware-amd-20251110_1 update noarch https://repo-default.voidlinux.org/current 300000000 0
libfoo-1.2_1 install x86_64 https://repo-default.voidlinux.org/current 10000 5000
EOF
	rm -rf "$T/run" "$T/modules" "$T/plan-xbps" "$T/fail-check" "$T/fail-update"; mkdir -p "$T/modules/6.18.58_1"
	: > "$LOG"
}
seam() { PATH=$1 RIBBON_PKG_BACKEND='' bash -c ". '$LIB/common.sh'; . '$LIB/pkg-update.sh'; ${*:2}"; }
ru() { env PATH="$XPATH" RIBBON_SV_DIR="${SVDIR-$T/sv}" HOME="$T/home" XDG_CACHE_HOME="$T/cache" RIBBON_LIB="$LIB" RIBBON_RUN="$T/run" RIBBON_MODULES="$T/modules" RIBBON_ROOT= SUDO_USER="${SUDO_USER:-}" \
	STUB_UID="${STUB_UID:-0}" bash "$RU" "$@"; }
logged() { grep -qxF -- "$1" "$LOG"; }
nolog() { ! grep -q -- "$1" "$LOG"; }

# ---- 1. the seam's update part --------------------------------------------------
echo "the seam: pkg_updates"
reset
out=$(seam "$XPATH" pkg_updates); rc=$?
want=$(printf 'mesa|25.2.7|25.2.8|16000000|update|\nlinux6.18|6.18.58|6.18.60|14000000|update|restart\nlinux-firmware-amd|20251101|20251110||update|restart\nlibfoo||1.2|5000|install|')
check "the plan from xbps-install -Mun: versions, the download, restart on the kernel and firmware, a new package" test "$rc:$out" = "0:$want"
check "the plan is read without changing anything (a dry run, the index in memory)" sh -c "[ \"\$(grep -c . '$LOG')\" = 1 ] && grep -qxF 'xbps-install -Mun [RIBBON_NO_SNAPSHOT=]' '$LOG'"
printf 'mesa-25.2.7_2 update x86_64 https://repo 1 2\n' > "$T/plan"
check "only the build revision changed: it is shown" test "$(seam "$XPATH" pkg_updates)" = 'mesa|25.2.7_1|25.2.7_2|2|update|'
reset; : > "$T/plan"
out=$(seam "$XPATH" pkg_updates); rc=$?
check "nothing to update: exit 0, no lines" test "$rc:$out" = "0:"
printf 'xbps-0.60_1 update x86_64 https://repo 1 300\n' > "$T/plan-xbps"; echo "xbps 0.59_1" >> "$T/installed"
check "xbps must update itself first: the plan is xbps alone" test "$(seam "$XPATH" pkg_updates)" = 'xbps|0.59|0.60|300|update|'
reset; : > "$T/fail-check"
out=$(seam "$XPATH" pkg_updates 2>&1); rc=$?
check "a failed check: exit 1 and xbps's reason" sh -c "[ $rc = 1 ] && printf '%s' \"\$1\" | grep -q 'failed to fetch file'" - "$out"
seam "$NPATH" pkg_updates >/dev/null 2>&1; rc=$?
check "a base without a package manager: pkg_updates answers 2" test $rc = 2
check "the kit backend: pkg_updates answers 2 (kit check is the system's update)" sh -c "PATH='$XPATH' RIBBON_PKG_BACKEND=kit bash -c \". '$LIB/common.sh'; . '$LIB/pkg-update.sh'; pkg_updates\"; [ \$? = 2 ]"

# ---- 2. ribbon update in a terminal --------------------------------------------------
echo "ribbon update"
reset
out=$(SUDO_USER=person ru -y 2>&1); rc=$?
order=$(sed 's/ \[RIBBON_NO_SNAPSHOT=1\]//; s/ \[RIBBON_NO_SNAPSHOT=\]//' "$LOG" | grep -v '^ribbon-snapshot backend' | tr '\n' '|')
want="ribbon-snapshot pre ribbon update $(date +%F)|xbps-install -S|xbps-install -u -y xbps|xbps-install -Mun|xbps-install -u -y|ribbon-sv2dinit --quiet|ribbon-snapshot prune|flatpak update -y --noninteractive|runuser -u person|kit check --yes [HOME=/home/person]|"
check "snapshot, sync, xbps, the rest, dinit services, flatpak, then kit check --yes as the person (exit $rc)" test "$rc:$order" = "0:$want"
check "the package manager is run as itself: no wrapper in front of it to skip (no RIBBON_NO_SNAPSHOT)" logged "xbps-install -u -y [RIBBON_NO_SNAPSHOT=]"
reset
SVDIR=$T/nosv SUDO_USER=person ru -y >/dev/null 2>&1
check "a base without runit services (no /etc/sv): no ribbon-sv2dinit after the update" sh -c "grep -q 'xbps-install -u -y' '$LOG' && ! grep -q '^ribbon-sv2dinit' '$LOG'"
check "ribbon-update runs no runit conversion itself (the seam's pkg_upgrade does, where there are runit services)" sh -c "! grep -v '^[[:space:]]*#' '$RU' | grep -q sv2dinit"
check "the kernel's update writes RIBBON_RUN/reboot-required" test -e "$T/run/reboot-required"
check "it says what takes effect at restart, and that a reboot is recommended" sh -c "printf '%s\n' \"\$1\" | grep -qxF 'Restart to finish: linux6.18 6.18.60, linux-firmware-amd 20251110.' && printf '%s\n' \"\$1\" | grep -qxF 'A reboot is recommended (new kernel).'" - "$out"
reset; sed -i '/^linux/d' "$T/plan"
out=$(SUDO_USER=person ru -y 2>&1); rc=$?
check "an update without a restart: no flag, no reboot line" sh -c "[ $rc = 0 ] && [ ! -e '$T/run/reboot-required' ] && ! printf '%s' \"\$1\" | grep -q -e 'reboot is recommended' -e 'Restart to finish'" - "$out"
reset; mkdir -p "$T/run"; : > "$T/run/reboot-required"; sed -i '/^linux/d' "$T/plan"
out=$(SUDO_USER=person ru -y 2>&1)
check "a flag another tool wrote (pending's GPU driver) still gives the reboot line" sh -c "printf '%s\n' \"\$1\" | grep -qxF 'A reboot is recommended.'" - "$out"
reset
out=$(ru 2>&1); rc=$?
check "without -y: xbps asks (no -y), kit check asks (no --yes)" sh -c "grep -qxF 'xbps-install -u [RIBBON_NO_SNAPSHOT=]' '$LOG' && grep -qxF 'xbps-install -u xbps [RIBBON_NO_SNAPSHOT=]' '$LOG'"
check "run as root itself: kit is not run for root, and it says so" sh -c "! grep -q '^kit ' '$LOG' && printf '%s' \"\$1\" | grep -q 'Not checking app kits'" - "$out"
reset
out=$(SUDO_USER=person ru --no-snapshot -y 2>&1)
check "--no-snapshot: no snapshot" nolog "ribbon-snapshot pre"
reset; : > "$T/fail-update"
out=$(SUDO_USER=person ru -y 2>&1); rc=$?
check "a failed update: its exit code and the way back" sh -c "[ $rc = 1 ] && printf '%s' \"\$1\" | grep -q 'sudo ribbon rollback'" - "$out"
reset
out=$(STUB_UID=1000 ru -y 2>&1); rc=$?
check "not root: refused, nothing run" sh -c "[ $rc = 1 ] && [ ! -s '$LOG' ]"
out=$(ru --frobnicate 2>&1); rc=$?
check "an unknown option is refused" sh -c "[ $rc = 1 ] && printf '%s' \"\$1\" | grep -q 'unknown option --frobnicate'" - "$out"
reset
out=$(env PATH="$NPATH" RIBBON_LIB="$LIB" RIBBON_RUN="$T/run" RIBBON_MODULES="$T/modules" bash "$RU" -y 2>&1); rc=$?
check "a base without a package manager: says so, no snapshot, exit 0" sh -c "[ $rc = 0 ] && printf '%s' \"\$1\" | grep -q 'no package manager Ribbon can use' && ! grep -q 'ribbon-snapshot pre' '$LOG'" - "$out"

# the kit backend: the system's packages are system kits, updated through kitd (kit check --yes); its exit status is ribbon update's
reset
KB2=$T/kitbin2; mkdir -p "$KB2"; printf '#!/bin/sh\necho "kit $*" >> "%s"\nexit "${KIT_RC:-0}"\n' "$LOG" > "$KB2/kit"; chmod +x "$KB2/kit"
out=$(env PATH="$KB2:$NPATH" RIBBON_PKG_BACKEND=kit RIBBON_LIB="$LIB" RIBBON_RUN="$T/run" RIBBON_MODULES="$T/modules" bash "$RU" -y 2>&1); rc=$?
check "the kit backend: kit check --yes runs, no snapshot of ribbon-update's own (kitd takes it), exit 0" sh -c "[ $rc = 0 ] && grep -qxF 'kit check --yes' '$LOG' && ! grep -q 'ribbon-snapshot pre' '$LOG'" - "$out"
reset
out=$(env PATH="$KB2:$NPATH" RIBBON_PKG_BACKEND=kit KIT_RC=3 RIBBON_LIB="$LIB" RIBBON_RUN="$T/run" RIBBON_MODULES="$T/modules" bash "$RU" -y 2>&1); rc=$?
check "the kit backend: a failed system check is ribbon update's failure (exit 3, 'undo' advice), not a silent success" sh -c "[ $rc = 3 ] && printf '%s' \"\$1\" | grep -q 'update exited with 3'" - "$out"

# ---- 3. --tcl, for the desktop --------------------------------------------------
echo "ribbon update --tcl"
tclcheck() { # SCRIPT with $out as `out`
	printf '%s' "$out" > "$T/out.txt"
	tclsh8.6 <<EOF
set out [read [open $T/out.txt]]
foreach l [split \$out \n] { if {[llength \$l] == 2 && [lindex \$l 0] in {plan done}} { set [lindex \$l 0] [lindex \$l 1] } }
if {[catch {$1} r] || !\$r} { puts stderr "tcl check: \$r"; exit 1 }
EOF
}
if command -v tclsh8.6 >/dev/null 2>&1; then
	reset
	out=$(STUB_UID=1000 ru --tcl 2>&1); rc=$?
	check "the plan, as a user: exit 0, one dry run" sh -c "[ $rc = 0 ] && [ \"\$(grep -c . '$LOG')\" = 1 ]"
	tclcheck 'expr {[llength [dict get $plan rows]] == 4 && [dict get $plan question] eq "Install 1 and update 3? (takes effect at restart)"
		&& [dict get [lindex [dict get $plan rows] 1] name] eq "linux6.18" && [dict get [lindex [dict get $plan rows] 1] tags] eq "restart"
		&& [dict get [lindex [dict get $plan rows] 1] old] eq "6.18.58" && [dict get [lindex [dict get $plan rows] 1] new] eq "6.18.60"
		&& [dict get [lindex [dict get $plan rows] 0] bytes] == 16000000 && [dict get [lindex [dict get $plan rows] 2] bytes] eq ""
		&& [dict get [lindex [dict get $plan rows] 3] action] eq "install" && abs([dict get $plan checked] - [clock seconds]) < 60}' &&
		ok "the plan's rows, question and time read as kit's" || fail "the plan line: $out"
	C=$T/cache/ribbon/system-updates
	tclcheck "set f [open $C]; set c [read \$f]; close \$f; set u [dict get \$c updates]
		expr {[llength \$u] == 4 && [dict get [lindex \$u 1] name] eq {linux6.18} && [dict get [lindex \$u 1] version] eq {6.18.58} && [dict get [lindex \$u 1] new] eq {6.18.60}
			&& [dict get [lindex \$u 1] flags] eq {restart} && [dict get [lindex \$u 0] download] == 16000000 && abs([dict get \$c checked] - [clock seconds]) < 60}" &&
		ok "the plan leaves what is waiting in ~/.cache/ribbon/system-updates, as kit's cache file" || fail "the cache file: $(cat "$C" 2>&1)"
	check "the plan changes nothing: no snapshot, no install" sh -c "! grep -q -e 'ribbon-snapshot' -e 'xbps-install -u' -e 'xbps-install -S ' '$LOG'"
	sed -i '/^linux/d' "$T/plan"
	out=$(STUB_UID=1000 ru --tcl 2>&1)
	tclcheck 'expr {[dict get $plan question] eq "Install 1 and update 1?"}' && ok "no restart: the question has no tail" || fail "question: $out"
	: > "$T/plan"
	out=$(STUB_UID=1000 ru --tcl 2>&1); rc=$?
	check "nothing waiting: Up to date, exit 0" test "$rc:$out" = "0:Up to date"
	check "and the cache file says nothing is waiting" grep -q '^checked [0-9]* updates {}$' "$T/cache/ribbon/system-updates"
	reset; : > "$T/fail-check"
	out=$(STUB_UID=1000 ru --tcl 2>&1); rc=$?
	check "a failed check: exit 1, the reason last" sh -c "[ $rc = 1 ] && printf '%s' \"\$1\" | tail -n1 | grep -q 'failed to fetch'" - "$out"
	reset
	out=$(SUDO_USER=person ru --tcl --yes 2>&1); rc=$?
	tclcheck 'expr {[llength [dict get $done rows]] == 4 && [dict get [lindex [dict get $done rows] 1] new] eq "switched"
		&& [dict get [lindex [dict get $done rows] 1] old] eq "6.18.60" && [dict get [lindex [dict get $done rows] 3] new] eq "installed"
		&& [dict get $done restart] eq {{linux6.18 6.18.60} {linux-firmware-amd 20251110}}
		&& [dict get $done lines] eq {{Restart to finish: linux6.18 6.18.60, linux-firmware-amd 20251110.}}
		&& [dict get $done stale] eq {} && [string is integer -strict [dict get $done time]]}' &&
		ok "--tcl --yes: the done line (switched and installed rows, the restart list, the summary)" || fail "the done line ($rc): $out"
	check "--tcl --yes: the snapshot and the update, no kit and no flatpak (the desktop runs kit)" sh -c "grep -q 'ribbon-snapshot pre' '$LOG' && grep -qxF 'xbps-install -u -y [RIBBON_NO_SNAPSHOT=]' '$LOG' && ! grep -q -e '^kit ' -e '^flatpak' '$LOG' && [ -e '$T/run/reboot-required' ]"
	reset; : > "$T/fail-update"
	out=$(SUDO_USER=person ru --tcl --yes 2>&1); rc=$?
	check "--tcl --yes, a failed update: no done line, exit 1" sh -c "[ $rc = 1 ] && ! printf '%s' \"\$1\" | grep -q '^done '" - "$out"
else
	echo "  skip --tcl (no tclsh8.6)"
fi

# ---- 4. no xbps in ribbon-update ---------------------------------------------
hits=$(grep -nE 'xbps|/var/db/|voidlinux' "$RU" | grep -v '^[0-9]*:[[:space:]]*#' || :)
check "no xbps command or Void path in ribbon-update (the seam has them)${hits:+: $hits}" test -z "$hits"
check "pending's flag is the one ribbon-update reads" sh -c "grep -q ': > /run/ribbon/reboot-required' '$REPO/srcpkgs/ribbon-tools/files/bin/pending' && grep -q 'RUN=\${RIBBON_RUN:-/run/ribbon}' '$RU' && grep -q '\"\$RUN/reboot-required\"' '$RU'"

# ---- 5. the desktop's pkexec: its polkit action names ribbon-update and asks an admin ----------------------
P=$REPO/srcpkgs/ribbon-desktop/files/apps/settings/policy/org.ribbon.update.policy
if command -v xmllint >/dev/null 2>&1; then
	check "org.ribbon.update.policy is well-formed, names /usr/bin/ribbon-update, asks an admin" sh -c "xmllint --noout --nonet '$P' &&
		grep -q 'exec.path\">/usr/bin/ribbon-update<' '$P' && grep -q '<allow_active>auth_admin_keep</allow_active>' '$P' && grep -q '<allow_any>auth_admin</allow_any>' '$P'"
else
	echo "  skip the policy's XML (no xmllint)"
fi
check "ribbon-update is installed as /usr/bin/ribbon-update (the policy's path)" grep -q '^bin @files/bin/ribbon-update$' "$REPO/build/install/manifests/ribbon-tools.manifest"

[ "$fails" -eq 0 ] || { echo "ribbon-update: $fails failure(s)"; exit 1; }
