#!/bin/sh
# Compile with the clang that ships in cosmocc (libexec/clang) using the flags the Cosmopolitan cross driver would pass to GCC, so a CMake build can swap compilers.
# usage: clang-wrap.sh <x86_64|aarch64> <cc|c++> <compiler arguments...>      Linking and preprocessing go to the normal cross driver unchanged.
ARCH=$1; KIND=$2; shift 2
COSMO=${COSMO:-$HOME/cosmo}
case " $* " in *" -c "*) ;; *) exec "$COSMO/bin/$ARCH-unknown-cosmo-$KIND" "$@";; esac
# Not usable for the x86-64 half: with this wrapper the D3D12 backend built, but D3D12 on Windows failed its compute check (measured, dawn-cosmo run with compiler=clang), and compiling only the
# Direct3D sources with GCC did not link (undefined BindGroupBase constructor between the GCC and clang objects). The arm64 half has no D3D12 backend and uses this wrapper (dawn-cosmo, compiler=auto).
case $ARCH in
  x86_64)  AF="--target=x86_64 -mno-tls-direct-seg-refs -fpatchable-function-entry=18,16 -mno-red-zone" ;;
  aarch64) AF="--target=aarch64 -ffixed-x18 -ffixed-x28 -fpatchable-function-entry=7,6 -fsigned-char" ;;
esac
LX=; [ "$KIND" = c++ ] && LX="-isystem $COSMO/include/third_party/libcxx"
out=; prev=; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
"$COSMO/libexec/clang" $AF -D__COSMOPOLITAN__ -D__COSMOCC__ -include libc/integral/normalize.inc -fno-semantic-interposition $LX -fno-pie -nostdinc -isystem "$COSMO/include" -fno-omit-frame-pointer -Wno-error -Wno-unknown-warning-option "$@" || exit $?
[ -n "$out" ] && [ -f "$out" ] && "$COSMO/bin/fixupobj" "$out"
exit 0
