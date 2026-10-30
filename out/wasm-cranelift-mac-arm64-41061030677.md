## mac-arm64: wasm-cranelift run 41061030677, commit 1f76ef6f374a1af3de6857b416a9e17ac9fd951d
Apple clang version 21.0.0 (clang-2100.1.1.101)
Apple M1 (Virtual)

Settings inferred for the current host:   has_dotprod   has_fp16   has_lse   has_pauth   sign_return_address_with_bkey 
### Phase A mac-arm64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.52 | 1.40 | 0.42 | 151.94 | 3.59 |
| opt-level=0 | 2.94 | 1.47 | 0.48 | 176.89 | 3.67 |
| opt-level=1 | 1.57 | 1.40 | 0.41 | 158.24 | 3.62 |
| opt-level=2 | 1.59 | 1.39 | 0.42 | 164.66 | 3.69 |
| opt-level=s | 1.58 | 1.39 | 0.41 | 151.52 | 3.59 |
| regalloc single-pass | 5.38 | 4.08 | 0.65 | 263.84 | 7.43 |
| explicit bounds checks (signals-based-traps=n) | 2.90 | 1.50 | 0.64 | 170.77 | 3.65 |
| dynamic memory (reservation 0, guard 0) | 3.46 | 1.63 | 0.61 | 173.43 | 3.62 |
| memory-may-move=y | 1.55 | 1.33 | 0.40 | 139.10 | 3.55 |
| memory-reservation=4GiB, guard=0 | 3.27 | 1.63 | 0.61 | 170.39 | 3.71 |
| fuel=1e15 | 3.65 | 2.25 | 0.56 | 174.24 | 3.58 |
| nan-canonicalization=y | 4.31 | 11.38 | 1.07 | 146.16 | 3.43 |
| inlining=y | 1.55 | 1.38 | 0.42 | 141.59 | 3.62 |
| winch (baseline compiler) | 5.37 | 4.49 | 0.64 | 175.62 | 3.68 |
| cwasm-baseline (--target only, no extra flags) | 1.50 | 1.33 | 0.41 | 137.88 | 3.56 |
| cwasm-host-default (compile without --target) | 1.49 | 1.38 | 0.41 | 141.72 | 3.58 |

speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=0 | 0.52 | 0.95 | 0.89 | 0.86 | 0.98 |
| opt-level=1 | 0.97 | 1.00 | 1.03 | 0.96 | 0.99 |
| opt-level=2 | 0.95 | 1.01 | 1.02 | 0.92 | 0.97 |
| opt-level=s | 0.96 | 1.01 | 1.04 | 1.00 | 1.00 |
| regalloc single-pass | 0.28 | 0.34 | 0.65 | 0.58 | 0.48 |
| explicit bounds checks (signals-based-traps=n) | 0.53 | 0.94 | 0.67 | 0.89 | 0.98 |
| dynamic memory (reservation 0, guard 0) | 0.44 | 0.86 | 0.70 | 0.88 | 0.99 |
| memory-may-move=y | 0.98 | 1.05 | 1.07 | 1.09 | 1.01 |
| memory-reservation=4GiB, guard=0 | 0.47 | 0.86 | 0.70 | 0.89 | 0.97 |
| fuel=1e15 | 0.42 | 0.62 | 0.76 | 0.87 | 1.00 |
| nan-canonicalization=y | 0.35 | 0.12 | 0.40 | 1.04 | 1.05 |
| inlining=y | 0.98 | 1.02 | 1.01 | 1.07 | 0.99 |
| winch (baseline compiler) | 0.28 | 0.31 | 0.67 | 0.87 | 0.98 |
| cwasm-baseline (--target only, no extra flags) | 1.02 | 1.06 | 1.03 | 1.10 | 1.01 |
| cwasm-host-default (compile without --target) | 1.02 | 1.01 | 1.04 | 1.07 | 1.00 |

