#!/bin/sh
# A stand-in for ribbon-install-probe and ribbon-install, for the Tk
# installer's tests and screenshots (RIBBON_INSTALLER_FAKE=this file).
#   installer-fake-backend.sh probe                       the fixture probe
#   installer-fake-backend.sh probe --check-answers FILE  ok / error <why>
#   installer-fake-backend.sh probe --windows-ready PART  {safe 1 why {}}
#   installer-fake-backend.sh install --answers FILE --secrets-stdin --progress
# RIBBON_FAKE_CHECK=reason makes --check-answers refuse with it;
# RIBBON_FAKE_PROBE_FAIL=1 makes the probe fail as a dismissed pkexec does;
# RIBBON_FAKE_UNSAFE=1 has --windows-ready say Windows is hibernated;
# RIBBON_FAKE_DELAY (seconds per progress line, default 0.05) paces the replay;
# RIBBON_FAKE_FAIL=1 ends with an ERROR; RIBBON_FAKE_MARKER=file is made once
# the install has printed its last line (it never is if the window went away
# and took the progress pipe with it).
here=$(cd "$(dirname "$0")" && pwd)
what=$1; shift
case "$what" in
probe)
	case "${1:-}" in
	--check-answers)
		f=$2
		[ -r "$f" ] || { echo "error the answers file is missing"; exit 0; }
		grep -q '^version 1' "$f" || { echo "error not a version 1 answers file"; exit 0; }
		# RIBBON_FAKE_CHECK=reason: the check refuses any answers with it
		[ -z "${RIBBON_FAKE_CHECK:-}" ] || { echo "error $RIBBON_FAKE_CHECK"; exit 0; }
		if grep -q '^mode manual' "$f" && ! grep -q 'mount /[ }]' "$f"; then
			echo "error there is no / partition"; exit 0
		fi
		echo ok ;;
	--windows-ready)
		if [ "${RIBBON_FAKE_UNSAFE:-0}" = 1 ]; then echo "min 440000000000 max 959600000000 safe 0 why {Windows is hibernated or was shut down with Fast Startup, so resizing it now could lose your Windows files. Start Windows, turn off Fast Startup (Control Panel, Power Options, Choose what the power buttons do), then shut it down fully: hold Shift while you click Shut down.}"
		else echo "safe 1 why {}"; fi ;;
	*)
		# RIBBON_FAKE_PROBE_FAIL=1: as pkexec says when its password prompt is dismissed
		if [ "${RIBBON_FAKE_PROBE_FAIL:-0}" = 1 ]; then echo "Error executing command as another user: Request dismissed" >&2; exit 126; fi
		cat "$here/fixtures/installer/mockup-machine.tcl" ;;
	esac ;;
install)
	answers='' progress=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--answers) answers=$2; shift ;;
		--progress) progress=1 ;;
		esac
		shift
	done
	[ -r "$answers" ] || { echo "ERROR {no answers file}"; exit 2; }
	# the secrets arrive on stdin; never echo them
	secrets=$(cat)
	case "$secrets" in *password*) : ;; *) echo "ERROR {no secrets on stdin}"; exit 2 ;; esac
	[ "$progress" = 1 ] || exit 0
	d=${RIBBON_FAKE_DELAY:-0.05}
	enc=0; grep -q '^encrypt 1' "$answers" && enc=1
	total=$((5 + enc)); i=0
	step() { i=$((i + 1)); echo "STEP $i $total {$1}"; sleep "$d"; }
	p() { echo "PROGRESS $1 {$2}"; sleep "$d"; }
	l() { echo "LOG $1"; sleep "$d"; }
	step "Preparing the disk"; l "==> Partitioning $(sed -n 's/^disk //p' "$answers")"; p 4 "Partitioning"
	l "==> Creating btrfs with subvolumes"; p 8 "Creating filesystems"
	if [ $enc = 1 ]; then step "Encrypting"; l "==> LUKS2 (argon2id)"; p 12 "Encrypting"; fi
	step "Copying Ribbon"; l "==> Copying the live system (rsync)"
	for n in 20 31 42 51 62 70; do l "    $n% · copying"; p $n "Copying Ribbon"; done
	step "Setting up the system"; l "==> Drivers, services, swap"; p 80 "Setting up"
	step "Boot loader"; l "==> $(sed -n 's/^bootloader //p' "$answers")"; p 90 "Boot loader"
	step "Your account"; l "==> Creating the account"; p 98 "Your account"
	if [ "${RIBBON_FAKE_FAIL:-0}" = 1 ]; then echo "ERROR {the disk went away}"; exit 1; fi
	p 100 "Done"; echo DONE
	[ -z "${RIBBON_FAKE_MARKER:-}" ] || : > "$RIBBON_FAKE_MARKER" ;;
*) echo "usage: $0 probe|install ..." >&2; exit 2 ;;
esac
