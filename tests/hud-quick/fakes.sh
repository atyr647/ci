#!/bin/sh
# fakes.sh DIR - the quick menu's services stood in for, in DIR: wpctl (the default output's volume in DIR/vol, its
# set-volume calls in DIR/wpctl.calls; muted while DIR/muted exists, set-mute calls in DIR/mute.calls), ribbon-hdr (the setting in DIR/hdr, on/off in DIR/hdr.calls) and
# ribbon-screenshot (touches DIR/shot.done). Used by tests/hud-quick/run.sh and the scene and native checks.
set -u
Q=$1; mkdir -p "$Q"
echo 0.64 > "$Q/vol"; echo on > "$Q/hdr"; : > "$Q/wpctl.calls"; : > "$Q/hdr.calls"; rm -f "$Q/shot.done" "$Q/muted" "$Q/mute.calls"
cat > "$Q/wpctl" <<W
#!/bin/sh
Q=$Q
W
cat >> "$Q/wpctl" <<'W'
case $1 in
get-volume) if [ -e "$Q/muted" ]; then echo "Volume: $(cat "$Q/vol") [MUTED]"; else echo "Volume: $(cat "$Q/vol")"; fi ;;
set-mute) echo "$*" >> "$Q/mute.calls"; [ "$3" = 0 ] && rm -f "$Q/muted" ;;
set-volume)
	echo "$*" >> "$Q/wpctl.calls"
	step=$5; v=$(cat "$Q/vol")
	awk -v v="$v" -v s="$step" 'BEGIN { d = (substr(s, length(s)) == "+") ? 0.05 : -0.05; n = v + d; if (n > 1) n = 1; if (n < 0) n = 0; printf "%.2f\n", n }' > "$Q/vol.new" && mv "$Q/vol.new" "$Q/vol" ;;
*) exit 1 ;;
esac
W
cat > "$Q/ribbon-hdr" <<W
#!/bin/sh
Q=$Q
W
cat >> "$Q/ribbon-hdr" <<'W'
case $1 in
status) echo "HDR: $(cat "$Q/hdr")   SDR white: 250 nits   game env: yes" ;;
on|off) echo "$1" >> "$Q/hdr.calls"; echo "$1" > "$Q/hdr"; echo "Applied." ;;
*) exit 1 ;;
esac
W
printf '#!/bin/sh\ntouch "%s/shot.done"\n' "$Q" > "$Q/ribbon-screenshot"
chmod +x "$Q/wpctl" "$Q/ribbon-hdr" "$Q/ribbon-screenshot"
