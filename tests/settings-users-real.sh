#!/bin/sh
# settings-users-real.sh - ribbon-users-helper as root with the REAL useradd, usermod, userdel, gpasswd, groupadd and
# chpasswd, and users.tcl changing your own password through the REAL passwd(1) and PAM. It must be run in a mount
# namespace of its own (tests/steps.d/56-settings-users-real.sh: unshare -m), where a copy of /etc is mounted over
# /etc, so the machine's own accounts are never touched; it stops before doing anything if that mount is not there.
#   unshare -m sh tests/settings-users-real.sh HELPER FILES-DIR TMP     (TMP/etc is the copy, with a marker file)
# Prints "  ok   ..." / "  FAIL ..." lines; exits 1 if any failed, 77 if it cannot run here.
set -u
H=$1; D=$2; T=$3
mount --bind "$T/etc" /etc 2>/dev/null || { echo "  skip: cannot mount here"; exit 77; }
[ -e /etc/.ribbon-users-test ] || { echo "  skip: the private /etc is not in place"; exit 77; }
# the helper keeps the highest removed user number in /var/lib/ribbon: a directory of this run's own is mounted there too
mkdir -p /var/lib/ribbon "$T/varlib" && mount --bind "$T/varlib" /var/lib/ribbon 2>/dev/null || { echo "  skip: cannot mount /var/lib/ribbon here"; exit 77; }
fails=0; n=0
ok() { n=$((n + 1)); echo "  ok   $1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "  FAIL $1"; }
is() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
field() { awk -F: -v u="$1" -v f="$2" '$1 == u { print $f }' /etc/passwd; }
members() { awk -F: -v g="$1" '$1 == g { print "," $4 "," }' /etc/group; }
# the password P is LOGIN's (its hash in /etc/shadow says so)
has_pw() { perl -e 'open(F, "/etc/shadow") or exit 2; while (<F>) { @f = split /:/; if ($f[0] eq $ARGV[0]) { exit(crypt($ARGV[1], $f[1]) eq $f[1] ? 0 : 1) } } exit 3' "$1" "$2"; }

PW1='Kestrel-Harbour-41 $(id) "q" :x'
PW2='Lantern-Quay-77x'
PW3='Marram-Dune-3048'
grep -q '^wheel:' /etc/group || groupadd -r wheel
useradd -m -U -s /bin/sh rbnboss && gpasswd -a rbnboss wheel >/dev/null || { echo "  skip: the real useradd does not work here"; exit 77; }
BOSS=$(id -u rbnboss)
# the helper as pkexec starts it: root, PKEXEC_UID; the test variables are set to show that root does not read them
mkdir -p "$T/fakebin"
for t in useradd usermod userdel gpasswd groupadd chpasswd tr; do printf '#!/bin/sh\necho x >%s/fakebin/ran\n' "$T" >"$T/fakebin/$t"; chmod 755 "$T/fakebin/$t"; done
h() { PKEXEC_UID=$BOSS RIBBON_USERS_TEST=1 RIBBON_USERS_ROOT="$T/nowhere" RIBBON_USERS_BIN="$T/fakebin" "$H" "$@"; }

printf 'rbnmira\n%s\n' "$PW1" | h add rbnmira off 'Mira Quill'
is "add: the account is there, a person's uid, the full name, a home folder of her own" \
	'[ "$(field rbnmira 3)" -ge 1000 ] && [ "$(field rbnmira 5)" = "Mira Quill" ] && [ -d "$T/home/rbnmira" ] && [ "$(stat -c %U "$T/home/rbnmira")" = rbnmira ]'
is "  her own group, and not wheel" 'grep -q "^rbnmira:" /etc/group && ! members wheel | grep -q ",rbnmira,"'
is "  the shell is one to log in with" 'case "$(field rbnmira 7)" in */nologin|*/false|"") false ;; *) [ -x "$(field rbnmira 7)" ] ;; esac'
is "  the password given on the standard input is hers (with its spaces, quotes and \$( ))" 'has_pw rbnmira "$PW1"'
printf 'rbnjon\n%s\n' "$PW2" | h add rbnjon on 'Jon'
is "add as an administrator: in wheel" 'members wheel | grep -q ",rbnjon,"'
printf 'rbnjon\n%s\n' "$PW2" | h add rbnjon off 'Again' 2>/dev/null
is "add refused for a name that is taken (exit 2)" '[ $? -eq 2 ]'
lines=$(wc -l </etc/passwd)
h rename rbnmira "$(printf 'Mira: Q,x\nevil::0:0::/:/bin/sh')"
is "rename with colons, a comma and a newline: one clean GECOS field, no new line in /etc/passwd, one uid 0" \
	'[ "$(field rbnmira 5)" = "Mira Qxevil00//bin/sh" ] && [ "$(wc -l </etc/passwd)" = "$lines" ] && [ "$(awk -F: "\$3 == 0" /etc/passwd | wc -l)" = 1 ]'
h rename rbnmira '-c x --help'
is "rename to a name that looks like options" '[ "$(field rbnmira 5)" = "-c x --help" ]'
h rename rbnmira 'Mira Quill'
h admin rbnmira on
is "admin on: in wheel" 'members wheel | grep -q ",rbnmira,"'
h admin rbnmira off
is "admin off: out of wheel" '! members wheel | grep -q ",rbnmira,"'
h admin rbnjon off
h admin rbnboss off 2>/dev/null
is "the last administrator keeps the right (exit 2)" '[ $? -eq 2 ] && members wheel | grep -q ",rbnboss,"'
h nopass rbnmira on
is "nopass on: the group nopasswdlogin is made, and she is in it" 'members nopasswdlogin | grep -q ",rbnmira,"'
h nopass rbnmira off
is "nopass off: out of it" '! members nopasswdlogin | grep -q ",rbnmira,"'
printf 'rbnmira\n%s\n' "$PW2" | h passwd rbnmira
is "passwd (an administrator sets it): the new password is hers, the old one is not" 'has_pw rbnmira "$PW2" && ! has_pw rbnmira "$PW1"'
root_before=$(grep '^root:' /etc/shadow)
printf 'root\n%s\n' "$PW2" | h passwd root 2>/dev/null
is "passwd root: refused, root's password untouched" '[ $? -eq 2 ] && [ "$(grep "^root:" /etc/shadow)" = "$root_before" ]'
h remove daemon delete 2>/dev/null
is "remove daemon: refused" '[ $? -eq 2 ] && grep -q "^daemon:" /etc/passwd'

# your own password: users.tcl runs passwd(1) as you; PAM checks the current one
if command -v setpriv >/dev/null 2>&1 && command -v tclsh8.6 >/dev/null 2>&1; then
	setpriv --reuid=rbnmira --regid=rbnmira --init-groups env -i PATH=/usr/bin:/bin HOME="$T/home/rbnmira" \
		tclsh8.6 -encoding utf-8 "$(dirname "$0")/settings-users-real.tcl" "$D" "$PW2" "$PW3" >"$T/own.out" 2>&1
	rc=$?
	cat "$T/own.out"
	n=$((n + $(grep -c '^  \(ok  \|FAIL\) ' "$T/own.out"))); fails=$((fails + $(grep -c '^  FAIL ' "$T/own.out")))
	[ $rc -eq 0 ] || [ "$(grep -c '^  FAIL ' "$T/own.out")" -gt 0 ] || bad "the own-password check did not run: exit $rc"
	is "  /etc/shadow agrees: the new password is hers, the old one is not" 'has_pw rbnmira "$PW3" && ! has_pw rbnmira "$PW2"'
else
	echo "  skip your own password through passwd(1) (no setpriv / tclsh8.6)"
fi

h remove rbnboss delete 2>/dev/null
is "remove refused for the account that asked" '[ $? -eq 2 ] && grep -q "^rbnboss:" /etc/passwd'
h remove rbnmira keep
is "remove, keeping the home folder: the account and its group are gone, the folder is there" \
	'! grep -q "^rbnmira:" /etc/passwd && ! grep -q "^rbnmira:" /etc/group && [ -d "$T/home/rbnmira" ]'
h remove rbnjon delete
is "remove: the account and its home folder are gone" '! grep -q "^rbnjon:" /etc/passwd && [ ! -e "$T/home/rbnjon" ]'
# a removed account's number is not given to the next account: its kept files would be the new one's (shadow's useradd
# takes the highest number in /etc/passwd plus one, which is the removed account's again)
printf 'rbnx\n%s\n' "$PW3" | h add rbnx off 'X'
UX=$(id -u rbnx)
h remove rbnx keep
printf 'rbny\n%s\n' "$PW3" | h add rbny off 'Y'
is "an account added after the highest was removed does not get its number (was $UX; the real useradd)" '[ "$(id -u rbny)" -gt "$UX" ]'
is "  the number is recorded in the helper's own directory, not in /etc" '[ "$(cat /var/lib/ribbon/users-uid-mark)" = "$UX" ]'
is "as root the test variables were never read (no stand-in tool ran)" '[ ! -e "$T/fakebin/ran" ]'
echo "$n checks, $fails failed"
[ "$fails" -eq 0 ]
