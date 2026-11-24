#!/bin/sh
# Every program ribbon-desktop puts in /usr/bin (srcpkgs/ribbon-desktop/files/bin) is run by something Ribbon ships:
# another program or script, a Tcl file, a .desktop entry, the labwc or session configuration. Its template and
# install manifest, which only install it, and the tests do not count. A helper nothing calls (the conky helpers
# ribbon-conky-gpu, -net and -temp were: the conky layouts read the GPU, sensors and network in ribbon.lua) is
# dead weight on every install.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0 n=0
for f in srcpkgs/ribbon-desktop/files/bin/*; do
	b=${f##*/}
	n=$((n + 1))
	if grep -rlwF --exclude=template -- "$b" srcpkgs | grep -v -x -F "$f" | grep -q .; then :; else
		echo "  FAIL /usr/bin/$b: nothing Ribbon ships runs it"; fails=$((fails + 1))
	fi
done
[ $fails -eq 0 ] && echo "  ok   each of ribbon-desktop's $n programs is run by something Ribbon ships"
[ $fails -eq 0 ]
