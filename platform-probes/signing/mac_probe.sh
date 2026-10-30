#!/bin/bash
# macOS: what signing structures can a Cosmopolitan fat executable have, and what do codesign / spctl / Launch Services / hardened runtime say about each?
# cwd = repository root; out/app.com is the unsigned fat file (with a zip asset). Everything is measured on the runner; notarization itself needs an Apple Developer account and cannot run here.
set +e
R() { echo "RESULT $*"; }
firstlines() { head -n "${1:-3}" | tr '\n' '|' | cut -c1-${2:-300}; }
guard() { local s=$1; shift; "$@" & local p=$!; ( sleep $s; kill -9 $p 2>/dev/null ) & local w=$!; wait $p 2>/dev/null; local rc=$?; kill $w 2>/dev/null; return $rc; }
sw_vers | tr '\n\t' '  ' | sed 's/^/RESULT host: /'; echo; R "arch $(uname -m); Xcode CLT: $(xcode-select -p 2>&1)"
mkdir -p mac && cd mac && cp ../out/app.com app.com && chmod +x app.com

echo "##### 1. ad-hoc signature on the bare fat file"
R "file(1): $(file app.com | cut -c1-150)"
R "lipo -info: $(lipo -info app.com 2>&1 | head -1 | cut -c1-150)"
R "otool -hv: $(otool -hv app.com 2>&1 | head -2 | tr '\n' '|' | cut -c1-150)"
h0=$(shasum -a 256 app.com | cut -d' ' -f1)
R "codesign --force -s -: $(codesign --force -s - app.com 2>&1 | firstlines 2) exit $?"
h1=$(shasum -a 256 app.com | cut -d' ' -f1); R "file bytes changed by codesign: $([ $h0 = $h1 ] && echo NO || echo YES)"
R "codesign -dvvv: $(codesign -dvvv app.com 2>&1 | grep -E 'Format|Signature|CodeDirectory|flags' | tr '\n' '|' | cut -c1-300)"
R "signature stored in extended attributes: $(xattr app.com | tr '\n' ' ')"
R "codesign --verify --strict: $(codesign --verify --strict -vvv app.com 2>&1 | firstlines 2) (exit $?)"
R "run after signing: $(./app.com 2>&1 | tr '\n' ' ')"
cp -X app.com copy-noxattr.com; R "copy without extended attributes (what a zip/tar/HTTP transfer does): $(codesign --verify --strict -vvv copy-noxattr.com 2>&1 | firstlines 1)"
zip -q t.zip app.com && mkdir -p unz && unzip -q -o t.zip -d unz; R "after zip+unzip: $(codesign --verify -vvv unz/app.com 2>&1 | firstlines 1)"
cp ../out/app.com fresh.com; chmod +x fresh.com

echo "##### 2. what runs on arm64 macOS: the shell stub builds the Ape loader with cc and executes it"
rm -f "${TMPDIR:-$HOME}"/.ape-1.10*; R "fresh file runs: $(./fresh.com 2>&1 | tr '\n' ' ')"
L="${TMPDIR:-$HOME}/.ape-1.10"; R "loader left behind: $(ls -la "$L"* 2>&1 | tr '\n' '|' | cut -c1-200)"
R "loader file(1): $(file "$L" | cut -c1-120)"; R "loader signature: $(codesign -dvvv "$L" 2>&1 | grep -E 'Format|Signature|flags|Identifier' | tr '\n' '|' | cut -c1-250)"
cp "$L" ape-loader
R "without cc (PATH has no compiler): $(env -i PATH=/usr/bin:/bin TMPDIR=$PWD/notmp HOME=$PWD/nohome /bin/sh -c 'mkdir -p notmp nohome; xcode-select -p >/dev/null 2>&1; ./fresh.com' 2>&1 | head -2 | tr '\n' ' ') (cc is Apple's /usr/bin/cc shim; on a Mac without Command Line Tools it opens the Xcode install dialog)"

echo "##### 3. hardened runtime on the loader: which entitlement does executing the embedded arm64 code need?"
cat > e-none.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>
EOF
ent() { f=$1; shift; printf '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>' > $f; for k in "$@"; do printf '<key>com.apple.security.cs.%s</key><true/>' $k >> $f; done; printf '</dict></plist>' >> $f; }
ent e-jit.plist allow-jit; ent e-unsigned.plist allow-unsigned-executable-memory; ent e-both.plist allow-jit allow-unsigned-executable-memory; ent e-noprot.plist disable-executable-page-protection; ent e-libval.plist disable-library-validation
for v in plain none jit unsigned both noprot libval; do
  cp ape-loader ape-$v
  if [ $v = plain ]; then codesign --force -s - ape-$v 2>/dev/null; label="ad-hoc, NO hardened runtime"
  else codesign --force -s - --options runtime --entitlements e-$v.plist ape-$v 2>/dev/null; label="hardened runtime, entitlements: $v"; fi
  ./ape-$v ./fresh.com > lo.txt 2>&1; rc=$?; R "loader $label -> exit $rc: $(tr '\n' ' ' < lo.txt | cut -c1-160)"
