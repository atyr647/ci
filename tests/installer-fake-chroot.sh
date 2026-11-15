#!/bin/bash
# A stand-in for chroot, for ribbon-install's steps 4-6 in tests/test-installer.sh
# (RIBBON_INSTALL_CHROOT=this file). ribbon-install calls it as
#   installer-fake-chroot.sh TARGET /usr/bin/env -i VAR=... command args
# Each command goes, one line per call, to $FAKE_CHROOT_LOG. The new system's
# tools (postinstall, the boot loaders, the initramfs, xbps) only log. The
# account tools act on TARGET's files the way shadow's do:
#   useradd -m -s SHELL [-c NAME] -G a,b,c USER   fails (exit 6) on a group
#                                                 TARGET/etc/group lacks
#   chpasswd                                      reads user:password lines
#   passwd -l root, chown                         log only
set -u
T=$1; shift
[ "${1:-}" = /usr/bin/env ] && shift
[ "${1:-}" = -i ] && shift
while [ $# -gt 0 ] && case "$1" in *=*) true ;; *) false ;; esac; do shift; done
# "env VAR=x command": the command is what counts
if [ "${1:-}" = env ]; then shift; while [ $# -gt 0 ] && case "$1" in *=*) true ;; *) false ;; esac; do shift; done; fi
LOG=${FAKE_CHROOT_LOG:?FAKE_CHROOT_LOG is not set}
printf '%s\n' "$*" >> "$LOG"
case "${1:-}" in
useradd)
	shift
	groups='' shell='' user=''
	while [ $# -gt 0 ]; do
		case "$1" in
		-G) groups=$2; shift ;;
		-s) shell=$2; shift ;;
		-c) shift ;;
		-m) ;;
		*) user=$1 ;;
		esac
		shift
	done
	IFS=, read -r -a gs <<< "$groups"
	for g in "${gs[@]}"; do
		grep -q "^$g:" "$T/etc/group" || { echo "useradd: group '$g' does not exist" >&2; exit 6; }
	done
	echo "$user:x:1000:1000::/home/$user:$shell" >> "$T/etc/passwd"
	mkdir -p "$T/home/$user"
	;;
chpasswd)
	while IFS=: read -r u p; do echo "chpasswd: $u (${#p} characters)" >> "$LOG"; done
	;;
esac
exit 0
