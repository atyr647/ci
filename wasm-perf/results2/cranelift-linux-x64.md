## linux-x64: wasm-cranelift run 41062865273, commit dbdc717137800e142e3bb47ab3ff2cf094dc4131
cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
model name	: AMD EPYC 7763 64-Core Processor
fma avx avx2 bmi2 
Settings inferred for the current host:   has_avx   has_avx2   has_bmi1   has_bmi2   has_cmpxchg16b   has_fma   has_lzcnt   has_popcnt   has_sse3   has_sse41   has_sse42   has_ssse3 
### Phase A linux-x64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 2.07 | 2.79 | 0.29 | 412.77 | 3.27 |
| no AVX2/FMA (AVX only) | 2.04 | 2.81 | 0.33 | 345.21 | 3.28 |
| no AVX/AVX2/FMA (SSE4.2) | 2.66 | 2.78 | 0.38 | 360.19 | 3.28 |
| no FMA only | 2.06 | 2.79 | 0.29 | 343.13 | 3.27 |
| no BMI1/BMI2/LZCNT/POPCNT | 2.08 | 2.81 | 0.33 | 307.04 | 3.29 |
| SSE4.2 only + no bmi/lzcnt/popcnt | 2.66 | 2.78 | 0.38 | 306.97 | 3.29 |
| no SSE4.1/4.2 and no AVX (SSSE3 only) | 2.24 | 2.86 | 0.38 | 360.03 | 3.27 |
| opt-level=0 | 3.46 | 2.94 | 0.39 | 327.26 | 3.29 |
| opt-level=1 | 2.06 | 2.78 | 0.29 | 343.18 | 3.28 |
| opt-level=2 | 2.06 | 2.79 | 0.29 | 346.09 | 3.27 |
| opt-level=s | 2.06 | 2.79 | 0.28 | 348.09 | 3.27 |
| enable_heap_access_spectre_mitigation=false | 2.06 | 2.79 | 0.29 | 352.00 | 3.27 |
| enable_table_access_spectre_mitigation=false | 2.06 | 2.78 | 0.29 | 343.66 | 3.27 |
| enable_alias_analysis=false | 2.06 | 2.79 | 0.29 | 343.14 | 3.27 |
| unwind_info=false (no exception/backtrace data) | 2.06 | 2.78 | 0.29 | 346.31 | 3.27 |
| regalloc single-pass | 7.12 | 5.22 | 0.70 | 462.02 | 3.28 |
| explicit bounds checks (signals-based-traps=n) | 2.74 | 2.82 | 0.66 | 323.97 | 3.27 |
| dynamic memory (reservation 0, guard 0) | 3.36 | 2.88 | 0.54 | 322.16 | 3.27 |
| memory-may-move=y | 2.07 | 2.79 | 0.29 | 342.93 | 3.28 |
| memory-reservation=4GiB, guard=0 | 3.42 | 2.90 | 0.51 | 345.26 | 3.27 |
| fuel=1e15 | 5.12 | 3.56 | 0.76 | 221.28 | 3.28 |
| nan-canonicalization=y | 3.49 | 8.78 | 1.17 | 362.36 | 3.29 |
| inlining=y | 2.06 | 2.79 | 0.29 | 384.94 | 3.27 |
| winch (baseline compiler) | 7.51 | 5.59 | 0.82 | 417.78 | 3.28 |
| cwasm-baseline (--target only, no extra flags) | 2.66 | 2.78 | 0.41 | 307.51 | 3.29 |
| cwasm-host-default (compile without --target) | 2.06 | 2.79 | 0.28 | 344.49 | 3.28 |
| cwasm-haswell (preset) | 2.06 | 2.79 | 0.29 | 343.28 | 3.28 |
| cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt) | 2.04 | 2.79 | 0.26 | 342.90 | 3.27 |

speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| no AVX2/FMA (AVX only) | 1.01 | 0.99 | 0.88 | 1.20 | 1.00 |
| no AVX/AVX2/FMA (SSE4.2) | 0.78 | 1.00 | 0.75 | 1.15 | 1.00 |
| no FMA only | 1.00 | 1.00 | 0.99 | 1.20 | 1.00 |
| no BMI1/BMI2/LZCNT/POPCNT | 1.00 | 0.99 | 0.88 | 1.34 | 0.99 |
| SSE4.2 only + no bmi/lzcnt/popcnt | 0.78 | 1.00 | 0.75 | 1.34 | 0.99 |
| no SSE4.1/4.2 and no AVX (SSSE3 only) | 0.92 | 0.97 | 0.76 | 1.15 | 1.00 |
| opt-level=0 | 0.60 | 0.95 | 0.73 | 1.26 | 0.99 |
| opt-level=1 | 1.00 | 1.00 | 1.00 | 1.20 | 1.00 |
| opt-level=2 | 1.00 | 1.00 | 1.00 | 1.19 | 1.00 |
| opt-level=s | 1.00 | 1.00 | 1.00 | 1.19 | 1.00 |
| enable_heap_access_spectre_mitigation=false | 1.00 | 1.00 | 0.99 | 1.17 | 1.00 |
| enable_table_access_spectre_mitigation=false | 1.00 | 1.00 | 0.99 | 1.20 | 1.00 |
| enable_alias_analysis=false | 1.00 | 1.00 | 0.99 | 1.20 | 1.00 |
| unwind_info=false (no exception/backtrace data) | 1.00 | 1.00 | 0.99 | 1.19 | 1.00 |
| regalloc single-pass | 0.29 | 0.53 | 0.41 | 0.89 | 1.00 |
| explicit bounds checks (signals-based-traps=n) | 0.75 | 0.99 | 0.43 | 1.27 | 1.00 |
| dynamic memory (reservation 0, guard 0) | 0.62 | 0.97 | 0.53 | 1.28 | 1.00 |
| memory-may-move=y | 1.00 | 1.00 | 1.00 | 1.20 | 1.00 |
| memory-reservation=4GiB, guard=0 | 0.60 | 0.96 | 0.56 | 1.20 | 1.00 |
| fuel=1e15 | 0.40 | 0.78 | 0.38 | 1.87 | 1.00 |
| nan-canonicalization=y | 0.59 | 0.32 | 0.24 | 1.14 | 0.99 |
| inlining=y | 1.00 | 1.00 | 0.99 | 1.07 | 1.00 |
| winch (baseline compiler) | 0.28 | 0.50 | 0.35 | 0.99 | 1.00 |
| cwasm-baseline (--target only, no extra flags) | 0.78 | 1.00 | 0.70 | 1.34 | 0.99 |
| cwasm-host-default (compile without --target) | 1.00 | 1.00 | 1.00 | 1.20 | 1.00 |
| cwasm-haswell (preset) | 1.00 | 1.00 | 1.00 | 1.20 | 1.00 |
| cwasm-explicit-flags (sse41,sse42,avx,avx2,fma,bmi1,bmi2,lzcnt,popcnt) | 1.01 | 1.00 | 1.08 | 1.20 | 1.00 |

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
| native c-hostisa-auto | 1.05 | 4.81 | 0.40 | 168.78 | 3.28 | 65.40 |
| native c-hostisa-vb32-u2 | 0.92 | 1.20 | 0.21 | 174.13 | 3.29 | 65.51 |
| native c-hostisa-vb32-u2-nofma | 0.91 | 1.27 | 0.24 | 240.60 | 3.28 | 65.66 |
| native c-scalar | 1.65 | 5.14 | 0.40 | 129.09 | 3.27 | 65.44 |
| native n-hostisa-auto | 0.69 | 1.22 | 0.17 | 145.67 | 3.28 | 82.90 |
| native n-hostisa-simd128 | 1.35 | 2.53 | 0.35 | 172.76 | 3.28 | 81.88 |
| native n-hostisa-simd128-u4 | 1.23 | 2.40 | 0.35 | 175.95 | 3.28 | 82.38 |
| native n-hostisa-simd128-u4-nofma | 1.17 | 2.51 | 0.35 | 149.94 | 3.28 | 82.90 |
| native n-hostisa-vb32-u2 | 1.03 | 1.27 | 0.35 | 146.99 | 3.28 | 82.48 |
| native n-hostisa-vb32-u2-nofma | 1.03 | 1.31 | 0.35 | 152.77 | 3.29 | 82.16 |
| native n-novec | 7.38 | 5.15 | 0.87 | 169.83 | 3.27 | 82.84 |
| native n-scalar | 1.34 | 2.77 | 0.30 | 166.73 | 3.27 | 82.23 |
| native n-simd128 | 2.67 | 2.71 | 0.35 | 184.08 | 3.27 | 82.08 |
| native n-simd128-u4 | 1.65 | 2.51 | 0.35 | 148.92 | 3.27 | 82.41 |
| wasmtime scalar | 8.22 | 5.27 | 0.85 | 230.65 | 3.27 | 70.66 |
| wasmtime autovec | 2.34 | 5.23 | 0.73 | 355.60 | 3.28 | 70.09 |
| wasmtime simd | 2.06 | 2.79 | 0.29 | 343.11 | 3.27 | 70.20 |
| wasmtime simd-u2 | 2.66 | 2.75 | 0.29 | 355.71 | 3.27 | 70.22 |
| wasmtime simd-u4 | 2.18 | 2.75 | 0.29 | 343.48 | 3.28 | 70.01 |
| wasmtime simd-vb32 | 1.72 | 2.84 | 0.27 | 361.86 | 3.29 | 70.80 |
| wasmtime simd-vb32-u2 | 1.94 | 2.75 | 0.27 | 361.48 | 3.28 | 70.86 |
| wasmtime relaxed | 2.06 | 2.58 | 0.28 | 359.73 | 3.28 | 70.72 |
| wasmtime relaxed-u2 | 2.34 | 2.54 | 0.33 | 360.18 | 3.27 | 70.51 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 1.28 | 0.58 | 0.76 | 0.99 | 1.00 | 1.26 |
| native c-hostisa-vb32-u2 | 1.46 | 2.32 | 1.45 | 0.96 | 1.00 | 1.26 |
| native c-hostisa-vb32-u2-nofma | 1.48 | 2.19 | 1.25 | 0.69 | 1.00 | 1.25 |
| native c-scalar | 0.82 | 0.54 | 0.77 | 1.29 | 1.00 | 1.26 |
| native n-hostisa-auto | 1.96 | 2.27 | 1.75 | 1.14 | 1.00 | 0.99 |
| native n-hostisa-simd128 | 0.99 | 1.10 | 0.86 | 0.97 | 1.00 | 1.00 |
| native n-hostisa-simd128-u4 | 1.09 | 1.16 | 0.87 | 0.95 | 1.00 | 1.00 |
| native n-hostisa-simd128-u4-nofma | 1.14 | 1.10 | 0.86 | 1.11 | 1.00 | 0.99 |
| native n-hostisa-vb32-u2 | 1.30 | 2.18 | 0.86 | 1.13 | 1.00 | 1.00 |
| native n-hostisa-vb32-u2-nofma | 1.30 | 2.12 | 0.86 | 1.09 | 1.00 | 1.00 |
| native n-novec | 0.18 | 0.54 | 0.35 | 0.98 | 1.00 | 0.99 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 0.50 | 1.03 | 0.86 | 0.91 | 1.00 | 1.00 |
| native n-simd128-u4 | 0.81 | 1.10 | 0.86 | 1.12 | 1.00 | 1.00 |
| wasmtime scalar | 0.16 | 0.53 | 0.36 | 0.72 | 1.00 | 1.16 |
| wasmtime autovec | 0.57 | 0.53 | 0.42 | 0.47 | 1.00 | 1.17 |
| wasmtime simd | 0.65 | 1.00 | 1.05 | 0.49 | 1.00 | 1.17 |
| wasmtime simd-u2 | 0.51 | 1.01 | 1.06 | 0.47 | 1.00 | 1.17 |
| wasmtime simd-u4 | 0.62 | 1.01 | 1.07 | 0.49 | 1.00 | 1.17 |
| wasmtime simd-vb32 | 0.78 | 0.98 | 1.13 | 0.46 | 0.99 | 1.16 |
| wasmtime simd-vb32-u2 | 0.69 | 1.01 | 1.15 | 0.46 | 1.00 | 1.16 |
| wasmtime relaxed | 0.65 | 1.07 | 1.10 | 0.46 | 1.00 | 1.16 |
| wasmtime relaxed-u2 | 0.57 | 1.09 | 0.94 | 0.46 | 1.00 | 1.17 |