done
R "loader flags check: $(codesign -dvvv ape-none 2>&1 | grep -E 'flags|Runtime' | tr '\n' '|')"

echo "##### 4. test identity (self-signed code-signing certificate in a temporary keychain, trusted for code signing on this runner only)"
cat > id.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Test Developer ID (CI only)
[ext]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout id.key -out id.pem -days 3 -config id.cnf 2>/dev/null
openssl pkcs12 -export -inkey id.key -in id.pem -out id.p12 -passout pass:pw -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null || openssl pkcs12 -export -inkey id.key -in id.pem -out id.p12 -passout pass:pw
KC=$PWD/ci.keychain-db; security create-keychain -p pw $KC; security set-keychain-settings -lut 7200 $KC; security unlock-keychain -p pw $KC
security import id.p12 -k $KC -P pw -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k pw $KC >/dev/null 2>&1
security list-keychains -d user -s $KC $(security list-keychains -d user | tr -d '"') 
R "trust for code signing: $(sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain id.pem 2>&1 | firstlines 2) exit $?"
R "identities: $(security find-identity -v -p codesigning | tr '\n' '|' | cut -c1-250)"
ID="Test Developer ID (CI only)"
signit() { # path, extra args...
  local p=$1; shift
  codesign --force --timestamp "$@" -s "$ID" "$p" 2>/tmp/cs.err || { R "(secure timestamp unavailable: $(head -1 /tmp/cs.err | cut -c1-120)); signing without it"; codesign --force --timestamp=none "$@" -s "$ID" "$p"; }
}
mkbundle() { # name loader-entitlements-file
  local b=$1.app; rm -rf $b; mkdir -p $b/Contents/MacOS $b/Contents/Resources
  cc -O2 -o $b/Contents/MacOS/$1 launcher.c; cp ape-loader $b/Contents/MacOS/ape-loader; cp ../out/app.com $b/Contents/Resources/app.com
  cat > $b/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$1</string><key>CFBundleIdentifier</key><string>ci.test.$1</string><key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>11.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
EOF
}
cat > launcher.c <<'EOF'
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <libgen.h>
#include <limits.h>
int main(int argc, char **argv) {
  char exe[PATH_MAX], real[PATH_MAX]; uint32_t n = sizeof exe;
  if (_NSGetExecutablePath(exe, &n) || !realpath(exe, real)) return 111;
  char *dir = dirname(real), ape[PATH_MAX], app[PATH_MAX];
  snprintf(ape, sizeof ape, "%s/ape-loader", dir); snprintf(app, sizeof app, "%s/../Resources/app.com", dir);
  char **a = calloc(argc + 2, sizeof *a); a[0] = ape; a[1] = app; for (int i = 1; i < argc; i++) a[i + 1] = argv[i];
  execv(ape, a); perror("execv"); return 113;
}
EOF
launch() { # bundle -> run through Launch Services, output to files
  local b=$1; rm -f lo.txt le.txt; guard 40 open -W -n --stdout $PWD/lo.txt --stderr $PWD/le.txt $b; local rc=$?
  echo "open rc=$rc stdout=[$(tr '\n' ' ' < lo.txt 2>/dev/null)] stderr=[$(head -c 200 le.txt 2>/dev/null | tr '\n' ' ')]"
}
report() { # bundle label
  local b=$1.app
  R "[$2] codesign --verify --deep --strict: $(codesign --verify --deep --strict --verbose=4 $b 2>&1 | firstlines 3) (exit $?)"
  R "[$2] codesign -dvvv: $(codesign -dvvv $b 2>&1 | grep -E 'Authority|flags|Timestamp|TeamIdentifier|Format|Signature=' | tr '\n' '|' | cut -c1-330)"
  R "[$2] spctl --assess --type execute: $(spctl --assess --type execute -vvv $b 2>&1 | firstlines 2)"
  R "[$2] direct exec of Contents/MacOS: $($b/Contents/MacOS/$1 2>&1 | tr '\n' ' ' | cut -c1-160)"
  R "[$2] Launch Services (open): $(launch $b)"
}

