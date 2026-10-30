#!/bin/sh
# usage: build_wasm.sh WASI_SDK_DIR OUT_DIR  -- the wasm variants of shootout.c used by the engine comparisons
S=$1; O=$2; mkdir -p "$O"
C="$S/bin/clang --target=wasm32-wasip1 -O3 -fno-math-errno shootout.c -lm"
cd "$(dirname "$0")"
$C -mno-simd128 -DSIMD=0 -o "$O/so-scalar.wasm"
$C -msimd128 -DSIMD=0 -o "$O/so-autovec.wasm"
$C -msimd128 -DSIMD=1 -o "$O/so-simd.wasm"
$C -msimd128 -DSIMD=1 -DUNROLL=2 -o "$O/so-simd-u2.wasm"
$C -msimd128 -DSIMD=1 -DUNROLL=4 -o "$O/so-simd-u4.wasm"
$C -msimd128 -DSIMD=1 -DVB=32 -o "$O/so-simd-vb32.wasm"
$C -msimd128 -DSIMD=1 -DVB=32 -DUNROLL=2 -o "$O/so-simd-vb32-u2.wasm"
$C -msimd128 -mrelaxed-simd -ffp-contract=fast -DSIMD=1 -o "$O/so-relaxed.wasm"
$C -msimd128 -mrelaxed-simd -ffp-contract=fast -DSIMD=1 -DUNROLL=2 -o "$O/so-relaxed-u2.wasm"
$S/bin/clang --target=wasm32 -O3 -msimd128 -nostdlib -Wl,--no-entry -Wl,--export-memory revec_test.c -o "$O/revec_test.wasm"
ls -la "$O" | awk '{print $5, $9}'
