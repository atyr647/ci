#!/bin/bash
# Builds every guest of the coverage run and precompiles it with the official Wasmtime CLI. Runs on ubuntu-latest in CI (not meant for a developer machine: it downloads tools).
# env: WT (wasmtime version), FLAGS_FULL (feature switches matching the full runtime), FLAGS_BASE (matching the base runtime), GH_TOKEN
set +e
cd "$(dirname "$0")/../.."          # wasmtime-nostd/
ROOT=$PWD; REPO=$(cd .. && pwd)
mkdir -p $ROOT/work/wasm $ROOT/work/out $ROOT/work/dl; cd $ROOT/work
: "${WT:=v50.0.0}"
curl -fsSL https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz | tar xz
S=$(ls -d $PWD/wasi-sdk-34*)
curl -fsSL -o wt.tar.xz https://github.com/bytecodealliance/wasmtime/releases/download/$WT/wasmtime-$WT-x86_64-linux.tar.xz && mkdir -p wt && tar xJf wt.tar.xz -C wt
W=$(find wt -name wasmtime -type f | head -1); $W --version | tee versions.txt
gh release download -R bytecodealliance/wasm-tools -p '*x86_64-linux.tar.gz' -D dl --clobber && (cd dl && for f in wasm-tools*.tar.gz; do tar xzf $f; done)
WTOOLS=$(find dl -name wasm-tools -type f | head -1); $WTOOLS --version | tee -a versions.txt
gh release download -R WebAssembly/binaryen -p 'binaryen-*-x86_64-linux.tar.gz' -D dl --clobber && (cd dl && for f in binaryen*.tar.gz; do tar xzf $f; done)
WOPT=$(find dl -name wasm-opt -type f | head -1); $WOPT --version | tee -a versions.txt
echo "== CLI options mentioning gc / collector / threads / exceptions"; $W compile -W help 2>&1 | grep -i "gc\|collector\|thread\|exception\|component" ; $W compile -O help 2>&1 | grep -i "collector\|gc"
echo "wasi-sdk 34 clang: $($S/bin/clang --version | head -1)" | tee -a versions.txt
G=$REPO/wasmtime-nostd/coverage/guest

# ---- core feature modules from text ----
for t in gc eh mem relaxed atomics shared yield; do $WTOOLS parse $G/$t.wat -o wasm/$t.wasm || echo "WAT-PARSE-FAIL $t" >> compile.log; done
# ---- C / C++ guests ----
$S/bin/clang --target=wasm32-wasip1 -O2 $G/wasitest.c -o wasm/wasitest.wasm 2>&1 | tail -20
$S/bin/clang --target=wasm32-wasip2 -O2 $G/wasitest.c -o wasm/wasitest.p2.wasm 2>&1 | tail -20
$S/bin/clang --target=wasm32-wasip1 -O3 -mno-simd128 -DSIMD=0 $REPO/wasm-perf/shootout.c -o wasm/so-scalar.wasm -lm 2>&1 | tail -5
$S/bin/clang++ --target=wasm32-wasip1 -std=c++20 -O2 -fno-exceptions -fno-rtti -mexec-model=reactor -Wl,--no-entry $G/coro.cpp -o wasm/coro.wasm 2>&1 | tail -20
for d in 0 50; do
  $S/bin/clang --target=wasm32 -nostdlib -O2 -DDEPTH=$d -Wl,--no-entry $G/asy.c -o wasm/asy-d$d.wasm 2>&1 | tail -5
  $WOPT -all -O2 --asyncify --pass-arg=asyncify-imports@env.await_host wasm/asy-d$d.wasm -o wasm/asy-d$d-opt.wasm 2>&1 | tail -5
done
ls -la wasm

# ---- precompile ----
compile() {   # <wasm> <outname> <flags...>
  local in=$1 out=$2; shift 2
  local a sb mode e
  for a in x86_64 aarch64; do for sb in y n; do mode=sig; [ $sb = n ] && mode=nosig
    e=$($W compile --target $a-unknown-linux-gnu "$@" -O signals-based-traps=$sb $in -o out/$out.$mode.$a.cwasm 2>&1) || { echo "COMPILE-FAIL $out $mode $a: $(echo "$e" | tr '\n' ' ' | cut -c1-300)" >> compile.log; }
  done; done
  e=$($W compile --target pulley64 "$@" $in -o out/$out.pulley.cwasm 2>&1) || echo "COMPILE-FAIL $out pulley: $(echo "$e" | tr '\n' ' ' | cut -c1-300)" >> compile.log
}
FULL="$FLAGS_FULL"; BASE="$FLAGS_BASE"
for t in gc eh mem relaxed yield wasitest so-scalar coro asy-d0 asy-d0-opt asy-d50 asy-d50-opt; do compile wasm/$t.wasm $t $FULL; done
compile wasm/wasitest.wasm b-wasitest $BASE
compile wasm/so-scalar.wasm b-so-scalar $BASE
# GC collectors and the threads proposal: compiled with the switch that the runtime does or does not have; the host reports what the loader says
compile wasm/gc.wasm gc-drc $FULL -O collector=drc
compile wasm/gc.wasm gc-null $FULL -O collector=null
compile wasm/gc.wasm gc-copying $FULL -O collector=copying
THR=$(echo "$FULL" | sed 's/-W threads=n/-W threads=y/')
compile wasm/atomics.wasm atomics-thr $THR
compile wasm/shared.wasm shared-thr $THR
# components (compiled when the full runtime has the component model)
if [ -n "$COMPONENTS" ]; then
  compile wasm/wasitest.p2.wasm wasitest.p2 $FULL
fi
echo "== compile.log"; cat compile.log 2>/dev/null
ls out | wc -l; du -sh out
