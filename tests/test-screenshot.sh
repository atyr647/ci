#!/bin/sh
# ribbon-screenshot (Print, Shift+Print) against stand-ins for grim, slurp, wl-copy and xdg-open, with the real shell
# as the notification server on a private session bus (tests/shell-notify-bus.tcl clicks an entry's first keycap,
# as a person would). The whole screen: the picture lands in Pictures/Screenshots, goes on the clipboard as PNG, and
# one notification arrives as the board draws it (Screenshot · "Screenshot taken" · the path under home, the camera
# icon); its Open opens the picture with xdg-open and the script then ends. A region: slurp's choice goes to grim
# -g; cancelled in slurp, nothing is taken and nothing is sent. With no notification server it still takes the
# picture. Then ribbon-browser (the menu's Web browser) starts the Exec line of the browser chosen in Default apps.
set -u
cd "$(dirname "$0")/.." || exit 1
for t in dbus-daemon gdbus tclsh8.6 wish8.6 xvfb-run mkfifo; do command -v $t >/dev/null 2>&1 || { echo "  skip ribbon-screenshot (no $t)"; exit 0; }; done
F=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d); SH=; BUS=
trap 'kill $SH $BUS 2>/dev/null; rm -rf "$T"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	mkdir -p "$T/ux"; make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >/dev/null 2>&1 || { echo "  skip ribbon-screenshot (unix_extra does not build)"; exit 0; }
	ux=$T/ux
fi
fails=0
ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
until_line() { i=0; while [ $i -lt "$2" ]; do grep -q -- "$1" "$3" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

# the stand-ins: each writes what it was asked to $T/calls
mkdir -p "$T/bin" "$T/h" "$T/c" "$T/s" "$T/r"; chmod 700 "$T/r"
cat > "$T/bin/grim" <<EOF
#!/bin/sh
echo "grim \$*" >> $T/calls
for last; do :; done
printf '\211PNG\r\n\032\nstand-in picture' > "\$last"
EOF
cat > "$T/bin/slurp" <<EOF
#!/bin/sh
echo slurp >> $T/calls
[ -e $T/cancel ] && exit 1
echo "10,20 300x200"
EOF
cat > "$T/bin/wl-copy" <<EOF
#!/bin/sh
echo "wl-copy \$* \$(cat | od -An -c | tr -d ' \n' | head -c 12)" >> $T/calls
EOF
cat > "$T/bin/xdg-open" <<EOF
#!/bin/sh
echo "xdg-open \$*" >> $T/calls
EOF
chmod +x "$T/bin/"*
P=$PATH
export PATH="$T/bin:$P" HOME=$T/h XDG_CACHE_HOME=$T/c XDG_STATE_HOME=$T/s XDG_RUNTIME_DIR=$T/r XDG_CONFIG_HOME=$T/h/.config
shot() { RIBBON_SCREENSHOT_WAIT=${WAIT:-20} timeout -k 2 30 sh "$F/bin/ribbon-screenshot" "$@"; }

# 0. no session bus at all: the picture is still taken, and the script does not wait
DBUS_SESSION_BUS_ADDRESS=unix:path=$T/nobus shot; rc=$?
ls "$T/h/Pictures/Screenshots/"*.png >/dev/null 2>&1 && [ $rc -eq 0 ] && ok "with no notification server the picture is still taken" || bad "no bus: rc $rc, $(cat "$T/calls" 2>/dev/null)"
rm -rf "$T/h/Pictures" "$T/calls"

cat > "$T/bus.conf" <<XML
<busconfig><type>session</type><listen>unix:dir=$T</listen>
<policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/><allow eavesdrop="true"/></policy></busconfig>
XML
dbus-daemon --nofork --nopidfile --config-file="$T/bus.conf" --print-address=3 3>"$T/addr" 2>"$T/daemon.log" & BUS=$!
i=0; while [ ! -s "$T/addr" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
DBUS_SESSION_BUS_ADDRESS=$(cat "$T/addr"); export DBUS_SESSION_BUS_ADDRESS
TCLLIBPATH="${ux:+$ux}${TCLLIBPATH:+${ux:+ }$TCLLIBPATH}"; export TCLLIBPATH
NOTIFY_BUS_LOG=$T/log RIBBON_SHELL_TEST=tests/shell-notify-bus.tcl timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 "$F/shell/main.tcl" -name ribbon-shell >"$T/shell.out" 2>&1 & SH=$!
until_line "status primary" 150 "$T/log" || { bad "the shell did not take org.freedesktop.Notifications"; sed 's/^/       /' "$T/shell.out" "$T/log" 2>/dev/null; exit 1; }

# 1. the whole screen
shot; rc=$?
f=$(ls "$T/h/Pictures/Screenshots/"*.png 2>/dev/null | head -1)
case $f in
	"$T/h/Pictures/Screenshots/"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9].png) ok "the picture is in Pictures/Screenshots ($(basename "$f"))";;
	*) bad "no picture in Pictures/Screenshots: $(ls -R "$T/h" | tr '\n' ' ')";;
