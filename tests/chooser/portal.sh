#!/bin/sh
# portal.sh T D: the FileChooser portal's run for tests/steps.d/62-chooser.sh, inside xvfb-run: a private session bus
# that activates org.freedesktop.impl.portal.desktop.ribbon from the shipped .service file (Exec pointed at the
# source tree), and tests/chooser/portal.tcl as the frontend. HOME and the rest come from the step.
T=$1; D=$2
mkdir -p "$T/services" "$T/mime/mime"
sed "s#^Exec=.*#Exec=$(command -v tclsh8.6) $D/appearance/chooser-portal.tcl#" \
	"$D/dbus-services/org.freedesktop.impl.portal.desktop.ribbon.service" >"$T/services/org.freedesktop.impl.portal.desktop.ribbon.service"
grep -q '^Name=org.freedesktop.impl.portal.desktop.ribbon$' "$T/services/org.freedesktop.impl.portal.desktop.ribbon.service" ||
	{ echo "  FAIL the .service file does not name org.freedesktop.impl.portal.desktop.ribbon"; exit 1; }
# shared-mime-info's globs for the MIME filters
printf '%s\n' '50:image/jpeg:*.jpg' '50:image/jpeg:*.jpeg' '50:image/png:*.png' >"$T/mime/mime/globs2"
cat >"$T/session.conf" <<XML
<busconfig><type>session</type><listen>unix:dir=$T</listen><servicedir>$T/services</servicedir>
<policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/></policy></busconfig>
XML
XDG_DATA_DIRS=$T/mime CHOOSER_FLOW_FILE=$T/flow RIBBON_CHOOSER_TEST=$PWD/tests/chooser/flow.tcl \
	timeout 200 dbus-daemon --nofork --nopidfile --config-file="$T/session.conf" --print-address=3 3>"$T/ses.addr" 2>"$T/ses.log" &
bp=$!
i=0; while [ ! -s "$T/ses.addr" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/ses.addr" ] || { cat "$T/ses.log"; echo "  FAIL dbus-daemon did not start"; exit 1; }
CHOOSER_FLOW_FILE=$T/flow DBUS_SESSION_BUS_ADDRESS=$(cat "$T/ses.addr") timeout 180 tclsh8.6 tests/chooser/portal.tcl "$HOME"
st=$?
kill $bp 2>/dev/null; wait $bp 2>/dev/null
exit $st
