

(grep -m1 -o 'flags.*\|Features.*' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx|avx2|fma|bmi2|avx512f|asimd|sve|sve2|asimddp|bf16|i8mm|fphp)$' | tr '\n' ' ') 2>/dev/null || true; echo
model name	: AMD EPYC 9V45 96-Core Processor
fma avx avx2 bmi2 avx512f 
Settings inferred for the current host:   has_avx   has_avx2   has_avx512bitalg   has_avx512dq   has_avx512f   has_avx512vbmi   has_avx512vl   has_avx512vnni   has_avx_vnni   has_bmi1   has_bmi2   has_cmpxchg16b   has_fma   has_lzcnt   has_popcnt   has_sse3   
compile cwasm-baseline (--target only, no extra flags): rc=0 
probe preset -C cranelift-x86-64-v3: rc=1 Error: No existing setting named 'x86_64_v3'
probe preset -C cranelift-x86_64_v3: rc=1 Error: No existing setting named 'x86_64_v3'
probe preset -C cranelift-haswell: rc=0 
compile cwasm-haswell (preset): rc=0 
compile cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt): rc=0 
24 configurations
### Phase A linux-x64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)
| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.20 | 1.66 | 0.17 | 90.89 | 2.53 |
| no AVX2/FMA (AVX only) | 1.19 | 1.67 | 0.17 | 90.70 | 2.51 |
| no AVX/AVX2/FMA (SSE4.2) | 1.20 | 1.67 | 0.17 | 90.38 | 2.55 |
| no FMA only | 1.21 | 1.69 | 0.18 | 90.66 | 2.52 |
| no BMI1/BMI2/LZCNT/POPCNT | 1.20 | 1.68 | 0.17 | 90.36 | 2.52 |
| SSE4.2 only + no bmi/lzcnt/popcnt | 1.21 | 1.68 | 0.19 | 90.63 | 2.50 |
| no SSE4.1/4.2 and no AVX (SSSE3 only) | 1.19 | 1.67 | 0.18 | 90.54 | 2.51 |
| opt-level=0 | 1.90 | 1.70 | 0.23 | 89.35 | 2.53 |
| opt-level=1 | 1.20 | 1.67 | 0.18 | 90.58 | 2.56 |
| opt-level=2 | 1.20 | 1.68 | 0.17 | 91.02 | 2.51 |
| opt-level=s | 1.20 | 1.67 | 0.17 | 90.17 | 2.48 |
| regalloc single-pass | 3.75 | 2.66 | 0.42 | 144.45 | 2.57 |
| explicit bounds checks (signals-based-traps=n) | 1.54 | 1.67 | 0.47 | 86.45 | 2.53 |
| dynamic memory (reservation 0, guard 0) | 2.76 | 1.68 | 0.43 | 111.15 | 2.52 |
| memory-may-move=y | 1.19 | 1.68 | 0.19 | 90.55 | 2.50 |
| memory-reservation=4GiB, guard=0 | 2.72 | 1.67 | 0.43 | 107.80 | 2.53 |
| epoch-interruption=y | - | - | - | - | - |  <- FAILED: Error: failed to run main module `so/so-simd.wasm`
| fuel=1e15 | 3.17 | 1.85 | 0.56 | 96.21 | 2.48 |
| nan-canonicalization=y | 2.08 | 5.90 | 0.56 | 76.11 | 2.62 |
| inlining=y | 1.19 | 1.66 | 0.17 | 89.27 | 2.49 |
| winch (baseline compiler) | 4.17 | 2.58 | 0.45 | 112.91 | 2.60 |
| cwasm-baseline (--target only, no extra flags) | 1.49 | 1.77 | 0.26 | 75.36 | 2.45 |
| cwasm-haswell (preset) | 1.18 | 1.65 | 0.18 | 75.44 | 2.49 |
| cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt) | 1.50 | 1.78 | 0.25 | 75.99 | 2.49 |
speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row
| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| no AVX2/FMA (AVX only) | 1.01 | 0.99 | 1.02 | 1.00 | 1.01 |
| no AVX/AVX2/FMA (SSE4.2) | 1.00 | 0.99 | 1.02 | 1.01 | 0.99 |
| no FMA only | 0.99 | 0.98 | 0.99 | 1.00 | 1.00 |
| no BMI1/BMI2/LZCNT/POPCNT | 1.00 | 0.99 | 1.05 | 1.01 | 1.00 |
| SSE4.2 only + no bmi/lzcnt/popcnt | 1.00 | 0.99 | 0.94 | 1.00 | 1.01 |
| no SSE4.1/4.2 and no AVX (SSSE3 only) | 1.01 | 0.99 | 0.98 | 1.00 | 1.01 |
| opt-level=0 | 0.63 | 0.97 | 0.77 | 1.02 | 1.00 |
| opt-level=1 | 1.00 | 0.99 | 0.97 | 1.00 | 0.99 |
| opt-level=2 | 1.00 | 0.99 | 1.01 | 1.00 | 1.01 |
| opt-level=s | 1.00 | 0.99 | 1.01 | 1.01 | 1.02 |
| regalloc single-pass | 0.32 | 0.62 | 0.42 | 0.63 | 0.98 |
| explicit bounds checks (signals-based-traps=n) | 0.78 | 0.99 | 0.37 | 1.05 | 1.00 |
| dynamic memory (reservation 0, guard 0) | 0.44 | 0.99 | 0.40 | 0.82 | 1.00 |
| memory-may-move=y | 1.01 | 0.99 | 0.92 | 1.00 | 1.01 |
| memory-reservation=4GiB, guard=0 | 0.44 | 0.99 | 0.41 | 0.84 | 1.00 |
| epoch-interruption=y | - | - | - | - | - |
| fuel=1e15 | 0.38 | 0.90 | 0.31 | 0.94 | 1.02 |
| nan-canonicalization=y | 0.58 | 0.28 | 0.31 | 1.19 | 0.97 |
| inlining=y | 1.01 | 1.00 | 1.02 | 1.02 | 1.02 |
| winch (baseline compiler) | 0.29 | 0.64 | 0.39 | 0.80 | 0.97 |
| cwasm-baseline (--target only, no extra flags) | 0.81 | 0.94 | 0.68 | 1.21 | 1.03 |
| cwasm-haswell (preset) | 1.01 | 1.01 | 0.97 | 1.20 | 1.01 |
| cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt) | 0.80 | 0.93 | 0.69 | 1.20 | 1.01 |
### Phase B linux-x64: wasm source variants vs native (ref = native scalar, baseline ISA): ms per kernel (best of 3 interleaved rounds)
| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 0.33 | 3.16 | 0.08 | 56.60 | 2.47 | 56.92 |
| native c-hostisa-vb32-u2 | 0.43 | 0.80 | 0.15 | 66.99 | 2.48 | 55.72 |
| native c-hostisa-vb32-u2-nofma | 0.46 | 0.80 | 0.16 | 68.32 | 2.49 | 56.38 |
| native c-scalar | 1.22 | 3.13 | 0.27 | 55.21 | 2.48 | 57.38 |
| native n-hostisa-auto | 0.48 | 0.40 | 0.07 | 68.60 | 2.50 | 68.44 |
| native n-hostisa-simd128 | 0.98 | 1.59 | 0.26 | 71.52 | 2.51 | 69.13 |
| native n-hostisa-simd128-u4 | 0.84 | 1.59 | 0.26 | 74.70 | 2.55 | 72.33 |
| native n-hostisa-simd128-u4-nofma | 0.82 | 1.61 | 0.26 | 70.31 | 2.52 | 71.97 |
| native n-hostisa-vb32-u2 | 0.46 | 0.79 | 0.26 | 68.98 | 2.52 | 68.75 |
| native n-hostisa-vb32-u2-nofma | 0.62 | 0.81 | 0.26 | 67.33 | 2.54 | 69.52 |
| native n-novec | 4.39 | 3.19 | 0.66 | 71.04 | 2.50 | 68.63 |
| native n-scalar | 0.99 | 1.63 | 0.19 | 70.76 | 2.52 | 68.26 |
| native n-simd128 | 2.00 | 1.63 | 0.25 | 79.69 | 2.46 | 69.50 |
| native n-simd128-u4 | 0.98 | 1.58 | 0.25 | 69.29 | 2.51 | 68.29 |
| wasmtime scalar | 4.89 | 3.23 | 0.65 | 84.01 | 2.50 | 58.20 |
| wasmtime autovec | 1.32 | 3.23 | 0.31 | 89.58 | 2.48 | 57.95 |
| wasmtime simd | 1.20 | 1.68 | 0.18 | 90.50 | 2.57 | 59.27 |
| wasmtime simd-u2 | 1.33 | 1.65 | 0.17 | 79.78 | 2.52 | 59.30 |
| wasmtime simd-u4 | 1.26 | 1.63 | 0.17 | 88.84 | 2.54 | 59.07 |
| wasmtime simd-vb32 | 1.12 | 1.63 | 0.19 | 75.94 | 2.51 | 58.40 |
| wasmtime simd-vb32-u2 | 1.23 | 1.62 | 0.18 | 88.81 | 2.49 | 58.96 |
| wasmtime relaxed | 1.19 | 1.59 | 0.18 | 89.95 | 2.51 | 59.08 |
| wasmtime relaxed-u2 | 1.31 | 1.59 | 0.17 | 91.53 | 2.52 | 58.85 |
speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row
| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 3.00 | 0.52 | 2.39 | 1.25 | 1.02 | 1.20 |
| native c-hostisa-vb32-u2 | 2.28 | 2.05 | 1.25 | 1.06 | 1.01 | 1.23 |
| native c-hostisa-vb32-u2-nofma | 2.15 | 2.05 | 1.20 | 1.04 | 1.01 | 1.21 |
| native c-scalar | 0.81 | 0.52 | 0.72 | 1.28 | 1.01 | 1.19 |
| native n-hostisa-auto | 2.05 | 4.12 | 2.85 | 1.03 | 1.01 | 1.00 |
| native n-hostisa-simd128 | 1.01 | 1.03 | 0.75 | 0.99 | 1.00 | 0.99 |
| native n-hostisa-simd128-u4 | 1.18 | 1.03 | 0.74 | 0.95 | 0.99 | 0.94 |
| native n-hostisa-simd128-u4-nofma | 1.21 | 1.01 | 0.73 | 1.01 | 1.00 | 0.95 |
| native n-hostisa-vb32-u2 | 2.13 | 2.06 | 0.75 | 1.03 | 1.00 | 0.99 |
| native n-hostisa-vb32-u2-nofma | 1.60 | 2.01 | 0.73 | 1.05 | 0.99 | 0.98 |
| native n-novec | 0.23 | 0.51 | 0.29 | 1.00 | 1.01 | 0.99 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 0.49 | 1.00 | 0.76 | 0.89 | 1.02 | 0.98 |
| native n-simd128-u4 | 1.01 | 1.03 | 0.75 | 1.02 | 1.00 | 1.00 |
| wasmtime scalar | 0.20 | 0.51 | 0.29 | 0.84 | 1.00 | 1.17 |
| wasmtime autovec | 0.75 | 0.50 | 0.62 | 0.79 | 1.02 | 1.18 |
| wasmtime simd | 0.82 | 0.97 | 1.07 | 0.78 | 0.98 | 1.15 |
| wasmtime simd-u2 | 0.75 | 0.99 | 1.10 | 0.89 | 1.00 | 1.15 |
| wasmtime simd-u4 | 0.79 | 1.00 | 1.09 | 0.80 | 0.99 | 1.16 |
| wasmtime simd-vb32 | 0.88 | 1.00 | 1.03 | 0.93 | 1.00 | 1.17 |
| wasmtime simd-vb32-u2 | 0.81 | 1.01 | 1.07 | 0.80 | 1.01 | 1.16 |
| wasmtime relaxed | 0.83 | 1.03 | 1.09 | 0.79 | 1.00 | 1.16 |
| wasmtime relaxed-u2 | 0.75 | 1.03 | 1.10 | 0.77 | 1.00 | 1.16 |
