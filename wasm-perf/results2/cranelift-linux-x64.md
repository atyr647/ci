## linux-x64: wasm-cranelift run 41061030677, commit 1f76ef6f374a1af3de6857b416a9e17ac9fd951d
cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
model name	: AMD EPYC 7763 64-Core Processor
fma avx avx2 bmi2 
Settings inferred for the current host:   has_avx   has_avx2   has_bmi1   has_bmi2   has_cmpxchg16b   has_fma   has_lzcnt   has_popcnt   has_sse3   has_sse41   has_sse42   has_ssse3 
### Phase A linux-x64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 2.06 | 2.78 | 0.28 | 342.76 | 3.27 |
| no AVX2/FMA (AVX only) | 2.03 | 2.80 | 0.33 | 342.99 | 3.27 |
| no AVX/AVX2/FMA (SSE4.2) | 2.66 | 2.78 | 0.38 | 351.45 | 3.27 |
| no FMA only | 2.06 | 2.79 | 0.28 | 344.24 | 3.27 |
| no BMI1/BMI2/LZCNT/POPCNT | 2.07 | 2.81 | 0.33 | 308.56 | 3.28 |
| SSE4.2 only + no bmi/lzcnt/popcnt | 2.66 | 2.78 | 0.38 | 310.70 | 3.30 |
| no SSE4.1/4.2 and no AVX (SSSE3 only) | 2.24 | 2.86 | 0.38 | 362.71 | 3.27 |
| opt-level=0 | 3.48 | 2.94 | 0.39 | 322.23 | 3.29 |
| opt-level=1 | 2.06 | 2.78 | 0.28 | 342.45 | 3.27 |
| opt-level=2 | 2.06 | 2.79 | 0.29 | 342.97 | 3.27 |
| opt-level=s | 2.06 | 2.78 | 0.28 | 343.22 | 3.27 |
| regalloc single-pass | 7.10 | 5.22 | 0.68 | 459.95 | 3.28 |
| explicit bounds checks (signals-based-traps=n) | 2.74 | 2.82 | 0.66 | 326.11 | 3.27 |
| dynamic memory (reservation 0, guard 0) | 3.36 | 2.88 | 0.56 | 405.53 | 3.27 |
| memory-may-move=y | 2.06 | 2.79 | 0.29 | 344.15 | 3.27 |
| memory-reservation=4GiB, guard=0 | 3.44 | 2.90 | 0.51 | 354.31 | 3.27 |
| fuel=1e15 | 5.10 | 3.57 | 0.77 | 209.70 | 3.28 |
| nan-canonicalization=y | 3.48 | 8.77 | 1.16 | 359.77 | 3.29 |
| inlining=y | 2.06 | 2.79 | 0.29 | 345.48 | 3.27 |
| winch (baseline compiler) | 7.59 | 5.59 | 0.82 | 355.31 | 3.27 |
| cwasm-baseline (--target only, no extra flags) | 2.66 | 2.78 | 0.41 | 308.20 | 3.28 |
| cwasm-host-default (compile without --target) | 2.07 | 2.79 | 0.29 | 344.50 | 3.27 |
| cwasm-haswell (preset) | 2.06 | 2.79 | 0.28 | 342.34 | 3.27 |
| cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt) | 2.04 | 2.79 | 0.27 | 342.86 | 3.27 |

speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| no AVX2/FMA (AVX only) | 1.02 | 0.99 | 0.87 | 1.00 | 1.00 |
| no AVX/AVX2/FMA (SSE4.2) | 0.78 | 1.00 | 0.75 | 0.98 | 1.00 |
| no FMA only | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| no BMI1/BMI2/LZCNT/POPCNT | 1.00 | 0.99 | 0.87 | 1.11 | 1.00 |
| SSE4.2 only + no bmi/lzcnt/popcnt | 0.78 | 1.00 | 0.75 | 1.10 | 0.99 |
| no SSE4.1/4.2 and no AVX (SSSE3 only) | 0.92 | 0.97 | 0.75 | 0.94 | 1.00 |
| opt-level=0 | 0.59 | 0.95 | 0.73 | 1.06 | 0.99 |
| opt-level=1 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=2 | 1.00 | 1.00 | 0.99 | 1.00 | 1.00 |
| opt-level=s | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| regalloc single-pass | 0.29 | 0.53 | 0.42 | 0.75 | 1.00 |
| explicit bounds checks (signals-based-traps=n) | 0.75 | 0.99 | 0.43 | 1.05 | 1.00 |
| dynamic memory (reservation 0, guard 0) | 0.61 | 0.96 | 0.51 | 0.85 | 1.00 |
| memory-may-move=y | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| memory-reservation=4GiB, guard=0 | 0.60 | 0.96 | 0.56 | 0.97 | 1.00 |
| fuel=1e15 | 0.40 | 0.78 | 0.37 | 1.63 | 1.00 |
| nan-canonicalization=y | 0.59 | 0.32 | 0.25 | 0.95 | 0.99 |
| inlining=y | 1.00 | 1.00 | 0.99 | 0.99 | 1.00 |
| winch (baseline compiler) | 0.27 | 0.50 | 0.35 | 0.96 | 1.00 |
| cwasm-baseline (--target only, no extra flags) | 0.78 | 1.00 | 0.70 | 1.11 | 1.00 |
| cwasm-host-default (compile without --target) | 1.00 | 1.00 | 1.00 | 0.99 | 1.00 |
| cwasm-haswell (preset) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt) | 1.01 | 1.00 | 1.06 | 1.00 | 1.00 |

== simd: total instructions host=13308 baseline-target=13560
   host: VEX(v*)=594 vfmadd/vfnmadd=0 packed-single/double mul+add=46 ymm-or-zmm operands=0
   base: VEX(v*)=0 vfmadd/vfnmadd=0 packed-single/double mul+add=46 ymm-or-zmm operands=0
== relaxed: total instructions host=13306 baseline-target=13560
   host: VEX(v*)=576 vfmadd/vfnmadd=18 packed-single/double mul+add=10 ymm-or-zmm operands=0
   base: VEX(v*)=0 vfmadd/vfnmadd=0 packed-single/double mul+add=46 ymm-or-zmm operands=0
== simd-vb32-u2: total instructions host=13507 baseline-target=13783
   host: VEX(v*)=709 vfmadd/vfnmadd=0 packed-single/double mul+add=113 ymm-or-zmm operands=0
   base: VEX(v*)=0 vfmadd/vfnmadd=0 packed-single/double mul+add=113 ymm-or-zmm operands=0
top mnemonics, host, simd:
 5898 mov; 816 add; 620 lea; 573 cmp; 571 jmp; 476 test; 329 je; 319 call; 270 sub; 229 jne; 198 and; 189 xor; 144 ...; 139 pop; 137 ud2; 137 ret; 126 or; 116 ja; 103 push; 99 movzbq; 93 shr; 78 vxorpd;
