## mac-arm64: wasm-cranelift run 41062865273, commit dbdc717137800e142e3bb47ab3ff2cf094dc4131
Apple clang version 21.0.0 (clang-2100.1.1.101)
Apple M1 (Virtual)

Settings inferred for the current host:   has_dotprod   has_fp16   has_lse   has_pauth   sign_return_address_with_bkey 
### Phase A mac-arm64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.44 | 1.28 | 0.41 | 138.97 | 3.77 |
| opt-level=0 | 2.82 | 1.46 | 0.47 | 166.79 | 3.64 |
| opt-level=1 | 1.50 | 1.41 | 0.44 | 142.10 | 3.64 |
| opt-level=2 | 1.55 | 1.33 | 0.42 | 144.22 | 3.69 |
| opt-level=s | 1.54 | 1.33 | 0.41 | 137.99 | 3.63 |
| enable_heap_access_spectre_mitigation=false | 1.57 | 1.40 | 0.41 | 136.78 | 3.58 |
| enable_table_access_spectre_mitigation=false | 1.44 | 1.30 | 0.40 | 133.34 | 3.42 |
| enable_alias_analysis=false | 1.49 | 1.32 | 0.41 | 137.87 | 3.65 |
| unwind_info=false (no exception/backtrace data) | 1.51 | 1.35 | 0.41 | 139.68 | 3.45 |
| regalloc single-pass | 5.19 | 4.17 | 0.68 | 254.06 | 7.11 |
| explicit bounds checks (signals-based-traps=n) | 3.02 | 1.47 | 0.62 | 174.86 | 3.65 |
| dynamic memory (reservation 0, guard 0) | 3.33 | 1.56 | 0.63 | 167.51 | 3.81 |
| memory-may-move=y | 1.56 | 1.38 | 0.41 | 140.45 | 3.64 |
| memory-reservation=4GiB, guard=0 | 3.40 | 1.65 | 0.60 | 167.34 | 3.64 |
| fuel=1e15 | 3.63 | 2.14 | 0.55 | 184.28 | 3.55 |
| nan-canonicalization=y | 4.27 | 11.41 | 1.06 | 133.95 | 3.43 |
| inlining=y | 1.50 | 1.33 | 0.41 | 135.94 | 3.58 |
| winch (baseline compiler) | 5.40 | 4.45 | 0.61 | 167.90 | 3.53 |
| cwasm-baseline (--target only, no extra flags) | 1.58 | 1.40 | 0.40 | 140.26 | 3.42 |
| cwasm-host-default (compile without --target) | 1.50 | 1.33 | 0.40 | 134.93 | 3.48 |

speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=0 | 0.51 | 0.88 | 0.88 | 0.83 | 1.03 |
| opt-level=1 | 0.96 | 0.91 | 0.95 | 0.98 | 1.04 |
| opt-level=2 | 0.93 | 0.96 | 0.98 | 0.96 | 1.02 |
| opt-level=s | 0.94 | 0.97 | 1.00 | 1.01 | 1.04 |
| enable_heap_access_spectre_mitigation=false | 0.92 | 0.92 | 1.01 | 1.02 | 1.05 |
| enable_table_access_spectre_mitigation=false | 1.00 | 0.98 | 1.05 | 1.04 | 1.10 |
| enable_alias_analysis=false | 0.97 | 0.97 | 1.01 | 1.01 | 1.03 |
| unwind_info=false (no exception/backtrace data) | 0.95 | 0.95 | 1.00 | 0.99 | 1.09 |
| regalloc single-pass | 0.28 | 0.31 | 0.61 | 0.55 | 0.53 |
| explicit bounds checks (signals-based-traps=n) | 0.48 | 0.87 | 0.67 | 0.79 | 1.03 |
| dynamic memory (reservation 0, guard 0) | 0.43 | 0.82 | 0.66 | 0.83 | 0.99 |
| memory-may-move=y | 0.93 | 0.93 | 1.01 | 0.99 | 1.03 |
| memory-reservation=4GiB, guard=0 | 0.42 | 0.78 | 0.69 | 0.83 | 1.04 |
| fuel=1e15 | 0.40 | 0.60 | 0.75 | 0.75 | 1.06 |
| nan-canonicalization=y | 0.34 | 0.11 | 0.39 | 1.04 | 1.10 |
| inlining=y | 0.96 | 0.97 | 1.02 | 1.02 | 1.05 |
| winch (baseline compiler) | 0.27 | 0.29 | 0.68 | 0.83 | 1.07 |
| cwasm-baseline (--target only, no extra flags) | 0.91 | 0.91 | 1.05 | 0.99 | 1.10 |
| cwasm-host-default (compile without --target) | 0.96 | 0.97 | 1.05 | 1.03 | 1.08 |

