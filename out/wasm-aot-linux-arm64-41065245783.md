## linux-arm64: wasm-aot run 41065245783, commit 23fb49f15687718bac06a97dfddddad81f7bdb2e
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
wasm2c scalar: ok, 553536 bytes of C
wasm2c autovec: ok, 591328 bytes of C
wasm2c simd: ok, 586962 bytes of C
wasm2c simd-u2: ok, 591553 bytes of C
wasm2c simd-vb32: ok, 592988 bytes of C
wasm2c relaxed: rc=1 error: wasm2c does not support the f32x4.relaxed_madd instruction
wasm2c relaxed-u2: rc=1 error: wasm2c does not support the f32x4.relaxed_madd instruction
34 runnable rows
### AOT routes linux-arm64 (ref = wasmtime simd): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 8.94 | 5.07 | 2.08 | 128.09 |
| wasmtime autovec | 2.28 | 5.08 | 1.11 | 127.97 |
| wasmtime simd | 2.05 | 4.04 | 0.58 | 128.00 |
| wasmtime simd-u2 | 2.28 | 4.02 | 0.58 | 128.02 |
| wasmtime simd-vb32 | 2.01 | 3.98 | 0.58 | 127.98 |
| wasmtime relaxed | 1.88 | 3.83 | 0.55 | 128.00 |
| wasmtime relaxed-u2 | 2.03 | 3.78 | 0.54 | 128.12 |
| wasmer-llvm scalar | 7.79 | 4.70 | 1.26 | 78.01 |
| wasmer-llvm simd | 2.12 | 4.55 | 0.55 | 78.60 |
| wasmer-llvm simd-u2 | 2.12 | 4.42 | 0.55 | 76.98 |
| wasmer-llvm simd-vb32 | 2.12 | 6.27 | 0.55 | 83.71 |
| wasmer-cranelift scalar | 8.94 | 5.04 | 2.07 | 143.37 |
| wasmer-cranelift simd | 2.05 | 4.03 | 0.58 | 143.52 |
| wasmer-cranelift simd-u2 | 2.27 | 4.00 | 0.58 | 143.35 |
| wasmer-cranelift simd-vb32 | 1.99 | 3.98 | 0.58 | 143.34 |
| wasmer-singlepass scalar | 185.03 | 95.21 | 15.74 | 272.73 |
| wasmedge-aot-O3 scalar | 917.73 | 189.22 | 69.38 | 8000.01 |
| wasmedge-aot-O3 simd | 243.90 | 100.41 | 27.52 | 8005.66 |
| wasmedge-aot-O3 simd-u2 | 233.67 | 86.22 | 27.53 | 8016.34 |
| wasmedge-aot-O3 simd-vb32 | 205.39 | 86.07 | 27.63 | 8010.82 |
| wasm2c scalar gcc host+oobelim | 1.91 | 4.22 | 0.43 | 75.29 |
| wasm2c scalar clang host+oobelim | 1.91 | 4.64 | 0.39 | 77.45 |
| wasm2c autovec gcc host+oobelim | 1.84 | 4.13 | 4.08 | 91.98 |
| wasm2c autovec clang host+oobelim | 1.83 | 4.64 | 0.54 | 77.20 |
| wasm2c simd gcc base | 2.22 | 5.13 | 0.40 | 75.86 |
| wasm2c simd gcc host | 2.22 | 5.11 | 0.40 | 76.38 |
| wasm2c simd gcc host+oobelim | 2.17 | 5.07 | 0.40 | 76.49 |
| wasm2c simd clang base | 2.05 | 4.01 | 0.81 | 79.10 |
| wasm2c simd clang host | 2.05 | 3.99 | 0.80 | 77.14 |
| wasm2c simd clang host+oobelim | 1.84 | 3.77 | 0.50 | 77.48 |
| wasm2c simd-u2 gcc host+oobelim | 1.82 | 4.05 | 0.40 | 75.67 |
| wasm2c simd-u2 clang host+oobelim | 1.84 | 3.74 | 0.49 | 77.33 |
| wasm2c simd-vb32 gcc host+oobelim | 2.10 | 4.10 | 0.40 | 75.80 |
| wasm2c simd-vb32 clang host+oobelim | 1.84 | 3.74 | 0.50 | 78.41 |

