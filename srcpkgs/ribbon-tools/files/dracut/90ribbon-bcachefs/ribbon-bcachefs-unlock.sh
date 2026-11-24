#!/bin/sh
# Ask for the bcachefs passphrase before dracut mounts an encrypted root.
# `bcachefs unlock` reads the passphrase from its standard input (bcachefs-tools, fs/util/prompt/userspace.rs: a terminal's
# line with echo off, or one line from a pipe; never /dev/tty). dracut's ask_for_password asks on the console or on
# plymouth's splash and writes the answer to the command's standard input, so the prompt shows and works whatever
# standard input this hook was started with. Without it (an old dracut) the command is run as it is, three tries.
# Tests: tests/steps.d/25-bcachefs-unlock.sh (stand-ins for getarg, modprobe, bcachefs and ask_for_password).
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
[ "$(getarg rootfstype=)" = bcachefs ] || return 0
dev=$(getarg root=)
case "$dev" in UUID=*) dev=/dev/disk/by-uuid/${dev#UUID=} ;; esac
modprobe -q bcachefs
# -c: exit 0 for an encrypted device (locked or not), 1 for one with no encryption: only the first is asked about
if bcachefs unlock -c "$dev" >/dev/null 2>&1; then
	if type ask_for_password >/dev/null 2>&1; then
		ask_for_password --cmd "bcachefs unlock -k session $dev" --prompt "Passphrase for $dev" --tries 3 --tty-echo-off
	else
		tries=0
		while [ $tries -lt 3 ]; do
			bcachefs unlock -k session "$dev" && break
			tries=$((tries + 1))
		done
	fi
fi