### Phase B mac-arm64: wasm source variants vs native (ref = native scalar, baseline ISA): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native n-hostisa-auto | 1.39 | 1.46 | 0.19 | 108.26 | 3.45 | 58.53 |
| native n-hostisa-simd128 | 1.48 | 0.99 | 0.14 | 109.65 | 3.62 | 57.94 |
| native n-hostisa-simd128-u4 | 1.32 | 0.87 | 0.15 | 111.73 | 3.46 | 56.15 |
| native n-hostisa-simd128-u4-nofma | 1.35 | 1.09 | 0.18 | 110.80 | 3.69 | 60.40 |
| native n-hostisa-vb32-u2 | 1.33 | 0.87 | 0.15 | 110.04 | 3.46 | 56.65 |
| native n-hostisa-vb32-u2-nofma | 1.38 | 1.09 | 0.17 | 106.33 | 3.44 | 57.63 |
| native n-novec | 6.30 | 1.90 | 0.42 | 112.38 | 3.62 | 57.62 |
| native n-scalar | 1.35 | 1.43 | 0.18 | 109.43 | 3.58 | 56.25 |
| native n-simd128 | 1.42 | 1.01 | 0.15 | 109.11 | 3.45 | 57.66 |
| native n-simd128-u4 | 1.41 | 0.93 | 0.15 | 113.52 | 3.63 | 59.15 |
| wasmtime scalar | 7.12 | 2.44 | 1.32 | 145.04 | 3.59 | 69.39 |
| wasmtime autovec | 1.74 | 2.44 | 0.45 | 148.27 | 3.57 | 71.53 |
| wasmtime simd | 1.62 | 1.41 | 0.44 | 148.05 | 3.62 | 65.17 |
| wasmtime simd-u2 | 1.73 | 1.28 | 0.41 | 143.85 | 3.63 | 66.59 |
| wasmtime simd-u4 | 1.54 | 1.21 | 0.42 | 141.84 | 3.58 | 63.79 |
| wasmtime simd-vb32 | 1.40 | 1.29 | 0.42 | 138.38 | 3.61 | 64.49 |
| wasmtime simd-vb32-u2 | 1.48 | 1.18 | 0.41 | 136.47 | 3.44 | 65.16 |
| wasmtime relaxed | 1.35 | 1.08 | 0.37 | 133.27 | 3.43 | 63.70 |
| wasmtime relaxed-u2 | 1.51 | 0.97 | 0.38 | 135.19 | 3.58 | 63.64 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native n-hostisa-auto | 0.97 | 0.98 | 0.95 | 1.01 | 1.04 | 0.96 |
| native n-hostisa-simd128 | 0.91 | 1.44 | 1.25 | 1.00 | 0.99 | 0.97 |
| native n-hostisa-simd128-u4 | 1.02 | 1.64 | 1.18 | 0.98 | 1.04 | 1.00 |
| native n-hostisa-simd128-u4-nofma | 1.00 | 1.31 | 0.99 | 0.99 | 0.97 | 0.93 |
| native n-hostisa-vb32-u2 | 1.02 | 1.64 | 1.21 | 0.99 | 1.03 | 0.99 |
| native n-hostisa-vb32-u2-nofma | 0.98 | 1.31 | 1.03 | 1.03 | 1.04 | 0.98 |
| native n-novec | 0.21 | 0.75 | 0.42 | 0.97 | 0.99 | 0.98 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 0.95 | 1.41 | 1.17 | 1.00 | 1.04 | 0.98 |
| native n-simd128-u4 | 0.96 | 1.53 | 1.21 | 0.96 | 0.99 | 0.95 |
| wasmtime scalar | 0.19 | 0.59 | 0.14 | 0.75 | 1.00 | 0.81 |
| wasmtime autovec | 0.77 | 0.58 | 0.40 | 0.74 | 1.00 | 0.79 |
| wasmtime simd | 0.83 | 1.01 | 0.41 | 0.74 | 0.99 | 0.86 |
| wasmtime simd-u2 | 0.78 | 1.11 | 0.43 | 0.76 | 0.99 | 0.84 |
| wasmtime simd-u4 | 0.88 | 1.18 | 0.43 | 0.77 | 1.00 | 0.88 |
| wasmtime simd-vb32 | 0.97 | 1.10 | 0.43 | 0.79 | 0.99 | 0.87 |
| wasmtime simd-vb32-u2 | 0.91 | 1.21 | 0.43 | 0.80 | 1.04 | 0.86 |
| wasmtime relaxed | 1.00 | 1.32 | 0.49 | 0.82 | 1.04 | 0.88 |
| wasmtime relaxed-u2 | 0.89 | 1.47 | 0.47 | 0.81 | 1.00 | 0.88 |

