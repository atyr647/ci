## linux-arm64: wasm-aot run 41061972390, commit 42503673eda60ca538f48c0d86727cb1da02b172
asimd sve sve2 
wasmer: wasmer 7.5.0 |       --target <TARGET_TRIPLE> |           Compilation Target triple |   -s, --singlepass |           Use Singlepass compiler |   -c, --cranelift |           Use Cranelift compiler |   -l, --llvm |           Use LLVM compiler |       --enable-verifier |           Enable compiler internal verification. |           Available for Cranelift (enabled always for LLVM). |           Available for Cranelift, LLVM and Singlepass. |           Enable a profiler. |           Available for Cranelift, LLVM and Singlepass.
wasmer compile --singlepass simd: rc=1 
Target: aarch64-unknown-linux-gnu
error: failed to compile `so/so-simd.wasm`
╰─▶ 1: Compilation error: not yet implemented: V128Const { value: V128([0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
wasmer compile --singlepass simd-u2: rc=1 rget: aarch64-unknown-linux-gnu
error: failed to compile `so/so-simd-u2.wasm`
╰─▶ 1: Compilation error: not yet implemented: V128Const { value: V128([0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
wasmer compile --singlepass simd-vb32: rc=1 et: aarch64-unknown-linux-gnu
error: failed to compile `so/so-simd-vb32.wasm`
╰─▶ 1: Compilation error: not yet implemented: V128Const { value: V128([0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
wasmedge compile: /bin/sh: 1: /home/runner/work/ci/ci/wedge/bin/wasmedge: not found
wasmedge compile O3 scalar: rc=127 /bin/sh: 1: /home/runner/work/ci/ci/wedge/bin/wasmedge: not found
wasmedge compile O3 simd: rc=127 /bin/sh: 1: /home/runner/work/ci/ci/wedge/bin/wasmedge: not found
wasmedge compile O3 simd-u2: rc=127 /bin/sh: 1: /home/runner/work/ci/ci/wedge/bin/wasmedge: not found
wasmedge compile O3 simd-vb32: rc=127 /bin/sh: 1: /home/runner/work/ci/ci/wedge/bin/wasmedge: not found
wasm2c scalar: ok, 553536 bytes of C
wasm2c autovec: ok, 591328 bytes of C
wasm2c simd: ok, 586962 bytes of C
wasm2c simd-u2: ok, 591553 bytes of C
wasm2c simd-vb32: ok, 592988 bytes of C
29 runnable rows
### AOT routes linux-arm64 (ref = wasmtime simd): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 8.94 | 5.07 | 2.07 | 128.13 |
| wasmtime autovec | 2.28 | 5.07 | 1.11 | 128.00 |
| wasmtime simd | 2.05 | 4.04 | 0.58 | 128.16 |
| wasmtime simd-u2 | 2.27 | 4.02 | 0.58 | 127.99 |
| wasmtime simd-vb32 | 2.01 | 3.97 | 0.58 | 127.94 |
| wasmtime relaxed | 1.88 | 3.83 | 0.55 | 128.02 |
| wasmer-llvm scalar | 7.79 | 4.70 | 1.27 | 77.91 |
| wasmer-llvm simd | 2.12 | 4.55 | 0.54 | 78.44 |
| wasmer-llvm simd-u2 | 2.12 | 4.43 | 0.54 | 76.73 |
| wasmer-llvm simd-vb32 | 2.12 | 6.27 | 0.54 | 83.71 |
| wasmer-cranelift scalar | 8.94 | 5.04 | 2.07 | 143.31 |
| wasmer-cranelift simd | 2.05 | 4.03 | 0.58 | 143.56 |
| wasmer-cranelift simd-u2 | 2.27 | 4.00 | 0.58 | 143.39 |
| wasmer-cranelift simd-vb32 | 1.99 | 3.98 | 0.58 | 143.35 |
| wasmer-singlepass scalar | 185.03 | 95.22 | 15.72 | 273.17 |
| wasm2c scalar gcc host+oobelim | 1.91 | 4.22 | 0.43 | 75.22 |
| wasm2c scalar clang host+oobelim | 2.02 | 5.68 | 0.49 | 77.30 |
| wasm2c autovec gcc host+oobelim | 1.84 | 4.13 | 4.10 | 92.27 |
| wasm2c autovec clang host+oobelim | 1.98 | 5.68 | 0.62 | 77.54 |
| wasm2c simd gcc base | 2.21 | 5.13 | 0.40 | 75.89 |
| wasm2c simd gcc host | 2.22 | 5.11 | 0.40 | 76.19 |
| wasm2c simd gcc host+oobelim | 2.17 | 5.07 | 0.40 | 76.31 |
| wasm2c simd clang base | 2.05 | 4.01 | 0.82 | 78.79 |
| wasm2c simd clang host | 2.05 | 3.99 | 0.79 | 76.60 |
| wasm2c simd clang host+oobelim | 1.98 | 4.00 | 0.55 | 77.32 |
| wasm2c simd-u2 gcc host+oobelim | 1.82 | 4.05 | 0.40 | 75.73 |
| wasm2c simd-u2 clang host+oobelim | 1.98 | 4.05 | 0.54 | 77.64 |
| wasm2c simd-vb32 gcc host+oobelim | 2.10 | 4.10 | 0.40 | 75.96 |
| wasm2c simd-vb32 clang host+oobelim | 1.98 | 4.08 | 0.54 | 77.61 |

speed relative to `wasmtime simd` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 0.23 | 0.80 | 0.28 | 1.00 |
| wasmtime autovec | 0.90 | 0.80 | 0.53 | 1.00 |
| wasmtime simd | 1.00 | 1.00 | 1.00 | 1.00 |
| wasmtime simd-u2 | 0.90 | 1.00 | 1.00 | 1.00 |
| wasmtime simd-vb32 | 1.02 | 1.02 | 1.00 | 1.00 |
| wasmtime relaxed | 1.09 | 1.05 | 1.07 | 1.00 |
| wasmer-llvm scalar | 0.26 | 0.86 | 0.46 | 1.64 |
| wasmer-llvm simd | 0.97 | 0.89 | 1.07 | 1.63 |
| wasmer-llvm simd-u2 | 0.97 | 0.91 | 1.08 | 1.67 |
| wasmer-llvm simd-vb32 | 0.97 | 0.64 | 1.07 | 1.53 |
| wasmer-cranelift scalar | 0.23 | 0.80 | 0.28 | 0.89 |
| wasmer-cranelift simd | 1.00 | 1.00 | 1.00 | 0.89 |
| wasmer-cranelift simd-u2 | 0.90 | 1.01 | 1.00 | 0.89 |
| wasmer-cranelift simd-vb32 | 1.03 | 1.02 | 1.00 | 0.89 |
| wasmer-singlepass scalar | 0.01 | 0.04 | 0.04 | 0.47 |
| wasm2c scalar gcc host+oobelim | 1.08 | 0.96 | 1.36 | 1.70 |
| wasm2c scalar clang host+oobelim | 1.02 | 0.71 | 1.18 | 1.66 |
| wasm2c autovec gcc host+oobelim | 1.11 | 0.98 | 0.14 | 1.39 |
| wasm2c autovec clang host+oobelim | 1.04 | 0.71 | 0.94 | 1.65 |
| wasm2c simd gcc base | 0.93 | 0.79 | 1.47 | 1.69 |
| wasm2c simd gcc host | 0.92 | 0.79 | 1.46 | 1.68 |
| wasm2c simd gcc host+oobelim | 0.94 | 0.80 | 1.45 | 1.68 |
| wasm2c simd clang base | 1.00 | 1.01 | 0.71 | 1.63 |
| wasm2c simd clang host | 1.00 | 1.01 | 0.74 | 1.67 |
| wasm2c simd clang host+oobelim | 1.04 | 1.01 | 1.07 | 1.66 |
| wasm2c simd-u2 gcc host+oobelim | 1.13 | 1.00 | 1.48 | 1.69 |
| wasm2c simd-u2 clang host+oobelim | 1.04 | 1.00 | 1.08 | 1.65 |
| wasm2c simd-vb32 gcc host+oobelim | 0.97 | 0.99 | 1.47 | 1.69 |
| wasm2c simd-vb32 clang host+oobelim | 1.04 | 0.99 | 1.07 | 1.65 |

