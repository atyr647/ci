#!/bin/sh
# ribbon-hdr (srcpkgs/ribbon-tools/files/bin/ribbon-hdr): what "on" and "off" write and how they apply in a running
# session, against a stand-in labwc that logs its arguments (and id, so the root check passes when the suite runs as
# root). Turning HDR off under the Vulkan renderer reloads labwc (<hdr>no</hdr> takes the screen out of HDR now);
# turning it on under GLES2 asks for a new login and does not reload; outside a Wayland session nothing is run.
set -u
cd "$(dirname "$0")/.." || exit 1
repo=$(pwd)
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/bin" "$T/home"
sed "s|/usr/lib/ribbon/common.sh|$repo/srcpkgs/ribbon-tools/files/lib/common.sh|" srcpkgs/ribbon-tools/files/bin/ribbon-hdr >"$T/ribbon-hdr"
cat >"$T/bin/labwc" <<W
#!/bin/sh
echo "\$*" >>"$T/labwc.calls"
W
printf '#!/bin/sh\n[ "${1:-}" = -u ] && { echo 1000; exit 0; }\nexec /usr/bin/id "$@"\n' >"$T/bin/id"
chmod +x "$T/bin/labwc" "$T/bin/id" "$T/ribbon-hdr"
fails=0
check() { what=$1; shift; if "$@"; then echo "  ok   $what"; else echo "  FAIL $what"; fails=$((fails + 1)); fi; }
hdr() { env -u WAYLAND_DISPLAY -u WLR_RENDERER HOME="$T/home" XDG_STATE_HOME="$T/home/state" XDG_CONFIG_HOME="$T/home/cfg" PATH="$T/bin:$PATH" "$@" bash "$T/ribbon-hdr" "${HDRCMD:-}"; }
RC=$T/home/state/ribbon/xdg/labwc/rc.xml
ENV=$T/home/state/ribbon/xdg/labwc/environment.d/50-hdr.env

: >"$T/labwc.calls"
out=$(HDRCMD=off hdr WAYLAND_DISPLAY=wayland-1 WLR_RENDERER=vulkan)
check "off under the Vulkan renderer: rc.xml says <hdr>no</hdr>" grep -q '<hdr>no</hdr>' "$RC"
check "off under the Vulkan renderer: labwc --reconfigure runs (the screen leaves HDR now)" grep -qx -- '--reconfigure' "$T/labwc.calls"
check "off under the Vulkan renderer: it says Applied, not log out ($out)" sh -c "echo '$out' | grep -q '^Applied' && ! echo '$out' | grep -q 'Log out'"
check "off: the next login no longer asks for the Vulkan renderer" sh -c "! grep -q WLR_RENDERER '$ENV'"

: >"$T/labwc.calls"
out=$(HDRCMD=on hdr WAYLAND_DISPLAY=wayland-1 WLR_RENDERER=gles2)
check "on under GLES2: rc.xml says <hdr>yes</hdr> and the next login takes Vulkan" sh -c "grep -q '<hdr>yes</hdr>' '$RC' && grep -qx WLR_RENDERER=vulkan '$ENV'"
check "on under GLES2: no reload, a new login is asked for" sh -c "[ ! -s '$T/labwc.calls' ] && echo '$out' | grep -q 'Log out'"

: >"$T/labwc.calls"
HDRCMD=on hdr WAYLAND_DISPLAY=wayland-1 WLR_RENDERER=vulkan >/dev/null
check "on under the Vulkan renderer: labwc --reconfigure runs" grep -qx -- '--reconfigure' "$T/labwc.calls"

: >"$T/labwc.calls"
HDRCMD=off hdr WAYLAND_DISPLAY=wayland-1 >/dev/null
check "off under GLES2 (the default renderer): labwc --reconfigure runs" grep -qx -- '--reconfigure' "$T/labwc.calls"

: >"$T/labwc.calls"
out=$(HDRCMD=off hdr)
check "outside a Wayland session: nothing runs, saved for the next login" sh -c "[ ! -s '$T/labwc.calls' ] && echo '$out' | grep -q 'next login'"
[ $fails -eq 0 ]