### Phase B linux-x64: wasm source variants vs native (ref = native scalar, baseline ISA): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 1.08 | 4.81 | 0.40 | 170.06 | 3.27 | 65.26 |
| native c-hostisa-vb32-u2 | 0.92 | 1.20 | 0.21 | 172.66 | 3.28 | 65.33 |
| native c-hostisa-vb32-u2-nofma | 0.83 | 1.27 | 0.28 | 247.03 | 3.27 | 65.59 |
| native c-scalar | 1.64 | 5.14 | 0.40 | 124.99 | 3.27 | 65.41 |
| native n-hostisa-auto | 0.69 | 1.22 | 0.16 | 146.03 | 3.27 | 82.77 |
| native n-hostisa-simd128 | 1.44 | 2.53 | 0.35 | 168.72 | 3.27 | 81.68 |
| native n-hostisa-simd128-u4 | 1.19 | 2.40 | 0.35 | 175.24 | 3.28 | 82.28 |
| native n-hostisa-simd128-u4-nofma | 1.17 | 2.51 | 0.35 | 151.40 | 3.29 | 82.75 |
| native n-hostisa-vb32-u2 | 0.92 | 1.27 | 0.35 | 148.69 | 3.28 | 82.36 |
| native n-hostisa-vb32-u2-nofma | 1.02 | 1.31 | 0.35 | 152.95 | 3.28 | 82.06 |
| native n-novec | 7.38 | 5.15 | 0.87 | 170.50 | 3.28 | 82.78 |
| native n-scalar | 1.34 | 2.77 | 0.31 | 170.32 | 3.27 | 82.12 |
| native n-simd128 | 2.67 | 2.71 | 0.35 | 185.16 | 3.27 | 82.01 |
| native n-simd128-u4 | 1.60 | 2.51 | 0.35 | 150.30 | 3.27 | 82.26 |
| wasmtime scalar | 8.22 | 5.27 | 0.87 | 215.89 | 3.27 | 70.57 |
| wasmtime autovec | 2.34 | 5.23 | 0.73 | 351.78 | 3.29 | 70.00 |
| wasmtime simd | 2.06 | 2.78 | 0.29 | 342.90 | 3.28 | 70.08 |
| wasmtime simd-u2 | 2.65 | 2.75 | 0.29 | 373.84 | 3.27 | 70.11 |
| wasmtime simd-u4 | 2.17 | 2.75 | 0.29 | 363.38 | 3.27 | 70.09 |
| wasmtime simd-vb32 | 1.72 | 2.85 | 0.27 | 382.46 | 3.28 | 70.50 |
| wasmtime simd-vb32-u2 | 1.94 | 2.75 | 0.27 | 362.85 | 3.27 | 70.59 |
| wasmtime relaxed | 2.06 | 2.58 | 0.28 | 359.70 | 3.28 | 70.47 |
| wasmtime relaxed-u2 | 2.34 | 2.54 | 0.33 | 359.29 | 3.27 | 70.63 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 1.25 | 0.58 | 0.77 | 1.00 | 1.00 | 1.26 |
| native c-hostisa-vb32-u2 | 1.46 | 2.32 | 1.47 | 0.99 | 1.00 | 1.26 |
| native c-hostisa-vb32-u2-nofma | 1.62 | 2.19 | 1.11 | 0.69 | 1.00 | 1.25 |
| native c-scalar | 0.82 | 0.54 | 0.76 | 1.36 | 1.00 | 1.26 |
| native n-hostisa-auto | 1.95 | 2.27 | 1.90 | 1.17 | 1.00 | 0.99 |
| native n-hostisa-simd128 | 0.94 | 1.10 | 0.87 | 1.01 | 1.00 | 1.01 |
| native n-hostisa-simd128-u4 | 1.13 | 1.16 | 0.87 | 0.97 | 0.99 | 1.00 |
| native n-hostisa-simd128-u4-nofma | 1.15 | 1.10 | 0.87 | 1.12 | 0.99 | 0.99 |
| native n-hostisa-vb32-u2 | 1.46 | 2.18 | 0.87 | 1.15 | 1.00 | 1.00 |
| native n-hostisa-vb32-u2-nofma | 1.31 | 2.11 | 0.87 | 1.11 | 1.00 | 1.00 |
| native n-novec | 0.18 | 0.54 | 0.35 | 1.00 | 1.00 | 0.99 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 0.50 | 1.03 | 0.87 | 0.92 | 1.00 | 1.00 |
| native n-simd128-u4 | 0.84 | 1.10 | 0.87 | 1.13 | 1.00 | 1.00 |
| wasmtime scalar | 0.16 | 0.53 | 0.35 | 0.79 | 1.00 | 1.16 |
| wasmtime autovec | 0.58 | 0.53 | 0.42 | 0.48 | 0.99 | 1.17 |
| wasmtime simd | 0.65 | 1.00 | 1.06 | 0.50 | 1.00 | 1.17 |
| wasmtime simd-u2 | 0.51 | 1.01 | 1.06 | 0.46 | 1.00 | 1.17 |
| wasmtime simd-u4 | 0.62 | 1.01 | 1.06 | 0.47 | 1.00 | 1.17 |
| wasmtime simd-vb32 | 0.78 | 0.98 | 1.13 | 0.45 | 0.99 | 1.16 |
| wasmtime simd-vb32-u2 | 0.69 | 1.01 | 1.13 | 0.47 | 1.00 | 1.16 |
| wasmtime relaxed | 0.65 | 1.07 | 1.11 | 0.47 | 1.00 | 1.17 |
| wasmtime relaxed-u2 | 0.58 | 1.09 | 0.94 | 0.47 | 1.00 | 1.16 |

