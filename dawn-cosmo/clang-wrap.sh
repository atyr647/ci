#!/bin/sh
# Compile with the clang that ships in cosmocc (libexec/clang) using the flags the Cosmopolitan cross driver would pass to GCC, so a CMake build can swap compilers.
# usage: clang-wrap.sh <x86_64|aarch64> <cc|c++> <compiler arguments...>      Linking and preprocessing go to the normal cross driver unchanged.
ARCH=$1; KIND=$2; shift 2
COSMO=${COSMO:-$HOME/cosmo}
case " $* " in *" -c "*) ;; *) exec "$COSMO/bin/$ARCH-unknown-cosmo-$KIND" "$@";; esac
# The Direct3D backend sources stay on the GCC driver: they call Windows COM interfaces through ms_abi, which was only made to work with GCC's calling-convention quirks (dawn-cosmo/fix_com_struct_returns.py);
# compiled by clang the same Dawn built fine but D3D12 on Windows failed its compute check (measured). Everything else, including Tint's HLSL writer, is compiled by clang.
for a in "$@"; do case "$a" in *.cpp|*.cc|*.c|*.mm) case "$a" in */native/d3d12/*|*/native/d3d11/*|*/native/d3d/*) exec "$COSMO/bin/$ARCH-unknown-cosmo-$KIND" "$@";; esac;; esac; done
case $ARCH in
  x86_64)  AF="--target=x86_64 -mno-tls-direct-seg-refs -fpatchable-function-entry=18,16 -mno-red-zone" ;;
  aarch64) AF="--target=aarch64 -ffixed-x18 -ffixed-x28 -fpatchable-function-entry=7,6 -fsigned-char" ;;
esac
LX=; [ "$KIND" = c++ ] && LX="-isystem $COSMO/include/third_party/libcxx"
out=; prev=; for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
"$COSMO/libexec/clang" $AF -D__COSMOPOLITAN__ -D__COSMOCC__ -include libc/integral/normalize.inc -fno-semantic-interposition $LX -fno-pie -nostdinc -isystem "$COSMO/include" -fno-omit-frame-pointer -Wno-error -Wno-unknown-warning-option "$@" || exit $?
[ -n "$out" ] && [ -f "$out" ] && "$COSMO/bin/fixupobj" "$out"
exit 0
