## linux-arm64: wasm-aot run 41062880168, commit dbdc717137800e142e3bb47ab3ff2cf094dc4131
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
wasmedge compile: [33mUSAGE[0m | 	/home/runner/work/ci/ci/wedge/bin/wasmedge	compile [OPTIONS] [--] WASM WASM_SO |  | [33mOPTIONS[0m | 	[32m-h|--help[0m | 		Show this help message | 	[32m--dump[0m | 		Dump LLVM IR to `wasm.ll` and `wasm-opt.ll`. | 	[32m--interruptible[0m | 		Generate a interruptible binary | 	[32m--enable-instruction-count[0m | 		Enable generating code for counting Wasm instructions executed. | 	[32m--enable-gas-measuring[0m | 		Enable generating code for counting gas burned during execution. | 	[32m--enable-time-measuring[0m | 		Enable generating code for counting time during execution. | 	[32m--enable-all-statistics[0m | 		Enable generating code for all statistics options 
SMOKE FAIL wasmedge-aot-O3 scalar: rc=1 [2026-10-30 13:25:10.500] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-scalar.so"
SMOKE FAIL wasmedge-aot-O3 simd: rc=1 [2026-10-30 13:25:11.267] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-simd.so"
SMOKE FAIL wasmedge-aot-O3 simd-u2: rc=1 [2026-10-30 13:25:12.046] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-simd-u2.so"
SMOKE FAIL wasmedge-aot-O3 simd-vb32: rc=1 [2026-10-30 13:25:12.822] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-simd-vb32.so"
wasm2c scalar: ok, 553536 bytes of C
wasm2c autovec: ok, 591328 bytes of C
wasm2c simd: ok, 586962 bytes of C
wasm2c simd-u2: ok, 591553 bytes of C
wasm2c simd-vb32: ok, 592988 bytes of C
wasm2c relaxed: rc=1 wasm2c: unknown option '--enable-relaxed-simd'
Try '--help' for more information.
wasm2c relaxed-u2: rc=1 wasm2c: unknown option '--enable-relaxed-simd'
Try '--help' for more information.
30 runnable rows
### AOT routes linux-arm64 (ref = wasmtime simd): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 8.94 | 5.07 | 2.07 | 128.02 |
| wasmtime autovec | 2.28 | 5.08 | 1.11 | 128.05 |
| wasmtime simd | 2.05 | 4.04 | 0.58 | 128.09 |
| wasmtime simd-u2 | 2.27 | 4.02 | 0.58 | 127.98 |
| wasmtime simd-vb32 | 2.01 | 3.97 | 0.58 | 128.04 |
| wasmtime relaxed | 1.88 | 3.83 | 0.55 | 127.96 |
| wasmtime relaxed-u2 | 2.03 | 3.78 | 0.55 | 128.01 |
| wasmer-llvm scalar | 7.79 | 4.70 | 1.26 | 77.79 |
| wasmer-llvm simd | 2.12 | 4.55 | 0.54 | 78.80 |
| wasmer-llvm simd-u2 | 2.12 | 4.42 | 0.54 | 77.22 |
| wasmer-llvm simd-vb32 | 2.12 | 6.27 | 0.54 | 83.81 |
| wasmer-cranelift scalar | 8.94 | 5.03 | 2.06 | 143.29 |
| wasmer-cranelift simd | 2.04 | 4.03 | 0.59 | 143.53 |
| wasmer-cranelift simd-u2 | 2.27 | 4.00 | 0.58 | 143.42 |
| wasmer-cranelift simd-vb32 | 1.99 | 3.98 | 0.58 | 143.37 |
| wasmer-singlepass scalar | 185.01 | 95.20 | 15.73 | 272.87 |
| wasm2c scalar gcc host+oobelim | 1.91 | 4.22 | 0.43 | 75.67 |
| wasm2c scalar clang host+oobelim | 1.91 | 4.64 | 0.39 | 77.43 |
| wasm2c autovec gcc host+oobelim | 1.84 | 4.13 | 4.09 | 92.17 |
| wasm2c autovec clang host+oobelim | 1.83 | 4.64 | 0.54 | 77.35 |
| wasm2c simd gcc base | 2.22 | 5.13 | 0.40 | 75.75 |
| wasm2c simd gcc host | 2.22 | 5.11 | 0.40 | 76.37 |
| wasm2c simd gcc host+oobelim | 2.17 | 5.07 | 0.40 | 76.14 |
| wasm2c simd clang base | 2.05 | 4.01 | 0.82 | 78.38 |
| wasm2c simd clang host | 2.05 | 3.99 | 0.80 | 76.87 |
| wasm2c simd clang host+oobelim | 1.84 | 3.77 | 0.49 | 77.46 |
| wasm2c simd-u2 gcc host+oobelim | 1.82 | 4.05 | 0.40 | 75.22 |
| wasm2c simd-u2 clang host+oobelim | 1.83 | 3.74 | 0.49 | 77.64 |
| wasm2c simd-vb32 gcc host+oobelim | 2.11 | 4.10 | 0.40 | 76.03 |
| wasm2c simd-vb32 clang host+oobelim | 1.84 | 3.74 | 0.49 | 77.86 |

speed relative to `wasmtime simd` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 0.23 | 0.80 | 0.28 | 1.00 |
| wasmtime autovec | 0.90 | 0.80 | 0.53 | 1.00 |
| wasmtime simd | 1.00 | 1.00 | 1.00 | 1.00 |
| wasmtime simd-u2 | 0.90 | 1.00 | 1.00 | 1.00 |
| wasmtime simd-vb32 | 1.02 | 1.02 | 1.00 | 1.00 |
| wasmtime relaxed | 1.09 | 1.05 | 1.07 | 1.00 |
| wasmtime relaxed-u2 | 1.01 | 1.07 | 1.07 | 1.00 |
| wasmer-llvm scalar | 0.26 | 0.86 | 0.46 | 1.65 |
| wasmer-llvm simd | 0.97 | 0.89 | 1.07 | 1.63 |
| wasmer-llvm simd-u2 | 0.97 | 0.91 | 1.08 | 1.66 |
| wasmer-llvm simd-vb32 | 0.97 | 0.64 | 1.08 | 1.53 |
| wasmer-cranelift scalar | 0.23 | 0.80 | 0.28 | 0.89 |
| wasmer-cranelift simd | 1.00 | 1.00 | 0.99 | 0.89 |
| wasmer-cranelift simd-u2 | 0.90 | 1.01 | 1.01 | 0.89 |
| wasmer-cranelift simd-vb32 | 1.03 | 1.02 | 1.00 | 0.89 |
| wasmer-singlepass scalar | 0.01 | 0.04 | 0.04 | 0.47 |
| wasm2c scalar gcc host+oobelim | 1.08 | 0.96 | 1.37 | 1.69 |
| wasm2c scalar clang host+oobelim | 1.07 | 0.87 | 1.51 | 1.65 |
| wasm2c autovec gcc host+oobelim | 1.11 | 0.98 | 0.14 | 1.39 |
| wasm2c autovec clang host+oobelim | 1.12 | 0.87 | 1.09 | 1.66 |
| wasm2c simd gcc base | 0.93 | 0.79 | 1.47 | 1.69 |
| wasm2c simd gcc host | 0.92 | 0.79 | 1.48 | 1.68 |
| wasm2c simd gcc host+oobelim | 0.94 | 0.80 | 1.46 | 1.68 |
| wasm2c simd clang base | 1.00 | 1.01 | 0.71 | 1.63 |
| wasm2c simd clang host | 1.00 | 1.01 | 0.73 | 1.67 |
| wasm2c simd clang host+oobelim | 1.12 | 1.07 | 1.19 | 1.65 |
| wasm2c simd-u2 gcc host+oobelim | 1.13 | 1.00 | 1.47 | 1.70 |
| wasm2c simd-u2 clang host+oobelim | 1.12 | 1.08 | 1.19 | 1.65 |
| wasm2c simd-vb32 gcc host+oobelim | 0.97 | 0.98 | 1.47 | 1.68 |
| wasm2c simd-vb32 clang host+oobelim | 1.12 | 1.08 | 1.19 | 1.65 |

