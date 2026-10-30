## linux-x64: wasm-aot run 41062880168, commit dbdc717137800e142e3bb47ab3ff2cf094dc4131
model name	: AMD EPYC 7763 64-Core Processor
fma avx2 
KERNEL nbody1024 5.126 204556
(node:3375) ExperimentalWarning: WASI is an experimental feature and might change at any time
(Use `node --trace-warnings ...` to show where the warning was created)
rc=0 (scalar)
KERNEL nbody1024 2.685 204556
(node:3385) ExperimentalWarning: WASI is an experimental feature and might change at any time
(Use `node --trace-warnings ...` to show where the warning was created)
rc=0 (simd-u2)
wasmer: wasmer 7.5.0 |       --target <TARGET_TRIPLE> |           Compilation Target triple |   -s, --singlepass |           Use Singlepass compiler |   -c, --cranelift |           Use Cranelift compiler |   -l, --llvm |           Use LLVM compiler |       --enable-verifier |           Enable compiler internal verification. |           Available for Cranelift (enabled always for LLVM). |           Available for Cranelift, LLVM and Singlepass. |           Enable a profiler. |           Available for Cranelift, LLVM and Singlepass.
wasmer compile --singlepass simd: rc=1 n
Target: x86_64-unknown-linux-gnu
error: failed to compile `so/so-simd.wasm`
╰─▶ 1: Compilation error: not yet implemented: V128Const { value: V128([0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
wasmer compile --singlepass simd-u2: rc=1 arget: x86_64-unknown-linux-gnu
error: failed to compile `so/so-simd-u2.wasm`
╰─▶ 1: Compilation error: not yet implemented: V128Const { value: V128([0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
wasmer compile --singlepass simd-vb32: rc=1 get: x86_64-unknown-linux-gnu
error: failed to compile `so/so-simd-vb32.wasm`
╰─▶ 1: Compilation error: not yet implemented: V128Const { value: V128([0, 0, 1, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]) }
wamrc: --target=<arch-name>      Set the target arch, which has the general format: <arch><sub> |                             Use --target=help to list supported targets |                             By doing this, --target-abi, --cpu, and --cpu-features will be ignored. |   --target-abi=<abi>        Set the target ABI, e.g. gnu, eabi, gnueabihf, msvc, etc. |                               Default is gnu if target isn't riscv64 or riscv32 |                               For target riscv64 and riscv32, default is lp64d and ilp32d |                             Use --target-abi=help to list all the ABI supported |   --cpu=<cpu>               Set the target CPU (default: host CPU, e.g. skylake) |       
wasmedge compile: [33mUSAGE[0m | 	/home/runner/work/ci/ci/wedge/bin/wasmedge	compile [OPTIONS] [--] WASM WASM_SO |  | [33mOPTIONS[0m | 	[32m-h|--help[0m | 		Show this help message | 	[32m--dump[0m | 		Dump LLVM IR to `wasm.ll` and `wasm-opt.ll`. | 	[32m--interruptible[0m | 		Generate a interruptible binary | 	[32m--enable-instruction-count[0m | 		Enable generating code for counting Wasm instructions executed. | 	[32m--enable-gas-measuring[0m | 		Enable generating code for counting gas burned during execution. | 	[32m--enable-time-measuring[0m | 		Enable generating code for counting time during execution. | 	[32m--enable-all-statistics[0m | 		Enable generating code for all statistics options 
SMOKE FAIL wasmedge-aot-O3 scalar: rc=1 [2026-10-30 13:25:32.245] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-scalar.so"
SMOKE FAIL wasmedge-aot-O3 simd: rc=1 [2026-10-30 13:25:33.212] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-simd.so"
SMOKE FAIL wasmedge-aot-O3 simd-u2: rc=1 [2026-10-30 13:25:34.186] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-simd-u2.so"
SMOKE FAIL wasmedge-aot-O3 simd-vb32: rc=1 [2026-10-30 13:25:35.152] [error]     File name: "/home/runner/work/ci/ci/aot/wedge-O3-simd-vb32.so"
wasm2c scalar: ok, 553536 bytes of C
wasm2c autovec: ok, 591328 bytes of C
wasm2c simd: ok, 586962 bytes of C
wasm2c simd-u2: ok, 591553 bytes of C
wasm2c simd-vb32: ok, 592988 bytes of C
wasm2c relaxed: rc=1 wasm2c: unknown option '--enable-relaxed-simd'
Try '--help' for more information.
wasm2c relaxed-u2: rc=1 wasm2c: unknown option '--enable-relaxed-simd'
Try '--help' for more information.
50 runnable rows
### AOT routes linux-x64 (ref = wasmtime simd): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 8.22 | 5.28 | 0.85 | 216.05 |
| wasmtime autovec | 2.35 | 5.23 | 0.73 | 343.35 |
| wasmtime simd | 2.07 | 2.79 | 0.29 | 343.29 |
| wasmtime simd-u2 | 2.95 | 2.73 | 0.29 | 343.05 |
| wasmtime simd-vb32 | 1.72 | 2.84 | 0.27 | 358.96 |
| wasmtime relaxed | 2.06 | 2.58 | 0.28 | 360.01 |
| wasmtime relaxed-u2 | 2.34 | 2.54 | 0.33 | 359.59 |
| wasmer-llvm scalar | 5.67 | 5.08 | 0.79 | 207.82 |
| wasmer-llvm simd | 1.63 | 3.77 | 0.32 | 210.42 |
| wasmer-llvm simd-u2 | 1.64 | 3.43 | 0.32 | 210.10 |
| wasmer-llvm simd-vb32 | 1.63 | 3.41 | 0.33 | 210.02 |
| wasmer-cranelift scalar | 8.22 | 5.23 | 0.99 | 276.50 |
| wasmer-cranelift simd | 2.04 | 2.81 | 0.33 | 345.55 |
| wasmer-cranelift simd-u2 | 2.34 | 2.76 | 0.33 | 347.11 |
| wasmer-cranelift simd-vb32 | 1.77 | 2.84 | 0.33 | 346.01 |
| wasmer-singlepass scalar | 37.66 | 24.52 | 5.14 | 341.99 |
| wamr-aot-default scalar | 8.16 | 5.08 | 1.00 | 159.67 |
| wamr-aot-default simd | 2.29 | 2.57 | 0.74 | 159.70 |
| wamr-aot-default simd-u2 | 2.30 | 2.52 | 0.42 | 158.44 |
| wamr-aot-default simd-vb32 | 2.28 | 2.52 | 0.41 | 156.68 |
| wamr-aot-avx2 scalar | 8.14 | 5.09 | 0.93 | 138.51 |
| wamr-aot-avx2 simd | 2.32 | 2.57 | 0.45 | 101.56 |
| wamr-aot-avx2 simd-u2 | 2.27 | 2.53 | 0.42 | 134.62 |
| wamr-aot-avx2 simd-vb32 | 2.28 | 2.53 | 0.43 | 133.01 |
| node-liftoff-default scalar | - | - | - | - |  <- FAILED: Segmentation fault (core dumped)
| node-liftoff-default simd | 6.19 | 3.46 | 0.68 | 174.82 |
| node-liftoff-default simd-u2 | 5.30 | 3.88 | 0.74 | 175.89 |
| node-liftoff-default simd-vb32 | 5.17 | 4.06 | 0.71 | 174.76 |
| node-turbofan scalar | 7.39 | 5.24 | 1.47 | 175.42 |
| node-turbofan simd | 1.92 | - | - | - |
| node-turbofan simd-u2 | 1.92 | 2.71 | 0.28 | 175.71 |
| node-turbofan simd-vb32 | 1.69 | 2.71 | 0.28 | 176.31 |
| node-turbofan+revec scalar | 7.39 | 5.25 | 1.46 | 174.98 |
| node-turbofan+revec simd | 1.92 | 2.61 | 0.28 | 175.72 |
| node-turbofan+revec simd-u2 | 1.92 | 2.70 | 0.29 | 176.63 |
| node-turbofan+revec simd-vb32 | 1.70 | 2.71 | 0.28 | 175.27 |
| wasm2c scalar gcc host+oobelim | 1.00 | 4.90 | 0.25 | 259.70 |
| wasm2c scalar clang host+oobelim | 2.39 | 4.89 | 0.41 | 163.26 |
| wasm2c autovec gcc host+oobelim | 1.96 | 4.87 | 0.48 | 383.09 |
| wasm2c autovec clang host+oobelim | 2.06 | 4.89 | 0.41 | 159.05 |
| wasm2c simd gcc base | 2.23 | 2.71 | 0.36 | 245.57 |
| wasm2c simd gcc host | 2.06 | 2.43 | 0.32 | 271.91 |
| wasm2c simd gcc host+oobelim | 1.84 | 2.50 | 0.32 | 177.35 |
| wasm2c simd clang base | 1.55 | 2.83 | 0.57 | 156.69 |
| wasm2c simd clang host | 1.99 | 2.56 | 0.53 | 148.14 |
| wasm2c simd clang host+oobelim | 2.08 | 2.46 | 0.41 | 164.59 |
| wasm2c simd-u2 gcc host+oobelim | 1.98 | 2.42 | 0.32 | 195.33 |
| wasm2c simd-u2 clang host+oobelim | 2.07 | 2.41 | 0.45 | 155.41 |
| wasm2c simd-vb32 gcc host+oobelim | 1.99 | 2.43 | 0.34 | 262.34 |
| wasm2c simd-vb32 clang host+oobelim | 2.10 | 2.42 | 0.41 | 155.86 |

speed relative to `wasmtime simd` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| wasmtime scalar | 0.25 | 0.53 | 0.35 | 1.59 |
| wasmtime autovec | 0.88 | 0.53 | 0.40 | 1.00 |
| wasmtime simd | 1.00 | 1.00 | 1.00 | 1.00 |
| wasmtime simd-u2 | 0.70 | 1.02 | 1.01 | 1.00 |
| wasmtime simd-vb32 | 1.20 | 0.98 | 1.08 | 0.96 |
| wasmtime relaxed | 1.00 | 1.08 | 1.05 | 0.95 |
| wasmtime relaxed-u2 | 0.88 | 1.09 | 0.90 | 0.95 |
| wasmer-llvm scalar | 0.37 | 0.55 | 0.37 | 1.65 |
| wasmer-llvm simd | 1.27 | 0.74 | 0.91 | 1.63 |
| wasmer-llvm simd-u2 | 1.26 | 0.81 | 0.91 | 1.63 |
| wasmer-llvm simd-vb32 | 1.27 | 0.82 | 0.90 | 1.63 |
| wasmer-cranelift scalar | 0.25 | 0.53 | 0.30 | 1.24 |
| wasmer-cranelift simd | 1.01 | 0.99 | 0.89 | 0.99 |
| wasmer-cranelift simd-u2 | 0.88 | 1.01 | 0.90 | 0.99 |
| wasmer-cranelift simd-vb32 | 1.17 | 0.98 | 0.90 | 0.99 |
| wasmer-singlepass scalar | 0.05 | 0.11 | 0.06 | 1.00 |
| wamr-aot-default scalar | 0.25 | 0.55 | 0.29 | 2.15 |
| wamr-aot-default simd | 0.90 | 1.09 | 0.40 | 2.15 |
| wamr-aot-default simd-u2 | 0.90 | 1.11 | 0.70 | 2.17 |
| wamr-aot-default simd-vb32 | 0.91 | 1.11 | 0.71 | 2.19 |
| wamr-aot-avx2 scalar | 0.25 | 0.55 | 0.32 | 2.48 |
| wamr-aot-avx2 simd | 0.89 | 1.08 | 0.66 | 3.38 |
| wamr-aot-avx2 simd-u2 | 0.91 | 1.10 | 0.70 | 2.55 |
| wamr-aot-avx2 simd-vb32 | 0.91 | 1.10 | 0.69 | 2.58 |
| node-liftoff-default scalar | - | - | - | - |
| node-liftoff-default simd | 0.33 | 0.80 | 0.43 | 1.96 |
| node-liftoff-default simd-u2 | 0.39 | 0.72 | 0.40 | 1.95 |
| node-liftoff-default simd-vb32 | 0.40 | 0.69 | 0.42 | 1.96 |
| node-turbofan scalar | 0.28 | 0.53 | 0.20 | 1.96 |
| node-turbofan simd | 1.08 | - | - | - |
| node-turbofan simd-u2 | 1.08 | 1.03 | 1.04 | 1.95 |
| node-turbofan simd-vb32 | 1.22 | 1.03 | 1.04 | 1.95 |
| node-turbofan+revec scalar | 0.28 | 0.53 | 0.20 | 1.96 |
| node-turbofan+revec simd | 1.08 | 1.07 | 1.04 | 1.95 |
| node-turbofan+revec simd-u2 | 1.08 | 1.03 | 1.00 | 1.94 |
| node-turbofan+revec simd-vb32 | 1.22 | 1.03 | 1.04 | 1.96 |
| wasm2c scalar gcc host+oobelim | 2.08 | 0.57 | 1.20 | 1.32 |
| wasm2c scalar clang host+oobelim | 0.86 | 0.57 | 0.71 | 2.10 |
| wasm2c autovec gcc host+oobelim | 1.06 | 0.57 | 0.62 | 0.90 |
| wasm2c autovec clang host+oobelim | 1.01 | 0.57 | 0.71 | 2.16 |
| wasm2c simd gcc base | 0.93 | 1.03 | 0.81 | 1.40 |
| wasm2c simd gcc host | 1.00 | 1.15 | 0.91 | 1.26 |
| wasm2c simd gcc host+oobelim | 1.12 | 1.11 | 0.91 | 1.94 |
| wasm2c simd clang base | 1.33 | 0.98 | 0.51 | 2.19 |
| wasm2c simd clang host | 1.04 | 1.09 | 0.55 | 2.32 |
| wasm2c simd clang host+oobelim | 1.00 | 1.13 | 0.71 | 2.09 |
| wasm2c simd-u2 gcc host+oobelim | 1.04 | 1.15 | 0.91 | 1.76 |
| wasm2c simd-u2 clang host+oobelim | 1.00 | 1.16 | 0.65 | 2.21 |
| wasm2c simd-vb32 gcc host+oobelim | 1.04 | 1.15 | 0.88 | 1.31 |
| wasm2c simd-vb32 clang host+oobelim | 0.99 | 1.15 | 0.71 | 2.20 |