speed relative to `wasmtime simd` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 0.23 | 0.80 | 0.28 | 1.00 |
| wasmtime autovec | 0.90 | 0.79 | 0.53 | 1.00 |
| wasmtime simd | 1.00 | 1.00 | 1.00 | 1.00 |
| wasmtime simd-u2 | 0.90 | 1.00 | 1.00 | 1.00 |
| wasmtime simd-vb32 | 1.02 | 1.02 | 1.00 | 1.00 |
| wasmtime relaxed | 1.09 | 1.05 | 1.07 | 1.00 |
| wasmtime relaxed-u2 | 1.01 | 1.07 | 1.07 | 1.00 |
| wasmer-llvm scalar | 0.26 | 0.86 | 0.46 | 1.64 |
| wasmer-llvm simd | 0.97 | 0.89 | 1.07 | 1.63 |
| wasmer-llvm simd-u2 | 0.97 | 0.91 | 1.06 | 1.66 |
| wasmer-llvm simd-vb32 | 0.97 | 0.64 | 1.06 | 1.53 |
| wasmer-cranelift scalar | 0.23 | 0.80 | 0.28 | 0.89 |
| wasmer-cranelift simd | 1.00 | 1.00 | 1.00 | 0.89 |
| wasmer-cranelift simd-u2 | 0.90 | 1.01 | 1.00 | 0.89 |
| wasmer-cranelift simd-vb32 | 1.03 | 1.01 | 1.00 | 0.89 |
| wasmer-singlepass scalar | 0.01 | 0.04 | 0.04 | 0.47 |
| wasmedge-aot-O3 scalar | 0.00 | 0.02 | 0.01 | 0.02 |
| wasmedge-aot-O3 simd | 0.01 | 0.04 | 0.02 | 0.02 |
| wasmedge-aot-O3 simd-u2 | 0.01 | 0.05 | 0.02 | 0.02 |
| wasmedge-aot-O3 simd-vb32 | 0.01 | 0.05 | 0.02 | 0.02 |
| wasm2c scalar gcc host+oobelim | 1.08 | 0.96 | 1.36 | 1.70 |
| wasm2c scalar clang host+oobelim | 1.07 | 0.87 | 1.48 | 1.65 |
| wasm2c autovec gcc host+oobelim | 1.11 | 0.98 | 0.14 | 1.39 |
| wasm2c autovec clang host+oobelim | 1.12 | 0.87 | 1.09 | 1.66 |
| wasm2c simd gcc base | 0.92 | 0.79 | 1.46 | 1.69 |
| wasm2c simd gcc host | 0.92 | 0.79 | 1.45 | 1.68 |
| wasm2c simd gcc host+oobelim | 0.94 | 0.80 | 1.45 | 1.67 |
| wasm2c simd clang base | 1.00 | 1.01 | 0.72 | 1.62 |
| wasm2c simd clang host | 1.00 | 1.01 | 0.73 | 1.66 |
| wasm2c simd clang host+oobelim | 1.11 | 1.07 | 1.18 | 1.65 |
| wasm2c simd-u2 gcc host+oobelim | 1.12 | 1.00 | 1.46 | 1.69 |
| wasm2c simd-u2 clang host+oobelim | 1.12 | 1.08 | 1.18 | 1.66 |
| wasm2c simd-vb32 gcc host+oobelim | 0.97 | 0.99 | 1.46 | 1.69 |
| wasm2c simd-vb32 clang host+oobelim | 1.11 | 1.08 | 1.18 | 1.63 |