### Phase B mac-arm64: wasm source variants vs native (ref = native scalar, baseline ISA): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native n-hostisa-auto | 1.33 | 1.45 | 0.19 | 110.89 | 3.64 | 64.35 |
| native n-hostisa-simd128 | 1.67 | 1.05 | 0.14 | 114.72 | 3.45 | 56.78 |
| native n-hostisa-simd128-u4 | 1.33 | 0.88 | 0.15 | 108.90 | 3.67 | 59.34 |
| native n-hostisa-simd128-u4-nofma | 1.39 | 1.13 | 0.18 | 107.26 | 3.40 | 62.00 |
| native n-hostisa-vb32-u2 | 1.36 | 0.90 | 0.14 | 114.80 | 3.49 | 57.62 |
| native n-hostisa-vb32-u2-nofma | 1.39 | 1.15 | 0.18 | 120.15 | 3.69 | 68.23 |
| native n-novec | 5.93 | 1.87 | 0.42 | 113.82 | 3.56 | 67.49 |
| native n-scalar | 1.38 | 1.48 | 0.19 | 112.14 | 3.77 | 61.56 |
| native n-simd128 | 1.50 | 1.05 | 0.15 | 106.70 | 3.41 | 57.26 |
| native n-simd128-u4 | 1.38 | 0.90 | 0.15 | 100.06 | 3.81 | 66.14 |
| wasmtime scalar | 6.55 | 2.33 | 1.29 | 132.79 | 3.61 | 67.39 |
| wasmtime autovec | 1.60 | 2.33 | 0.46 | 143.15 | 3.76 | 69.80 |
| wasmtime simd | 1.50 | 1.40 | 0.42 | 144.48 | 3.70 | 71.43 |
| wasmtime simd-u2 | 1.73 | 1.27 | 0.41 | 147.94 | 3.69 | 66.39 |
| wasmtime simd-u4 | 1.45 | 1.15 | 0.44 | 140.24 | 3.53 | 69.05 |
| wasmtime simd-vb32 | 1.46 | 1.30 | 0.38 | 144.34 | 3.49 | 59.01 |
| wasmtime simd-vb32-u2 | 1.55 | 1.23 | 0.43 | 134.44 | 3.46 | 67.85 |
| wasmtime relaxed | 1.41 | 1.14 | 0.38 | 138.42 | 3.60 | 71.57 |
| wasmtime relaxed-u2 | 1.58 | 1.01 | 0.38 | 142.31 | 3.43 | 71.10 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native n-hostisa-auto | 1.04 | 1.02 | 1.01 | 1.01 | 1.04 | 0.96 |
| native n-hostisa-simd128 | 0.83 | 1.40 | 1.34 | 0.98 | 1.09 | 1.08 |
| native n-hostisa-simd128-u4 | 1.04 | 1.69 | 1.26 | 1.03 | 1.03 | 1.04 |
| native n-hostisa-simd128-u4-nofma | 0.99 | 1.31 | 1.03 | 1.05 | 1.11 | 0.99 |
| native n-hostisa-vb32-u2 | 1.02 | 1.64 | 1.35 | 0.98 | 1.08 | 1.07 |
| native n-hostisa-vb32-u2-nofma | 0.99 | 1.28 | 1.06 | 0.93 | 1.02 | 0.90 |
| native n-novec | 0.23 | 0.79 | 0.45 | 0.99 | 1.06 | 0.91 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 0.92 | 1.40 | 1.28 | 1.05 | 1.11 | 1.08 |
| native n-simd128-u4 | 1.00 | 1.64 | 1.27 | 1.12 | 0.99 | 0.93 |
| wasmtime scalar | 0.21 | 0.64 | 0.15 | 0.84 | 1.04 | 0.91 |
| wasmtime autovec | 0.86 | 0.64 | 0.41 | 0.78 | 1.00 | 0.88 |
| wasmtime simd | 0.92 | 1.06 | 0.46 | 0.78 | 1.02 | 0.86 |
| wasmtime simd-u2 | 0.80 | 1.16 | 0.46 | 0.76 | 1.02 | 0.93 |
| wasmtime simd-u4 | 0.95 | 1.29 | 0.43 | 0.80 | 1.07 | 0.89 |
| wasmtime simd-vb32 | 0.95 | 1.14 | 0.50 | 0.78 | 1.08 | 1.04 |
| wasmtime simd-vb32-u2 | 0.89 | 1.20 | 0.45 | 0.83 | 1.09 | 0.91 |
| wasmtime relaxed | 0.98 | 1.29 | 0.51 | 0.81 | 1.05 | 0.86 |
| wasmtime relaxed-u2 | 0.87 | 1.47 | 0.51 | 0.79 | 1.10 | 0.87 |

