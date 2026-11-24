#!/bin/sh
# The sudo rule that lets GameMode switch the scheduler mode (srcpkgs/ribbon-gaming/files/sudoers-gaming): valid sudoers
# syntax, only the two exact commands GameMode's start= and end= run (gamemode.ini), and for the group audio, not ALL
# (review finding of 17 Nov: any account of the machine could restart scx and flip the power profile in a loop).
set -u
cd "$(dirname "$0")/../.." || exit 1
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
F=srcpkgs/ribbon-gaming/files/sudoers-gaming
rule=$(grep -v '^[[:space:]]*#' "$F" | grep .)
[ "$(printf '%s\n' "$rule" | wc -l)" = 1 ] && ok "one rule" || bad "rules: $rule"
case $rule in '%audio ALL=(root) NOPASSWD: '*) ok "it is for the group audio, as root, without a password" ;; *) bad "rule: $rule" ;; esac
case $rule in 'ALL '*) bad "the rule is for every account" ;; *) ok "  not for every account" ;; esac
cmds=${rule#*NOPASSWD: }
[ "$cmds" = "/usr/bin/ribbon-scheduler gamemode on, /usr/bin/ribbon-scheduler gamemode off" ] && ok "only the two exact commands, arguments included" || bad "commands: $cmds"
start=$(sed -n 's/^start=//p' srcpkgs/ribbon-gaming/files/gamemode.ini); end=$(sed -n 's/^end=//p' srcpkgs/ribbon-gaming/files/gamemode.ini)
[ "$start" = "/usr/bin/ribbon-scheduler gamemode on" ] && [ "$end" = "/usr/bin/ribbon-scheduler gamemode off" ] && ok "they are what gamemode.ini's start= and end= run" || bad "gamemode.ini: $start / $end"
if command -v visudo >/dev/null 2>&1; then
	visudo -c -q -f "$F" 2>/dev/null && ok "visudo accepts the file" || bad "visudo rejects the file"
else
	echo "  skip visudo's syntax check (no visudo)"
fi
exit $fail
