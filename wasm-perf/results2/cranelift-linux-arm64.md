

(grep -m1 -o 'flags.*\|Features.*' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|fma|bmi2|avx512f|asimd|sve|sve2|asimddp|bf16|i8mm|fphp)$' | tr '\n' ' ') 2>/dev/null || true; echo
asimd fphp asimddp sve sve2 i8mm bf16 
Settings inferred for the current host:   has_dotprod   has_fp16   has_i8mm   has_lse   has_pauth 
compile cwasm-baseline (--target only, no extra flags): rc=0 
16 configurations
### Phase A linux-arm64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)
| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 2.05 | 4.04 | 0.58 | 128.24 | 2.49 |
| opt-level=0 | 3.39 | 4.04 | 0.66 | 147.81 | 2.62 |
| opt-level=1 | 2.05 | 4.04 | 0.58 | 128.02 | 2.49 |
| opt-level=2 | 2.06 | 4.04 | 0.58 | 128.10 | 2.49 |
| opt-level=s | 2.04 | 4.04 | 0.59 | 127.96 | 2.50 |
| regalloc single-pass | 7.79 | 4.64 | 0.90 | 449.84 | 7.13 |
| explicit bounds checks (signals-based-traps=n) | 3.49 | 3.92 | 0.78 | 155.70 | 2.52 |
| dynamic memory (reservation 0, guard 0) | 4.05 | 4.12 | 0.86 | 167.96 | 2.66 |
| memory-may-move=y | 2.05 | 4.04 | 0.59 | 128.01 | 2.49 |
| memory-reservation=4GiB, guard=0 | 4.17 | 4.14 | 0.86 | 169.89 | 2.65 |
| epoch-interruption=y | - | - | - | - | - |  <- FAILED: Error: failed to run main module `so/so-simd.wasm`
| fuel=1e15 | 3.75 | 4.21 | 0.77 | 176.68 | 2.50 |
| nan-canonicalization=y | 9.54 | 27.87 | 2.45 | 128.01 | 2.50 |
| inlining=y | 2.06 | 4.04 | 0.58 | 127.97 | 2.50 |
| winch (baseline compiler) | 7.18 | 5.87 | 0.90 | 245.76 | 4.04 |
| cwasm-baseline (--target only, no extra flags) | 2.05 | 4.04 | 0.58 | 128.19 | 2.50 |
speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row
| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=0 | 0.60 | 1.00 | 0.89 | 0.87 | 0.95 |
| opt-level=1 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=2 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=s | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| regalloc single-pass | 0.26 | 0.87 | 0.65 | 0.29 | 0.35 |
| explicit bounds checks (signals-based-traps=n) | 0.59 | 1.03 | 0.75 | 0.82 | 0.99 |
| dynamic memory (reservation 0, guard 0) | 0.51 | 0.98 | 0.68 | 0.76 | 0.94 |
| memory-may-move=y | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| memory-reservation=4GiB, guard=0 | 0.49 | 0.97 | 0.68 | 0.75 | 0.94 |
| epoch-interruption=y | - | - | - | - | - |
| fuel=1e15 | 0.55 | 0.96 | 0.76 | 0.73 | 1.00 |
| nan-canonicalization=y | 0.21 | 0.14 | 0.24 | 1.00 | 1.00 |
| inlining=y | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| winch (baseline compiler) | 0.29 | 0.69 | 0.65 | 0.52 | 0.62 |
| cwasm-baseline (--target only, no extra flags) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
### Phase B linux-arm64: wasm source variants vs native (ref = native scalar, baseline ISA): ms per kernel (best of 3 interleaved rounds)
| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 1.81 | 4.04 | 0.39 | 77.14 | 2.49 | 45.62 |
| native c-hostisa-vb32-u2 | 1.83 | 3.77 | 0.24 | 77.19 | 2.49 | 45.42 |
| native c-hostisa-vb32-u2-nofma | 1.91 | 4.02 | 0.33 | 76.89 | 2.48 | 45.56 |
| native c-scalar | 1.82 | 4.09 | 0.39 | 74.61 | 2.49 | 45.43 |
| native n-hostisa-auto | 1.63 | 4.04 | 0.43 | 76.98 | 2.52 | 55.60 |
| native n-hostisa-simd128 | 1.64 | 3.79 | 0.34 | 75.18 | 2.52 | 55.60 |
| native n-hostisa-simd128-u4 | 1.51 | 3.93 | 0.34 | 75.84 | 2.52 | 55.47 |
| native n-hostisa-simd128-u4-nofma | 1.68 | 3.96 | 0.42 | 74.96 | 2.52 | 55.58 |
| native n-hostisa-vb32-u2 | 6.27 | 4.83 | 0.34 | 76.34 | 2.53 | 55.83 |
| native n-hostisa-vb32-u2-nofma | 6.00 | 4.58 | 0.42 | 79.23 | 2.53 | 55.63 |
| native n-novec | 6.97 | 4.06 | 0.80 | 88.09 | 2.53 | 54.89 |
| native n-scalar | 1.64 | 3.77 | 0.44 | 77.61 | 2.51 | 54.77 |
| native n-simd128 | 1.64 | 3.78 | 0.34 | 90.13 | 2.48 | 54.92 |
| native n-simd128-u4 | 1.49 | 3.83 | 0.34 | 75.99 | 2.48 | 54.96 |
| wasmtime scalar | 8.94 | 5.07 | 2.07 | 128.04 | 2.50 | 50.77 |
| wasmtime autovec | 2.28 | 5.08 | 1.11 | 128.01 | 2.50 | 50.81 |
| wasmtime simd | 2.05 | 4.04 | 0.58 | 128.06 | 2.50 | 50.60 |
| wasmtime simd-u2 | 2.27 | 4.01 | 0.59 | 128.00 | 2.49 | 50.84 |
| wasmtime simd-u4 | 2.05 | 3.94 | 0.58 | 127.95 | 2.50 | 50.88 |
| wasmtime simd-vb32 | 2.01 | 3.98 | 0.59 | 128.03 | 2.50 | 50.93 |
| wasmtime simd-vb32-u2 | 2.07 | 3.99 | 0.59 | 128.09 | 2.50 | 50.86 |
| wasmtime relaxed | 1.88 | 3.83 | 0.55 | 128.02 | 2.50 | 50.69 |
| wasmtime relaxed-u2 | 2.04 | 3.78 | 0.55 | 127.97 | 2.50 | 50.73 |
speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row
| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 0.90 | 0.94 | 1.14 | 1.01 | 1.01 | 1.20 |
| native c-hostisa-vb32-u2 | 0.90 | 1.00 | 1.80 | 1.01 | 1.01 | 1.21 |
| native c-hostisa-vb32-u2-nofma | 0.86 | 0.94 | 1.33 | 1.01 | 1.01 | 1.20 |
| native c-scalar | 0.90 | 0.92 | 1.14 | 1.04 | 1.01 | 1.21 |
| native n-hostisa-auto | 1.00 | 0.94 | 1.01 | 1.01 | 1.00 | 0.99 |
| native n-hostisa-simd128 | 1.00 | 1.00 | 1.29 | 1.03 | 1.00 | 0.98 |
| native n-hostisa-simd128-u4 | 1.08 | 0.96 | 1.31 | 1.02 | 1.00 | 0.99 |
| native n-hostisa-simd128-u4-nofma | 0.98 | 0.95 | 1.04 | 1.04 | 1.00 | 0.99 |
| native n-hostisa-vb32-u2 | 0.26 | 0.78 | 1.28 | 1.02 | 0.99 | 0.98 |
| native n-hostisa-vb32-u2-nofma | 0.27 | 0.82 | 1.04 | 0.98 | 0.99 | 0.98 |
| native n-novec | 0.23 | 0.93 | 0.55 | 0.88 | 0.99 | 1.00 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 1.00 | 1.00 | 1.28 | 0.86 | 1.01 | 1.00 |
| native n-simd128-u4 | 1.10 | 0.99 | 1.30 | 1.02 | 1.01 | 1.00 |
| wasmtime scalar | 0.18 | 0.74 | 0.21 | 0.61 | 1.01 | 1.08 |
| wasmtime autovec | 0.72 | 0.74 | 0.40 | 0.61 | 1.01 | 1.08 |
| wasmtime simd | 0.80 | 0.94 | 0.75 | 0.61 | 1.01 | 1.08 |
| wasmtime simd-u2 | 0.72 | 0.94 | 0.75 | 0.61 | 1.01 | 1.08 |
| wasmtime simd-u4 | 0.80 | 0.96 | 0.75 | 0.61 | 1.01 | 1.08 |
| wasmtime simd-vb32 | 0.81 | 0.95 | 0.75 | 0.61 | 1.01 | 1.08 |
| wasmtime simd-vb32-u2 | 0.79 | 0.95 | 0.75 | 0.61 | 1.01 | 1.08 |
| wasmtime relaxed | 0.87 | 0.99 | 0.80 | 0.61 | 1.01 | 1.08 |
| wasmtime relaxed-u2 | 0.80 | 1.00 | 0.80 | 0.61 | 1.01 | 1.08 |