echo "##### 5. bundle A: the APE itself as CFBundleExecutable (what a naive .app would be)"
mkdir -p A.app/Contents/MacOS; cp ../out/app.com A.app/Contents/MacOS/A; chmod +x A.app/Contents/MacOS/A
cat > A.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>A</string><key>CFBundleIdentifier</key><string>ci.test.A</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleName</key><string>A</string><key>CFBundleVersion</key><string>1</string></dict></plist>
EOF
cat > spawn.c <<'EOF'
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
extern char **environ;
int main(int c, char **v) { pid_t p; int e = posix_spawn(&p, v[1], 0, 0, v + 1, environ); printf("posix_spawn(%s): %s (%d)\n", v[1], e ? strerror(e) : "ok", e); return 0; }
EOF
cc -o spawn spawn.c; R "[A] posix_spawn of the APE (what Launch Services does; no shell fallback): $(./spawn $PWD/A.app/Contents/MacOS/A 2>&1)"
codesign --force -s - A.app 2>&1 | head -2; report A "A: ad-hoc"

echo "##### 6. bundle B: real Mach-O launcher + Ape loader + APE as resource"
for v in none unsigned jit both; do
  name=B$v; mkbundle $name
  signit $name.app/Contents/MacOS/ape-loader --options runtime --entitlements e-$v.plist
  signit $name.app/Contents/MacOS/$name --options runtime
  signit $name.app --options runtime
  report $name "B: Developer-ID-style, hardened runtime, loader entitlement=$v"
done
R "[B unsigned] nested sign order + entitlements of the loader: $(codesign -d --entitlements :- Bunsigned.app/Contents/MacOS/ape-loader 2>&1 | tr -d '\n' | cut -c1-300)"
R "[B] syspolicy_check distribution: $(syspolicy_check distribution Bunsigned.app 2>&1 | head -12 | tr '\n' '|' | cut -c1-900)"

echo "##### 7. quarantine"
cp -R Bunsigned.app Q.app; xattr -w com.apple.quarantine "0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)" Q.app; xattr -rw com.apple.quarantine "0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)" Q.app 2>/dev/null
R "[Q] quarantined copy: $(xattr -l Q.app | head -1 | cut -c1-80); spctl: $(spctl --assess --type execute -vvv Q.app 2>&1 | firstlines 2)"
R "[Q] Launch Services on the quarantined, self-signed bundle: $(launch Q.app)"
R "[Q] the bare APE with quarantine (shell fallback; no assessment is made of scripts): $(cp ../out/app.com q.com; chmod +x q.com; xattr -w com.apple.quarantine "0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)" q.com; ./q.com 2>&1 | tr '\n' ' ')"
python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 & HS=$!; sleep 1
curl -s -o dl-curl.com http://127.0.0.1:8765/app.com; python3 -c "import urllib.request as u; u.urlretrieve('http://127.0.0.1:8765/app.com','dl-urllib.com')"; kill $HS 2>/dev/null
R "[no quarantine] file fetched by curl: xattrs=[$(xattr dl-curl.com | tr '\n' ' ')]; by python urllib: xattrs=[$(xattr dl-urllib.com | tr '\n' ' ')]; copy with cp of a quarantined file keeps it: [$(xattr q.com; cp q.com q2.com; xattr q2.com | tr '\n' ' ')]"

echo "##### 8. notarization tooling, offline"
R "notarytool: $(xcrun notarytool --version 2>&1 | head -1); stapler: $(xcrun --find stapler 2>&1 | tail -1); altool: $(xcrun --find altool 2>&1 | tail -1)"
ditto -c -k --keepParent Bunsigned.app B.zip; R "notarytool submit without credentials: $(xcrun notarytool submit B.zip --keychain-profile no-such-profile 2>&1 | head -3 | tr '\n' '|' | cut -c1-300)"
R "stapler validate on the unnotarized bundle: $(xcrun stapler validate Bunsigned.app 2>&1 | head -3 | tr '\n' '|' | cut -c1-200)"
hdiutil create -quiet -volname T -srcfolder Bunsigned.app -ov B.dmg; R "dmg: $(ls -la B.dmg | awk '{print $5}') bytes; codesign dmg: $(codesign --force --timestamp=none -s "$ID" B.dmg 2>&1 | head -1); verify: $(codesign --verify -vvv B.dmg 2>&1 | head -2 | tr '\n' ' ')"
echo "=== SUMMARY ==="
