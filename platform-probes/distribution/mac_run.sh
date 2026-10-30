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
echo "##### control: Launch Services (open -W) on the same bundles WITHOUT the quarantine attribute"
for v in unsigned server local; do
  R "[$v] open -W, no quarantine, 25 s limit: exit $(to 25 open -W $v/App.app >/dev/null 2>&1; echo $?)  (142 = timed out)"
done
echo "##### is code-signing enforced on this runner at all? (an unsigned arm64 program ran above)"
R "csrutil: $(csrutil status 2>&1 | head -1)  nvram boot-args: $(nvram boot-args 2>&1 | head -1 | cut -c1-120)  sysctl security.mac.amfi: $(sysctl security.mac.amfi 2>&1 | head -3 | tr '\n' ' ' | cut -c1-200)"
R "hardware: $(sysctl -n machdep.cpu.brand_string 2>/dev/null) $(sysctl -n kern.hv_vmm_present 2>/dev/null) (kern.hv_vmm_present=1 means a virtual machine)"
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
echo "##### keeping the BARE file (no .app around the game): (A) a loader put where the stub looks for it, no compiler; (B) a one-time runner app that opens the file as a document"
# the stub (first lines of the file): ape in PATH, else ${TMPDIR:-${HOME:-.}}/.ape-1.10 if executable, else (arm64) it needs cc to build one
for v in server local; do
  H=$PWD/home-$v; rm -rf $H; mkdir -p $H; cp $v/App.app/Contents/MacOS/ape-loader $H/.ape-1.10; chmod +x $H/.ape-1.10
  cp unsigned/App.app/Contents/Resources/game.com $H/bare.com; chmod +x $H/bare.com
  R "[A-$v] loader signature: $(codesign -dvvv $H/.ape-1.10 2>&1 | grep -E 'Signature=|not signed' | head -1)"
  env -i HOME=$H PATH=/nonexistent /bin/sh -c "cd $H; /bin/sh ./bare.com" > $H/out1.txt 2>&1; rc=$?
  R "[A-$v] bare file, loader in place, PATH has no compiler (and no other tool): exit $rc :: $(tr '\n' ' ' < $H/out1.txt | cut -c1-160)"
  before=$(shasum -a 256 $H/.ape-1.10 | cut -c1-16)
  xattr -w com.apple.quarantine "$(q)" $H/bare.com
  env -i HOME=$H PATH=/nonexistent /bin/sh -c "cd $H; /bin/sh ./bare.com" > $H/out2.txt 2>&1; rc=$?
  R "[A-$v] same, bare file quarantined: exit $rc :: $(tr '\n' ' ' < $H/out2.txt | cut -c1-160); loader unchanged: $([ $before = $(shasum -a 256 $H/.ape-1.10 | cut -c1-16) ] && echo yes || echo NO)"
  # started like a user would from Terminal: the file itself as the command
  env -i HOME=$H PATH=/nonexistent /bin/zsh -c "cd $H; ./bare.com" > $H/out3.txt 2>&1; rc=$?
  R "[A-$v] zsh, ./bare.com (what typing the name in Terminal does): exit $rc :: $(tr '\n' ' ' < $H/out3.txt | cut -c1-160)"
done
if [ -d runner/Runner.app ]; then
  chmod -R u+rwX runner; chmod +x runner/Runner.app/Contents/MacOS/*
  codesign --force --deep -s - runner/Runner.app 2>&1 | head -1
  R "[B] runner signature: $(codesign -dvvv runner/Runner.app 2>&1 | grep -E 'Signature=|Format' | tr '\n' '|') verify: $(codesign --verify --deep --strict runner/Runner.app 2>&1 | head -1)"
  cp unsigned/App.app/Contents/Resources/game.com game.cosmo; chmod +x game.cosmo
  rm -f /tmp/runner-proof.txt
  R "[B0] runner binary started directly with the file as argument (no Launch Services, no quarantine), 30 s limit: exit $(to 30 $PWD/runner/Runner.app/Contents/MacOS/runner $PWD/game.cosmo >runner-direct.txt 2>&1; echo $?) :: $(head -c 200 runner-direct.txt | tr '\n' ' ') recorded: $(cat /tmp/runner-proof.txt 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
  rm -f /tmp/runner-proof.txt
  R "[B1] open -W -a Runner.app game.cosmo (document NOT quarantined), 40 s limit: exit $(to 40 open -W -a $PWD/runner/Runner.app $PWD/game.cosmo >open1.txt 2>&1; echo $?) :: $(head -c 200 open1.txt | tr '\n' ' ') recorded: $(cat /tmp/runner-proof.txt 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
  xattr -w com.apple.quarantine "$(q)" game.cosmo; rm -f /tmp/runner-proof.txt
  R "[B2] same, document QUARANTINED (a browser download), runner ad-hoc signed and not quarantined: exit $(to 40 open -W -a $PWD/runner/Runner.app $PWD/game.cosmo >open2.txt 2>&1; echo $?) :: $(head -c 200 open2.txt | tr '\n' ' ') recorded: $(cat /tmp/runner-proof.txt 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
  cp -R runner/Runner.app runner/RunnerQ.app; xattr -rw com.apple.quarantine "$(q)" runner/RunnerQ.app; rm -f /tmp/runner-proof.txt
  R "[B3] same with the RUNNER quarantined too (a browser-downloaded runner), 25 s limit: exit $(to 25 open -W -a $PWD/runner/RunnerQ.app $PWD/game.cosmo >open3.txt 2>&1; echo $?) :: $(head -c 200 open3.txt | tr '\n' ' ') recorded: $(cat /tmp/runner-proof.txt 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
fi
