#!/bin/sh
# ribbon-welcome (Tcl/Tk, no zenity): drives the window through every
# choice with tests/welcome-flow.tcl and checks the commands it would run
# (RIBBON_WELCOME_DRYRUN) and the welcome-pending/welcome-done markers.
# RIBBON_SHOTS=DIR keeps a screenshot of each step.
set -u
cd "$(dirname "$0")/.." || exit 1
status=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; status=1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.config/ribbon"
: > "$tmp/home/.config/ribbon/welcome-pending"
# mounted, swap and LUKS partitions are not offered; a label with a space is
printf '%s\n' '/dev/sda1 part vfat 512M  /boot/efi' '/dev/sda2 part btrfs 900G  /' \
	'/dev/sdb1 part ntfs 1T Games\x20Disk ' '/dev/sdb2 part ext4 2T  ' \
	'/dev/sdb3 part swap 8G  ' '/dev/sdc1 part crypto_LUKS 1T  ' > "$tmp/lsblk"
if HOME=$tmp/home XDG_CONFIG_HOME=$tmp/home/.config XDG_CACHE_HOME=$tmp/cache \
	RIBBON_SHELL_DIR=srcpkgs/ribbon-desktop/files/shell RIBBON_WELCOME_DRYRUN="$tmp/cmds" \
	RIBBON_WELCOME_LSBLK="$tmp/lsblk" RIBBON_WELCOME_TEST=tests/welcome-flow.tcl \
	${RIBBON_SHOTS:+RIBBON_WELCOME_SHOT=$RIBBON_SHOTS} \
	xvfb-run -a -s "-screen 0 1280x800x24" wish8.6 -encoding utf-8 \
	srcpkgs/ribbon-desktop/files/welcome/main.tcl -name ribbon-welcome > "$tmp/out" 2>&1
then ok "the welcome window runs through every step"
else bad "welcome flow: $(tail -n 3 "$tmp/out")"; fi
expect='ribbon-hdr on
pkexec ribbon-drives add /dev/sdb2
flatpak remote-add --user --if-not-exists flathub /usr/share/ribbon/flatpak/flathub.flatpakrepo
ribbon-theme pick'
[ "$(cat "$tmp/cmds" 2>/dev/null)" = "$expect" ] && ok "it runs HDR, the drive (the one picked), Flathub and Appearance, in order" ||
	bad "commands: $(tr '\n' ';' < "$tmp/cmds" 2>/dev/null)"
[ ! -e "$tmp/home/.config/ribbon/welcome-pending" ] && [ -e "$tmp/home/.config/ribbon/welcome-done" ] &&
	ok "welcome-pending is replaced by welcome-done" || bad "welcome markers"
if grep -rl zenity srcpkgs/ribbon-desktop/files/bin srcpkgs/ribbon-desktop/files/welcome srcpkgs/ribbon-desktop/template \
	srcpkgs/ribbon-gaming/template srcpkgs/ribbon-gaming/files 2>/dev/null | grep -q .; then
	bad "zenity is still used: $(grep -rl zenity srcpkgs/ribbon-desktop/files/bin srcpkgs/ribbon-desktop/files/welcome srcpkgs/ribbon-desktop/template srcpkgs/ribbon-gaming | tr '\n' ' ')"
else ok "no Ribbon script uses zenity"; fi
exit $status
