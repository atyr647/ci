#!/bin/sh
# Mail's passwords at login (srcpkgs/ribbon-desktop/INSTALL, post): pam_gnome_keyring goes into greetd's PAM file
# after its auth lines ("auth optional", unlocks the login keyring with the password typed) and after its session
# lines ("session optional ... auto_start"), once, next to the nopasswdlogin rule the same script adds; a
# Debian-style file (@include) and a base without the module or without greetd are checked too. Needs only sh/awk.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
INST=$PWD/srcpkgs/ribbon-desktop/INSTALL
FRAG=$PWD/srcpkgs/ribbon-desktop/files/greetd/pam-nopasswdlogin
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
mkroot() { # DIR MODULEDIR (or "")
	rm -rf "$1"; mkdir -p "$1/etc/pam.d" "$1/usr/share/ribbon/greetd"
	cp "$FRAG" "$1/usr/share/ribbon/greetd/pam-nopasswdlogin"
	[ -n "$2" ] && { mkdir -p "$1/$2"; : > "$1/$2/pam_gnome_keyring.so"; }
	:
}
post() { (cd "$1" && ACTION=post PATH=$T/bin:$PATH sh "$INST" ribbon-desktop 0.9 no >/dev/null 2>&1); }
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/usermod"; chmod +x "$T/bin/usermod"
line() { grep -n -- "$2" "$1" | head -n 1 | cut -d: -f1; }

R=$T/void; mkroot "$R" usr/lib/security
cat > "$R/etc/pam.d/greetd" <<'EOF'
#%PAM-1.0

auth       required     pam_securetty.so
auth       requisite    pam_nologin.so
auth       include      system-local-login
account    include      system-local-login
session    include      system-local-login
EOF
post "$R"
G=$R/etc/pam.d/greetd
a=$(line "$G" '^auth       optional     pam_gnome_keyring.so$'); s=$(line "$G" '^session    optional     pam_gnome_keyring.so auto_start$')
ai=$(line "$G" '^auth *include'); si=$(line "$G" '^session *include'); np=$(line "$G" 'ingroup nopasswdlogin')
if [ -n "$a" ] && [ "$a" -eq $((ai + 1)) ] && [ -n "$s" ] && [ "$s" -eq $((si + 1)) ]; then
	ok "pam: auth optional pam_gnome_keyring.so after the auth lines, session optional ... auto_start after the session lines"
else cat "$G"; fail "pam: pam_gnome_keyring's lines (auth $a after $ai, session $s after $si)"; fi
[ -n "$np" ] && [ "$np" -lt "$ai" ] && ok "pam: the nopasswdlogin rule still comes ahead of the password stack" ||
	fail "pam: nopasswdlogin rule at line ${np:-none}"
[ "$(wc -l < "$G")" -eq 11 ] && ok "pam: nothing else changed" || { cat "$G"; fail "pam: other lines changed"; }
cp "$G" "$T/once"; post "$R"
cmp -s "$G" "$T/once" && ok "pam: a second install adds nothing" || { diff "$T/once" "$G"; fail "pam: a second install changed the file"; }

R=$T/deb; mkroot "$R" usr/lib/x86_64-linux-gnu/security
cat > "$R/etc/pam.d/greetd" <<'EOF'
#%PAM-1.0
auth       requisite    pam_nologin.so
@include common-auth
@include common-account
@include common-session
-session   optional     pam_elogind.so
EOF
post "$R"
G=$R/etc/pam.d/greetd
a=$(line "$G" 'auth .*pam_gnome_keyring'); s=$(line "$G" 'session .*pam_gnome_keyring'); ca=$(line "$G" '@include common-auth'); el=$(line "$G" 'pam_elogind')
[ -n "$a" ] && [ "$a" -eq $((ca + 1)) ] && [ -n "$s" ] && [ "$s" -eq $((el + 1)) ] &&
	ok "pam: after @include common-auth, and after the last session line (a -session one too)" || { cat "$G"; fail "pam: Debian-style order"; }

R=$T/nomod; mkroot "$R" ""
printf 'auth include system-local-login\nsession include system-local-login\n' > "$R/etc/pam.d/greetd"
post "$R"
grep -q pam_gnome_keyring "$R/etc/pam.d/greetd" && fail "pam: lines added for a module the base does not have" ||
	ok "pam: a base without pam_gnome_keyring.so gets no lines for it"

R=$T/nogreetd; mkroot "$R" usr/lib/security
post "$R"
[ ! -e "$R/etc/pam.d/greetd" ] && ok "pam: a base without greetd's PAM file gets none" || fail "pam: a greetd PAM file was made"

R=$T/had; mkroot "$R" usr/lib/security
printf 'auth include system-local-login\nauth optional pam_gnome_keyring.so\nsession include system-local-login\nsession optional pam_gnome_keyring.so auto_start\n' > "$R/etc/pam.d/greetd"
post "$R"
[ "$(grep -c pam_gnome_keyring "$R/etc/pam.d/greetd")" -eq 2 ] && ok "pam: a file that has the module already is left with its own lines" ||
	{ cat "$R/etc/pam.d/greetd"; fail "pam: lines doubled"; }
[ "$fails" -eq 0 ]
