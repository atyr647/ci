#!/bin/bash
# macOS: does an ad-hoc signature that was embedded OFF the Mac (rcodesign, Linux) work like one made by codesign on the Mac, with and without the quarantine attribute a browser download carries?
# usage: mac_run.sh <dir with unsigned/ and server/ : each holds App.app (bundle) and launcher (bare Mach-O)>
cd "$1" || exit 2
R() { echo "RESULT $*"; }
q() { echo "0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)"; }
to() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # run with a time limit
echo "##### macOS $(sw_vers -productVersion) $(uname -m)"
for v in unsigned server; do
  chmod -R u+rwX $v; chmod +x $v/launcher $v/App.app/Contents/MacOS/* $v/App.app/Contents/Resources/game.com
  R "[$v] launcher: $(codesign -dvvv $v/launcher 2>&1 | grep -E 'Signature|Format|flags|Identifier|not signed' | tr '\n' '|' | cut -c1-260)"
  R "[$v] launcher codesign --verify --strict: $(codesign --verify --strict -vvv $v/launcher 2>&1 | head -2 | tr '\n' ' ')"
done
cp -R unsigned local; cp -R unsigned/launcher local/launcher.bak
codesign --force -s - local/launcher; codesign --force --deep -s - local/App.app
for v in unsigned server local; do
  R "[$v] run bare launcher (no args, expect exit 92 = it started and could not find its bundle files): exit $(to 20 ./$v/launcher >/dev/null 2>&1; echo $?)"
done
echo "##### whole bundle, started the way the launcher runs it (direct exec of Contents/MacOS/launcher)"
for v in unsigned server local; do
  out=$(to 60 ./$v/App.app/Contents/MacOS/launcher 2>&1 | tr '\n' ' ' | cut -c1-200); R "[$v] bundle direct exec: exit ${PIPESTATUS[0]} :: $out"
  R "[$v] bundle codesign --verify --deep --strict: $(codesign --verify --deep --strict -vvv $v/App.app 2>&1 | head -2 | tr '\n' ' ')"
  R "[$v] bundle signature: $(codesign -dvvv $v/App.app 2>&1 | grep -E 'Signature=|Format|flags|Sealed|CodeDirectory' | tr '\n' '|' | cut -c1-260)"
done
echo "##### with the quarantine attribute a browser sets (all files in the bundle, as an unzip of a download would leave them)"
for v in unsigned server local; do
  cp -R $v Q-$v; xattr -rw com.apple.quarantine "$(q)" Q-$v/App.app; xattr -w com.apple.quarantine "$(q)" Q-$v/launcher
  R "[Q-$v] attr: $(xattr -l Q-$v/launcher | head -1 | cut -c1-70)"
  R "[Q-$v] exec from a shell, bundle launcher: exit $(to 60 ./Q-$v/App.app/Contents/MacOS/launcher >/dev/null 2>&1; echo $?)"
  R "[Q-$v] spctl --assess --type execute: $(spctl --assess --type execute -vvv Q-$v/App.app 2>&1 | head -2 | tr '\n' ' ')"
  R "[Q-$v] open -W with a 25 s limit (Launch Services; blocks if Gatekeeper shows a dialog): exit $(to 25 open -W Q-$v/App.app >/dev/null 2>&1; echo $?)  (142 = timed out)"
done
echo "##### the bytes: is the server's embedded signature the same kind as the Mac's own?"
for v in server local; do R "[$v] $(codesign -dvvv $v/launcher 2>&1 | grep -E 'CodeDirectory|Hash type|Signature size|Page size|Format' | tr '\n' '|' | cut -c1-300)"; done
R "[server] size unsigned $(stat -f %z unsigned/launcher) signed-by-server $(stat -f %z server/launcher) signed-by-codesign $(stat -f %z local/launcher)"
R "[server] the game file inside the bundle is byte-identical to the unsigned one: $(cmp -s unsigned/App.app/Contents/Resources/game.com server/App.app/Contents/Resources/game.com && echo yes || echo NO)"