esac
grep -qx "grim ${f:-none}" "$T/calls" && ok "grim takes the whole screen (no -g)" || bad "grim was run as: $(grep grim "$T/calls")"
grep -q '^wl-copy --type image/png 211PNG' "$T/calls" && ok "the picture goes on the clipboard as image/png" || bad "the clipboard: $(grep wl-copy "$T/calls")"
n=$(grep -c ' app=Screenshot ' "$T/log")
grep -q "app=Screenshot summary=Screenshot taken body=Pictures/Screenshots/$(basename "${f:-none}") icon=line camera" "$T/log" && [ "$n" -eq 1 ] &&
	ok "one notification: Screenshot · Screenshot taken · the path under home, the camera icon" || bad "the notification ($n): $(grep 'app=Screenshot' "$T/log")"
grep -q '^clicked ' "$T/log" && grep -qx "xdg-open ${f:-none}" "$T/calls" && ok "its Open opens the picture with xdg-open" || bad "Open: $(grep -e clicked -e 'no keycap' "$T/log") / $(grep xdg-open "$T/calls")"
[ $rc -eq 0 ] && ok "the script ends once Open is chosen" || bad "the script ended with $rc (124: it kept waiting)"

# 2. a region
rm -f "$T/calls"; rm -rf "$T/h/Pictures"
shot region
f=$(ls "$T/h/Pictures/Screenshots/"*.png 2>/dev/null | head -1)
grep -qx 'slurp' "$T/calls" && grep -qx "grim -g 10,20 300x200 ${f:-none}" "$T/calls" && ok "a region: slurp's choice goes to grim -g" || bad "the region: $(cat "$T/calls" | tr '\n' ' ')"
# 3. a region cancelled in slurp
rm -f "$T/calls"; rm -rf "$T/h/Pictures"; touch "$T/cancel"
before=$(grep -c ' app=Screenshot ' "$T/log")
shot region; rc=$?
sleep 0.5
after=$(grep -c ' app=Screenshot ' "$T/log")
! grep -q '^grim' "$T/calls" && [ "$before" -eq "$after" ] && [ $rc -eq 0 ] && ok "a region cancelled in slurp takes nothing and sends nothing" || bad "cancelled: rc $rc, $(cat "$T/calls" | tr '\n' ' '), notifications $before -> $after"
rm -f "$T/cancel"
# 4. a name already taken (two in one second) gets a suffix, not an overwrite: the names of this second and the
# next few are taken beforehand
rm -f "$T/calls"; rm -rf "$T/h/Pictures"; mkdir -p "$T/h/Pictures/Screenshots"
now=$(date +%s); taken=
for k in 0 1 2 3; do n=$(date -d "@$((now + k))" +%F_%H-%M-%S); : > "$T/h/Pictures/Screenshots/$n.png"; taken="$taken $n"; done
shot
over=; for n in $taken; do [ -s "$T/h/Pictures/Screenshots/$n.png" ] && over="$over $n"; done
new=$(find "$T/h/Pictures/Screenshots" -maxdepth 1 -name '*-1.png' | wc -l)
[ -z "$over" ] && [ "$new" -eq 1 ] && ok "a name already taken is not overwritten (the new one has -1)" || bad "taken names: overwritten$over, $(ls "$T/h/Pictures/Screenshots" | tr '\n' ' ')"
grep -q '  FAIL' "$T/shell.out" && { bad "the shell reported an error"; sed 's/^/       /' "$T/shell.out"; }

# 5. ribbon-browser: the Exec line of the browser chosen in Default apps (x-scheme-handler/https), field codes out
mkdir -p "$T/h/.local/share/applications" "$T/data/applications"
cat > "$T/bin/xdg-mime" <<EOF
#!/bin/sh
[ "\$*" = "query default x-scheme-handler/https" ] && cat $T/chosen 2>/dev/null
EOF
cat > "$T/bin/pickedbrowser" <<EOF
#!/bin/sh
echo "pickedbrowser [\$*]" >> $T/calls
EOF
chmod +x "$T/bin/xdg-mime" "$T/bin/pickedbrowser"
printf '[Desktop Entry]\nName=Picked\nExec=pickedbrowser --new-window %%U\n[Desktop Action private]\nExec=pickedbrowser --private\n' > "$T/data/applications/picked.desktop"
echo picked.desktop > "$T/chosen"
rm -f "$T/calls"
XDG_DATA_DIRS=$T/data sh "$F/bin/ribbon-browser"; rc=$?
[ $rc -eq 0 ] && grep -qx 'pickedbrowser \[--new-window\]' "$T/calls" && ok "Web browser starts the chosen browser's Exec line, its %U taken out" || bad "ribbon-browser: rc $rc, $(cat "$T/calls" 2>/dev/null)"
: > "$T/chosen"
XDG_DATA_DIRS=$T/data sh "$F/bin/ribbon-browser" 2>"$T/err"; rc=$?
[ $rc -ne 0 ] && grep -q 'no web browser is chosen' "$T/err" && ok "with no browser chosen it says so" || bad "no browser chosen: rc $rc $(cat "$T/err")"

[ $fails -eq 0 ] && echo "ribbon-screenshot and ribbon-browser: all checks passed"
[ $fails -eq 0 ]
