#!/bin/bash
# The login screen's theme: ribbon-login-theme (the privileged helper) on a
# fake /etc (RIBBON_LOGIN_ROOT), with bad palettes, bad pictures, symlink
# and path tricks; then ribbon-theme driving it through a stubbed pkexec.
# Run as root (the helper checks that its directories are root's).
set -u
cd "$(dirname "$0")/.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
HELPER=$D/bin/ribbon-login-theme
PALS=$D/themes/palettes
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { local what=$1; shift; if "$@" >"$T/out" 2>&1; then ok "$what"; else fail "$what"; sed 's/^/       /' "$T/out"; fi; }
refuse() { local what=$1; shift; if "$@" >"$T/out" 2>&1; then fail "$what (was accepted)"; else ok "$what: $(tail -n 1 "$T/out" | sed 's/^ribbon-login-theme: //')"; fi; }

if [ "$(id -u)" != 0 ]; then echo "  skip login theme helper (needs root)"; exit 0; fi

R=$T/root
mkdir -p "$R/etc"
export RIBBON_LOGIN_ROOT=$R
H() { tclsh8.6 "$HELPER" "$@"; }
pal=$R/etc/ribbon/palette.conf

echo "ribbon-login-theme: palettes"
for p in "$PALS"/*.conf; do
	check "installs $(basename "$p" .conf)" H set-palette "$p"
done
check "the installed palette has the scheme's colours and id" sh -c "
	grep -qx 'ACCENT=#FF7A59' '$pal' && grep -qx 'NAME=\"Graphite\"' '$pal' && grep -qx '# id: ribbon' '$pal' &&
	grep -qx 'BAR_SHADOW=\"6 20 0.35 #000000\"' '$pal' && [ \"\$(stat -c %a '$pal')\" = 644 ]"
check "show reports it" sh -c "tclsh8.6 '$HELPER' show | grep -qx 'PALETTE_NAME=Graphite'"
cp "$pal" "$T/good"
bad() { # description, palette text
	printf '%b' "$2" > "$T/bad.conf"
	refuse "$1" H set-palette "$T/bad.conf"
}
bad "unknown key" 'ACCENT=#112233\nFOO=#112233\n'
bad "lower-case key" 'accent=#112233\n'
bad "shell in a key" 'ACCENT=#112233\n$(touch /tmp/x)=1\n'
bad "colour with 5 digits" 'ACCENT=#12345\n'
bad "colour with 7 digits" 'ACCENT=#1234567\n'
bad "colour not hex" 'ACCENT=#GG0000\n'
bad "colour by name" 'ACCENT=red\n'
bad "colour with a command" 'ACCENT=$(id)\n'
bad "colour with trailing junk" 'ACCENT=#112233; rm -rf /\n'
bad "mismatched quotes" 'ACCENT="#112233\n'
bad "alpha above 1" 'DESK_STRIPE_ALPHA=1.5\n'
bad "alpha not a number" 'DESK_STRIPE_ALPHA=abc\n'
bad "alpha negative" 'DESK_MARK_ALPHA=-0.1\n'
bad "shadow too big" 'BAR_SHADOW="6 2000 0.35 #000000"\n'
bad "shadow not numbers" 'BAR_SHADOW="a b c d"\n'
bad "name with a quote" 'NAME="Bad\\"Name"\nACCENT=#112233\n'
bad "name with \$" 'NAME=$HOME\nACCENT=#112233\n'
bad "name with a backtick" 'NAME=`id`\nACCENT=#112233\n'
bad "theme name with a slash" 'GTK_THEME=../../x\nACCENT=#112233\n'
bad "a key twice" 'ACCENT=#112233\nACCENT=#445566\n'
bad "a line without =" 'ACCENT=#112233\njust words\n'
bad "carriage returns" 'ACCENT=#112233\r\n'
bad "a NUL byte" 'ACCENT=#112233\n\0\n'
bad "not UTF-8" 'NAME=\xff\xfe\nACCENT=#112233\n'
bad "no colours at all" '# nothing\nNAME=Empty\n'
head -c 20000 /dev/zero | tr '\0' '#' > "$T/big.conf"
refuse "a file over 16 KB" H set-palette "$T/big.conf"
refuse "/dev/zero" H set-palette /dev/zero
refuse "a directory" H set-palette "$T"
check "rejected palettes left the installed one alone" cmp "$pal" "$T/good"
printf 'ACCENT=#22cc88\n  FG = #FFFFFF\n' > "$T/sp.conf"
refuse "spaces around =" H set-palette "$T/sp.conf"
printf '# mine\nNAME="Mint"\nACCENT=#22cc88\nDESK_TOP=#102030\n' > "$T/mint.conf"
check "a partial palette (the greeter fills in Graphite)" H set-palette "$T/mint.conf"
check "colours are normalised" grep -qx 'ACCENT=#22CC88' "$pal"

echo "ribbon-login-theme: paths and symlinks"
refuse "a relative path" H set-palette "palettes/ribbon.conf"
refuse "a ../ path" H set-palette "../ribbon.conf"
refuse "an output path of the caller's choosing" H set-palette "$PALS/ribbon.conf" "$T/out.conf"
[ -e "$T/out.conf" ] && fail "wrote the caller's output path"
refuse "an unknown command" H install "$PALS/ribbon.conf"
refuse "no command" H
mkdir -m 700 "$T/private"; cp "$PALS/ribbon-moss.conf" "$T/private/"
refuse "a file the caller can't read (PKEXEC_UID=nobody)" env PKEXEC_UID=65534 tclsh8.6 "$HELPER" set-palette "$T/private/ribbon-moss.conf"
check "a file the caller can read (PKEXEC_UID=nobody)" env PKEXEC_UID=65534 tclsh8.6 "$HELPER" set-palette "$PALS/ribbon-moss.conf"
echo victim > "$T/victim"
ln -sfn "$T/victim" "$pal"
check "palette.conf a symlink: replaced, not followed" H set-palette "$PALS/ribbon.conf"
check "  the symlink's target is untouched" sh -c "[ \"\$(cat '$T/victim')\" = victim ] && [ ! -L '$pal' ] && [ -f '$pal' ]"
rm -f "$pal"; mkdir -p "$T/linkdir"; ln -s "$T/linkdir" "$pal"
check "palette.conf a symlink to a directory: replaced, nothing put in the directory" sh -c "
	tclsh8.6 '$HELPER' set-palette '$PALS/ribbon.conf' && [ -f '$pal' ] && [ ! -L '$pal' ] && [ -z \"\$(ls -A '$T/linkdir')\" ]"
rm -f "$pal"; mkdir "$pal"
refuse "palette.conf a directory" H set-palette "$PALS/ribbon.conf"
rmdir "$pal"
mv "$R/etc/ribbon" "$T/realribbon"; ln -s "$T/realribbon" "$R/etc/ribbon"
refuse "/etc/ribbon a symlink" H set-palette "$PALS/ribbon-fjord.conf"
check "  nothing written through it" sh -c "! grep -q Fjord '$T/realribbon/palette.conf' 2>/dev/null"
rm "$R/etc/ribbon"; mv "$T/realribbon" "$R/etc/ribbon"
chmod 775 "$R/etc/ribbon"
refuse "/etc/ribbon writable by its group" H set-palette "$PALS/ribbon.conf"
chmod 755 "$R/etc/ribbon"
chown 65534 "$R/etc/ribbon"
refuse "/etc/ribbon not owned by root" H set-palette "$PALS/ribbon.conf"
chown 0 "$R/etc/ribbon"
refuse "RIBBON_LOGIN_ROOT relative" env RIBBON_LOGIN_ROOT=root tclsh8.6 "$HELPER" set-palette "$PALS/ribbon.conf"
check "no temporary files left behind" sh -c "[ -z \"\$(find '$R/etc/ribbon' -name '.*')\" ]"

echo "ribbon-login-theme: backgrounds"
mk() { tclsh8.6 tests/make-picture.tcl "$@"; }
L=$R/etc/ribbon/login
mk bands 1440 1100 "$T/tall.png"
check "a PNG" H set-background "$T/tall.png"
check "  installed as login/background.png, the same bytes" cmp "$T/tall.png" "$L/background.png"
cp "$T/tall.png" "$T/really-a-png.jpg"
check "a PNG named .jpg is stored as a PNG" sh -c "tclsh8.6 '$HELPER' set-background '$T/really-a-png.jpg' | grep -q 'PNG 1440x1100' && [ -f '$L/background.png' ] && [ ! -e '$L/background.jpg' ]"
mk jpeg 1920 1080 "$T/p.jpg"
check "a JPEG (and the PNG goes)" sh -c "tclsh8.6 '$HELPER' set-background '$T/p.jpg' | grep -q 'JPG 1920x1080' && [ -f '$L/background.jpg' ] && [ ! -e '$L/background.png' ]"
mk webp 2560 1440 "$T/p.webp"
check "a WebP" sh -c "tclsh8.6 '$HELPER' set-background '$T/p.webp' | grep -q 'WEBP 2560x1440' && [ -f '$L/background.webp' ] && [ ! -e '$L/background.jpg' ]"
check "show reports it" sh -c "tclsh8.6 '$HELPER' show | grep -qx 'BACKGROUND=$L/background.webp'"
cp "$L/background.webp" "$T/bg-before"
printf 'just text\n' > "$T/text.png"
refuse "text named .png" H set-background "$T/text.png"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$T/x.svg"
refuse "an SVG" H set-background "$T/x.svg"
printf '\x89PNG\r\n\x1a\nXXXXXXXX' > "$T/cut.png"
refuse "a PNG without its header chunk" H set-background "$T/cut.png"
mk png 20000 1000 "$T/wide.png"
refuse "a PNG 20000 px wide" H set-background "$T/wide.png"
mk png 10000 10000 "$T/huge.png"
refuse "a PNG of 100 megapixels" H set-background "$T/huge.png"
mk png 0 100 "$T/zero.png"
refuse "a PNG 0 px wide" H set-background "$T/zero.png"
{ cat "$T/tall.png"; head -c $((33 * 1024 * 1024)) /dev/zero; } > "$T/fat.png"
refuse "a picture over 32 MB" H set-background "$T/fat.png"
printf '\xff\xd8\xff\xe0\x00\x10JFIF' > "$T/cut.jpg"
refuse "a JPEG with no frame" H set-background "$T/cut.jpg"
printf 'RIFF\xff\xff\xff\x00WEBPVP8X' > "$T/cut.webp"
refuse "a WebP shorter than it says" H set-background "$T/cut.webp"
refuse "a relative path" H set-background "p.webp"
refuse "/dev/zero" H set-background /dev/zero
refuse "a picture the caller can't read" sh -c "cp '$T/tall.png' '$T/private/' && PKEXEC_UID=65534 tclsh8.6 '$HELPER' set-background '$T/private/tall.png'"
check "rejected pictures left the installed one alone" cmp "$L/background.webp" "$T/bg-before"
ln -sfn "$T/victim" "$L/background.png"
check "background.png a symlink: replaced, not followed" sh -c "
	tclsh8.6 '$HELPER' set-background '$T/tall.png' && [ ! -L '$L/background.png' ] && [ \"\$(cat '$T/victim')\" = victim ]"
ln -sfn "$T/victim" "$L/background.jpg"
check "ribbon: removes the picture (a symlink only as a link)" sh -c "
	tclsh8.6 '$HELPER' set-background ribbon && [ -z \"\$(ls -A '$L')\" ] && [ -f '$T/victim' ] &&
	tclsh8.6 '$HELPER' show | grep -qx BACKGROUND=ribbon"
rmdir "$L"; ln -s "$T/linkdir" "$L"
refuse "/etc/ribbon/login a symlink" H set-background "$T/tall.png"
check "  nothing written through it" sh -c "[ -z \"\$(ls -A '$T/linkdir')\" ]"
rm "$L"

echo "polkit: who may change the login screen"
P=$D/polkit
check "the policy is well-formed XML" python3 -c "import sys, xml.dom.minidom as m; m.parse(sys.argv[1])" "$P/org.ribbon.login-theme.policy"
check "pkexec's path is where the package puts the helper, and where ribbon-theme calls it" sh -c "
	grep -q '<annotate key=\"org.freedesktop.policykit.exec.path\">/usr/lib/ribbon/ribbon-login-theme</annotate>' '$P/org.ribbon.login-theme.policy' &&
	grep -q 'bin/ribbon-login-theme.* 755 usr/lib/ribbon' srcpkgs/ribbon-desktop/template &&
	grep -qx 'LOGIN_HELPER=/usr/lib/ribbon/ribbon-login-theme' '$D/bin/ribbon-theme'"
check "by default, an admin's password for everyone" sh -c "[ \"\$(grep -c '<allow_[a-z]*>auth_admin<' '$P/org.ribbon.login-theme.policy')\" = 3 ]"
if command -v node >/dev/null 2>&1; then
	# run the rules files as polkitd would, for a few subjects
	check "the rules: no password only for an active local admin" node -e '
		const fs = require("fs"); const rules = [];
		const polkit = { Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin", NOT_HANDLED: null },
			addRule: f => rules.push(f), log: () => {} };
		for (const f of process.argv.slice(1)) new Function("polkit", fs.readFileSync(f, "utf8"))(polkit);
		const ask = (id, user, groups, local, active) => {
			const s = { user, local, active, isInGroup: g => groups.includes(g) };
			for (const r of rules) { const v = r({ id }, s); if (v) return v; }
			return "default";
		};
		const A = "org.ribbon.login-theme", want = [
			[A, "alex", ["wheel"], true, true, "yes"],
			[A, "alex", ["wheel"], true, false, "default"],
			[A, "alex", ["wheel"], false, true, "default"],
			[A, "sam", ["users"], true, true, "default"],
			[A, "_greeter", ["video"], true, true, "default"],
			["org.freedesktop.login1.reboot", "alex", ["wheel"], true, true, "default"],
			["org.freedesktop.login1.reboot", "_greeter", [], true, true, "yes"]];
		let bad = 0;
		for (const w of want) { const got = ask(...w.slice(0, 5)); if (got !== w[5]) { console.log(w.slice(0, 5).join(" "), "->", got, "not", w[5]); bad++; } }
		process.exit(bad ? 1 : 0);' "$P/50-ribbon-login-theme.rules" "$D/greeter/50-ribbon-greeter.rules"
else
	echo "  skip the polkit rules (no node)"
fi

echo "ribbon-theme: the login screen follows (pkexec stubbed)"
B=$T/stubs; mkdir -p "$B"
# pkexec: log the call, run the helper as root on the fake /etc as polkit
# would (PKEXEC_UID = the caller); PKEXEC_HOLD waits for a file first,
# PKEXEC_FAIL refuses like a dismissed password dialog
cat > "$B/pkexec" <<EOF
#!/bin/sh
echo "\$*" >> "$T/pkexec.log"
if [ -n "\${PKEXEC_HOLD:-}" ]; then i=0; while [ ! -e "\$PKEXEC_HOLD" ] && [ \$i -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done; fi
[ -n "\${PKEXEC_FAIL:-}" ] && { echo "Error executing command as another user: Not authorized" >&2; exit 127; }
case "\$1" in /*) ;; *) echo "pkexec: needs an absolute path" >&2; exit 127 ;; esac
PKEXEC_UID=\$(id -u) exec tclsh8.6 "\$@"
EOF
# id: the groups this test says the user is in
cat > "$B/id" <<'EOF'
#!/bin/sh
case "$1" in -nG) echo "${FAKE_GROUPS:-user}" ;; -un) echo user ;; *) exec /usr/bin/id "$@" ;; esac
EOF
chmod +x "$B/pkexec" "$B/id"
export HOME=$T/home PATH=$B:$PATH
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME WAYLAND_DISPLAY
mkdir -p "$HOME"
RT="bash $D/bin/ribbon-theme"
LOG=$HOME/.local/state/ribbon/login-theme.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
waitlog() { # n: until the log has n lines (the background job is done)
	local i=0; while [ "$(lines)" -lt "$1" ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
	[ "$(lines)" -ge "$1" ]
}
rm -rf "${R:?}/etc/ribbon"; : > "$T/pkexec.log"
export FAKE_GROUPS="user wheel"
check "apply ribbon-fjord (an admin)" $RT apply ribbon-fjord --quiet --no-reload
check "  the login screen follows, in the background" sh -c "
	i=0; while ! grep -qs '# id: ribbon-fjord' '$pal' && [ \$i -lt 150 ]; do sleep 0.1; i=\$((i + 1)); done
	grep -qx 'NAME=\"Fjord\"' '$pal'"
check "  through pkexec and the helper's absolute path" grep -q "^/.*/ribbon-login-theme set-palette /.*/ribbon-fjord.conf$" "$T/pkexec.log"
check "  logged" waitlog 1
check "  theme.conf says so (and the default: follow)" sh -c "grep -qx PALETTE=ribbon-fjord '$HOME/.config/ribbon/theme.conf' && [ \"\$($RT login follow)\" = yes ]"
n=$(lines)
start=$(date +%s)
PKEXEC_HOLD=$T/release $RT apply ribbon-moss --quiet --no-reload
took=$(( $(date +%s) - start ))
check "apply doesn't wait for polkit (${took}s while pkexec is held)" sh -c "[ $took -le 3 ] && grep -q Fjord '$pal'"
touch "$T/release"
check "  then the login screen takes Moss" sh -c "i=0; while ! grep -qs Moss '$pal' && [ \$i -lt 150 ]; do sleep 0.1; i=\$((i + 1)); done; grep -q Moss '$pal'"
waitlog $((n + 1)); n=$(lines)
check "a failing pkexec doesn't fail apply" env PKEXEC_FAIL=1 $RT apply ribbon-amber --quiet --no-reload
check "  the desktop is Amber" grep -qx PALETTE=ribbon-amber "$HOME/.config/ribbon/theme.conf"
check "  the failure is logged" sh -c "i=0; while [ \"\$(wc -l < '$LOG')\" -le $n ] && [ \$i -lt 150 ]; do sleep 0.1; i=\$((i + 1)); done; tail -n 1 '$LOG' | grep -q 'not changed (pkexec status 127).*Not authorized'"
check "  the login screen is still Moss" grep -q Moss "$pal"
n=$(lines)
for s in ribbon-slate ribbon-midnight ribbon-dark; do $RT apply $s --quiet --no-reload; done
check "three applies in a row: the last one wins" sh -c "
	i=0; while [ \"\$(wc -l < '$LOG')\" -lt $((n + 3)) ] && [ \$i -lt 200 ]; do sleep 0.1; i=\$((i + 1)); done
	grep -qx '# id: ribbon-dark' '$pal'"
: > "$T/pkexec.log"
check "login follow no" $RT login follow no
check "  keeps the scheme in theme.conf" grep -qx PALETTE=ribbon-dark "$HOME/.config/ribbon/theme.conf"
$RT apply ribbon-slate --quiet --no-reload; sleep 0.5
check "  apply leaves the login screen alone" sh -c "[ ! -s '$T/pkexec.log' ] && grep -q '# id: ribbon-dark' '$pal'"
$RT login follow yes
$RT apply ribbon-slate --quiet --no-reload --no-login; sleep 0.5
check "apply --no-login (first login) leaves it alone" sh -c "[ ! -s '$T/pkexec.log' ]"
n=$(lines)
FAKE_GROUPS=user $RT apply ribbon-slate --quiet --no-reload; sleep 0.5
check "not an admin: no pkexec (it would ask for a password each time), logged" sh -c "
	[ ! -s '$T/pkexec.log' ] && [ \"\$(wc -l < '$LOG')\" -gt $n ] && tail -n 1 '$LOG' | grep -q 'not an admin'"
check "ribbon-theme login ribbon-moss (now, in the foreground)" sh -c "FAKE_GROUPS=user $RT login ribbon-moss && grep -q '# id: ribbon-moss' '$pal'"
refuse "ribbon-theme login with a refused password fails" env PKEXEC_FAIL=1 $RT login ribbon-fjord
refuse "ribbon-theme login nosuch" $RT login nosuch
mkdir -p "$HOME/.config/ribbon/palettes"
printf 'NAME="Mine"\nACCENT=#22CC88\n' > "$HOME/.config/ribbon/palettes/mine.conf"
check "your own palette" sh -c "$RT login mine && grep -qx 'ACCENT=#22CC88' '$pal'"
printf 'NAME="Evil"\nACCENT=$(touch %s/pwned)\n' "$T" > "$HOME/.config/ribbon/palettes/evil.conf"
refuse "your own palette with a bad colour" $RT login evil
[ -e "$T/pwned" ] && fail "a palette ran a command"
check "ribbon-theme login show (no pkexec)" sh -c ": > '$T/pkexec.log'; $RT login show | grep -qx PALETTE_NAME=Mine && [ ! -s '$T/pkexec.log' ]"
check "wallpaper login FILE (a relative name)" sh -c "cd '$T' && $RT wallpaper login tall.png"
check "  the login background is set" cmp "$T/tall.png" "$L/background.png"
check "wallpaper login ribbon" sh -c "$RT wallpaper login ribbon && [ ! -e '$L/background.png' ]"
refuse "wallpaper login with no file" $RT wallpaper login
refuse "wallpaper login with a missing file" $RT wallpaper login "$T/nosuch.png"

echo
[ $fails -eq 0 ] && echo "login theme: all checks passed" || echo "login theme: $fails checks failed"
[ $fails -eq 0 ]
