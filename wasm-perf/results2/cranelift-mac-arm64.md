

(grep -m1 -o 'flags.*\|Features.*' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|fma|bmi2|avx512f|asimd|sve|sve2|asimddp|bf16|i8mm|fphp)$' | tr '\n' ' ') 2>/dev/null || true; echo
Apple M1 (Virtual)
Settings inferred for the current host:   has_dotprod   has_fp16   has_lse   has_pauth   sign_return_address_with_bkey 
compile cwasm-baseline (--target only, no extra flags): rc=0 
16 configurations
### Phase A mac-arm64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)
| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.45 | 1.28 | 0.42 | 145.75 | 3.66 |
| opt-level=0 | 2.97 | 1.50 | 0.43 | 157.17 | 3.31 |
| opt-level=1 | 1.44 | 1.28 | 0.41 | 145.01 | 3.30 |
| opt-level=2 | 1.44 | 1.28 | 0.41 | 132.87 | 3.30 |
| opt-level=s | 1.44 | 1.30 | 0.38 | 136.23 | 3.32 |
| regalloc single-pass | 5.00 | 3.77 | 0.66 | 222.15 | 6.80 |
| explicit bounds checks (signals-based-traps=n) | 2.96 | 1.56 | 0.64 | 178.94 | 3.42 |
| dynamic memory (reservation 0, guard 0) | 3.43 | 1.61 | 0.56 | 163.33 | 3.38 |
| memory-may-move=y | 1.59 | 1.28 | 0.42 | 139.54 | 3.57 |
| memory-reservation=4GiB, guard=0 | 3.45 | 1.68 | 0.58 | 158.14 | 3.54 |
| epoch-interruption=y | - | - | - | - | - |  <- FAILED: Error: failed to run main module `so/so-simd.wasm`
| fuel=1e15 | 3.49 | 2.34 | 0.52 | 152.78 | 3.32 |
| nan-canonicalization=y | 4.20 | 10.35 | 1.01 | 126.00 | 3.29 |
| inlining=y | 1.50 | 1.29 | 0.42 | 127.49 | 3.61 |
| winch (baseline compiler) | 5.15 | 4.30 | 0.68 | 178.29 | 3.67 |
| cwasm-baseline (--target only, no extra flags) | 1.44 | 1.28 | 0.41 | 130.98 | 3.42 |
speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row
| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=0 | 0.49 | 0.85 | 0.98 | 0.93 | 1.10 |
| opt-level=1 | 1.01 | 1.00 | 1.03 | 1.01 | 1.11 |
| opt-level=2 | 1.01 | 1.00 | 1.03 | 1.10 | 1.11 |
| opt-level=s | 1.01 | 0.98 | 1.11 | 1.07 | 1.10 |
| regalloc single-pass | 0.29 | 0.34 | 0.64 | 0.66 | 0.54 |
| explicit bounds checks (signals-based-traps=n) | 0.49 | 0.82 | 0.67 | 0.81 | 1.07 |
| dynamic memory (reservation 0, guard 0) | 0.42 | 0.80 | 0.75 | 0.89 | 1.08 |
| memory-may-move=y | 0.92 | 1.00 | 1.02 | 1.04 | 1.03 |
| memory-reservation=4GiB, guard=0 | 0.42 | 0.76 | 0.73 | 0.92 | 1.04 |
| epoch-interruption=y | - | - | - | - | - |
| fuel=1e15 | 0.42 | 0.55 | 0.82 | 0.95 | 1.10 |
| nan-canonicalization=y | 0.35 | 0.12 | 0.42 | 1.16 | 1.11 |
| inlining=y | 0.97 | 0.99 | 1.02 | 1.14 | 1.02 |
| winch (baseline compiler) | 0.28 | 0.30 | 0.63 | 0.82 | 1.00 |
| cwasm-baseline (--target only, no extra flags) | 1.01 | 1.00 | 1.03 | 1.11 | 1.07 |
### Phase B mac-arm64: wasm source variants vs native (ref = native scalar, baseline ISA): ms per kernel (best of 3 interleaved rounds)
| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native n-hostisa-auto | 1.28 | 1.40 | 0.17 | 99.98 | 3.54 | 52.87 |
| native n-hostisa-simd128 | 1.54 | 1.03 | 0.14 | 110.80 | 3.67 | 57.02 |
| native n-hostisa-simd128-u4 | 1.33 | 0.90 | 0.15 | 102.06 | 3.67 | 60.41 |
| native n-hostisa-simd128-u4-nofma | 1.28 | 1.05 | 0.18 | 100.63 | 3.73 | 58.96 |
| native n-hostisa-vb32-u2 | 1.32 | 0.84 | 0.14 | 106.19 | 3.34 | 55.12 |
| native n-hostisa-vb32-u2-nofma | 1.31 | 1.05 | 0.17 | 102.39 | 3.60 | 53.35 |
| native n-novec | 5.83 | 1.87 | 0.38 | 116.82 | 3.67 | 53.06 |
| native n-scalar | 1.36 | 1.47 | 0.19 | 102.83 | 3.81 | 66.99 |
| native n-simd128 | 1.55 | 1.08 | 0.15 | 102.56 | 3.30 | 60.68 |
| native n-simd128-u4 | 1.38 | 0.92 | 0.14 | 101.48 | 3.31 | 54.10 |
| wasmtime scalar | 6.55 | 2.24 | 1.30 | 136.82 | 3.64 | 65.14 |
| wasmtime autovec | 1.59 | 2.24 | 0.45 | 127.43 | 3.33 | 69.29 |
| wasmtime simd | 1.48 | 1.28 | 0.38 | 127.32 | 3.56 | 59.73 |
| wasmtime simd-u2 | 1.59 | 1.18 | 0.38 | 129.94 | 3.29 | 58.58 |
| wasmtime simd-u4 | 1.42 | 1.13 | 0.38 | 128.69 | 3.30 | 58.88 |
| wasmtime simd-vb32 | 1.34 | 1.20 | 0.41 | 129.67 | 3.62 | 66.14 |
| wasmtime simd-vb32-u2 | 1.43 | 1.14 | 0.38 | 135.34 | 3.59 | 65.78 |
| wasmtime relaxed | 1.31 | 1.04 | 0.35 | 130.67 | 3.40 | 60.06 |
| wasmtime relaxed-u2 | 1.45 | 0.94 | 0.35 | 133.18 | 3.29 | 60.14 |
speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row
| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native n-hostisa-auto | 1.06 | 1.05 | 1.09 | 1.03 | 1.07 | 1.27 |
| native n-hostisa-simd128 | 0.88 | 1.42 | 1.37 | 0.93 | 1.04 | 1.17 |
| native n-hostisa-simd128-u4 | 1.02 | 1.63 | 1.22 | 1.01 | 1.04 | 1.11 |
| native n-hostisa-simd128-u4-nofma | 1.06 | 1.40 | 1.02 | 1.02 | 1.02 | 1.14 |
| native n-hostisa-vb32-u2 | 1.02 | 1.75 | 1.33 | 0.97 | 1.14 | 1.22 |
| native n-hostisa-vb32-u2-nofma | 1.03 | 1.40 | 1.13 | 1.00 | 1.06 | 1.26 |
| native n-novec | 0.23 | 0.79 | 0.50 | 0.88 | 1.04 | 1.26 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 0.87 | 1.36 | 1.25 | 1.00 | 1.15 | 1.10 |
| native n-simd128-u4 | 0.99 | 1.60 | 1.37 | 1.01 | 1.15 | 1.24 |
| wasmtime scalar | 0.21 | 0.66 | 0.15 | 0.75 | 1.05 | 1.03 |
| wasmtime autovec | 0.85 | 0.66 | 0.42 | 0.81 | 1.14 | 0.97 |
| wasmtime simd | 0.92 | 1.15 | 0.49 | 0.81 | 1.07 | 1.12 |
| wasmtime simd-u2 | 0.85 | 1.24 | 0.49 | 0.79 | 1.16 | 1.14 |
| wasmtime simd-u4 | 0.96 | 1.31 | 0.49 | 0.80 | 1.15 | 1.14 |
| wasmtime simd-vb32 | 1.01 | 1.22 | 0.46 | 0.79 | 1.05 | 1.01 |
| wasmtime simd-vb32-u2 | 0.95 | 1.29 | 0.49 | 0.76 | 1.06 | 1.02 |
| wasmtime relaxed | 1.04 | 1.42 | 0.54 | 0.79 | 1.12 | 1.12 |
| wasmtime relaxed-u2 | 0.94 | 1.57 | 0.54 | 0.77 | 1.16 | 1.11 |
