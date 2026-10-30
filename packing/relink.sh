#!/usr/bin/env bash
# Relinks the test program against the Dawn libraries of an earlier dawn-cosmo run in several ways (nothing of Dawn is recompiled): the exact original link (map file for the
# inventory), with and without --gc-sections, and "per-OS" links in which a backend's connector is replaced by a stub so its objects are never pulled out of the archive.
# cwd = repo root with: lib-x86_64/ lib-aarch64/ metal/ cosmo/ pin/ (the sources of the dawn-cosmo run's commit)
set -euo pipefail
B=$PWD/cosmo/bin; P=$PWD/pin
export PATH=$B:$PATH
mkdir -p work parts maps out
echo "== cosmocc bin:"; ls $B | tr '\n' ' '; echo
for A in x86_64 aarch64; do
  python3 -I packing/ar_unique.py lib-$A/libwebgpu_dawn.a work/o-$A
  rm -f work/libdawn-$A.a; $B/$A-linux-cosmo-ar crs work/libdawn-$A.a work/o-$A/*.o
  L=$PWD/lib-$A; INC="-I$L/inc1 -I$L/inc2 -I$P/ci-webgpu-test"
  $B/$A-unknown-cosmo-c++ -O2 -std=c++17 -c $P/alloc-probe/tcache_new.cpp -o work/tcache.$A.o
  $B/$A-unknown-cosmo-cc -O2 $INC -c $P/ci-webgpu-test/wgt.c -o work/wgt.$A.o
  [ $A = aarch64 ] && $B/aarch64-unknown-cosmo-cc -O2 -c metal/objc_shim.c -o work/objc_shim.o
  if [ $A = x86_64 ]; then BK="d3d12 vulkan null"; else BK="vulkan null"; fi
  for b in $BK; do python3 -I packing/gen_stubs.py $A work/o-$A work/stub_$b.$A.c $b && $B/$A-unknown-cosmo-cc -O2 -c work/stub_$b.$A.c -o work/stub_$b.$A.o; done
done

link() {   # name arch "stub objects" [extra linker flags...]    (NOMETAL=1 leaves the Metal objects out)
  local name=$1 A=$2 stubs=$3; shift 3
  local extra="work/tcache.$A.o"
  if [ $A = aarch64 ] && [ -z "${NOMETAL:-}" ]; then extra="$extra $(ls $PWD/metal/objs/*.o) work/objc_shim.o"; fi
  $B/$A-unknown-cosmo-c++ -O2 work/wgt.$A.o $extra $stubs "$@" work/libdawn-$A.a -Wl,--wrap=pthread_create -Wl,-Map=maps/$name.$A.map -o parts/$name.$A.com
}
S() { local A=$1; shift; local r=""; for b in "$@"; do r="$r work/stub_$b.$A.o"; done; echo $r; }

link base   x86_64 ""
link nogc   x86_64 "" -Wl,--no-gc-sections
link gc     x86_64 "" -Wl,--gc-sections
link nonull x86_64 "$(S x86_64 null)"
link lnx    x86_64 "$(S x86_64 d3d12 null)"
link win    x86_64 "$(S x86_64 vulkan null)"
link base   aarch64 ""
link nogc   aarch64 "" -Wl,--no-gc-sections
link gc     aarch64 "" -Wl,--gc-sections
link nonull aarch64 "$(S aarch64 null)"
NOMETAL=1 link lnx aarch64 "$(S aarch64 null)"
link mac    aarch64 "$(S aarch64 vulkan null)"
echo "== linked halves"; ls -l parts | awk '{print $5, $9}'

$B/cosmocc -O2 packing/hello.c -o out/hello.com
AL="-l $B/ape-x86_64.elf -l $B/ape-aarch64.elf"; M1="-M $B/ape-m1.c"
fat() { local out=$1; shift; $B/apelink -V -1 "$@" -o out/$out; }
fat all.com        $AL $M1 parts/base.x86_64.com.dbg parts/base.aarch64.com.dbg
fat nom1.com       $AL     parts/base.x86_64.com.dbg parts/base.aarch64.com.dbg
fat x64only.com    -l $B/ape-x86_64.elf parts/base.x86_64.com.dbg
fat arm64only.com  -l $B/ape-aarch64.elf $M1 parts/base.aarch64.com.dbg
fat gc.com         $AL $M1 parts/gc.x86_64.com.dbg parts/gc.aarch64.com.dbg
fat nonull.com     $AL $M1 parts/nonull.x86_64.com.dbg parts/nonull.aarch64.com.dbg
fat lnx.com        $AL     parts/lnx.x86_64.com.dbg parts/lnx.aarch64.com.dbg
fat win.com        -l $B/ape-x86_64.elf parts/win.x86_64.com.dbg
fat mac.com        -l $B/ape-aarch64.elf $M1 parts/mac.aarch64.com.dbg
echo "== file sizes"; ls -l out parts | awk '{print $5, $9}'
echo "== original artifact vs relink"; ls -l wgt-dawn/wgt-dawn.com | awk '{print $5}'; cmp wgt-dawn/wgt-dawn.com out/all.com && echo "IDENTICAL to the dawn-cosmo artifact" || echo "differs from the dawn-cosmo artifact"
