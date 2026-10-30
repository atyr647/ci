## linux-arm64: wasm-cranelift run 41062865273, commit dbdc717137800e142e3bb47ab3ff2cf094dc4131
cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
asimd fphp asimddp sve sve2 i8mm bf16 
Settings inferred for the current host:   has_dotprod   has_fp16   has_i8mm   has_lse   has_pauth 
### Phase A linux-arm64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 2.06 | 4.04 | 0.59 | 128.12 | 2.50 |
| opt-level=0 | 3.40 | 4.04 | 0.66 | 147.80 | 2.62 |
| opt-level=1 | 2.05 | 4.04 | 0.59 | 128.00 | 2.50 |
| opt-level=2 | 2.05 | 4.04 | 0.59 | 128.00 | 2.50 |
| opt-level=s | 2.05 | 4.04 | 0.59 | 128.08 | 2.50 |
| enable_heap_access_spectre_mitigation=false | 2.06 | 4.04 | 0.59 | 127.99 | 2.50 |
| enable_table_access_spectre_mitigation=false | 2.07 | 4.04 | 0.59 | 128.01 | 2.50 |
| enable_alias_analysis=false | 2.06 | 4.04 | 0.58 | 128.15 | 2.50 |
| unwind_info=false (no exception/backtrace data) | 2.05 | 4.04 | 0.58 | 128.06 | 2.50 |
| regalloc single-pass | 7.80 | 4.64 | 0.89 | 448.93 | 7.13 |
| explicit bounds checks (signals-based-traps=n) | 3.49 | 3.93 | 0.78 | 155.78 | 2.52 |
| dynamic memory (reservation 0, guard 0) | 4.05 | 4.12 | 0.87 | 168.01 | 2.66 |
| memory-may-move=y | 2.05 | 4.04 | 0.58 | 128.11 | 2.50 |
| memory-reservation=4GiB, guard=0 | 4.16 | 4.14 | 0.85 | 170.01 | 2.65 |
| fuel=1e15 | 3.75 | 4.21 | 0.76 | 176.70 | 2.51 |
| nan-canonicalization=y | 9.54 | 27.89 | 2.45 | 128.09 | 2.51 |
| inlining=y | 2.05 | 4.04 | 0.59 | 128.12 | 2.51 |
| winch (baseline compiler) | 7.21 | 5.91 | 0.94 | 246.34 | 4.05 |
| cwasm-baseline (--target only, no extra flags) | 2.05 | 4.04 | 0.59 | 128.18 | 2.51 |
| cwasm-host-default (compile without --target) | 2.05 | 4.04 | 0.59 | 127.97 | 2.50 |

speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=0 | 0.61 | 1.00 | 0.89 | 0.87 | 0.95 |
| opt-level=1 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=2 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=s | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| enable_heap_access_spectre_mitigation=false | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| enable_table_access_spectre_mitigation=false | 0.99 | 1.00 | 1.00 | 1.00 | 1.00 |
| enable_alias_analysis=false | 1.00 | 1.00 | 1.01 | 1.00 | 1.00 |
| unwind_info=false (no exception/backtrace data) | 1.00 | 1.00 | 1.01 | 1.00 | 1.00 |
| regalloc single-pass | 0.26 | 0.87 | 0.66 | 0.29 | 0.35 |
| explicit bounds checks (signals-based-traps=n) | 0.59 | 1.03 | 0.76 | 0.82 | 0.99 |
| dynamic memory (reservation 0, guard 0) | 0.51 | 0.98 | 0.68 | 0.76 | 0.94 |
| memory-may-move=y | 1.00 | 1.00 | 1.01 | 1.00 | 1.00 |
| memory-reservation=4GiB, guard=0 | 0.49 | 0.97 | 0.69 | 0.75 | 0.94 |
| fuel=1e15 | 0.55 | 0.96 | 0.77 | 0.73 | 1.00 |
| nan-canonicalization=y | 0.22 | 0.14 | 0.24 | 1.00 | 1.00 |
| inlining=y | 1.00 | 1.00 | 0.99 | 1.00 | 1.00 |
| winch (baseline compiler) | 0.29 | 0.68 | 0.63 | 0.52 | 0.62 |
| cwasm-baseline (--target only, no extra flags) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| cwasm-host-default (compile without --target) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |

== simd: total instructions host=12171 baseline-target=12171
   fmla=0 fmul=73 fadd=61 ldr=992 ldp=324
== relaxed: total instructions host=12157 baseline-target=12157
   fmla=18 fmul=55 fadd=43 ldr=992 ldp=324
== simd-vb32-u2: total instructions host=12403 baseline-target=12403
   fmla=0 fmul=111 fadd=90 ldr=1071 ldp=328
top mnemonics, host, simd:
 2886 mov; 992 ldr; 953 add; 664 str; 638 cmp; 521 movk; 514 b; 502 ldur; 453 sub; 342 stur; 324 ldp; 261 bl; 247 udf; 238 and; 216 stp; 175 cbz; 150 cbnz; 137 ret; 136 csel; 125 lsr; 112 orr; 100 b.eq;
### Phase B linux-arm64: wasm source variants vs native (ref = native scalar, baseline ISA): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 1.81 | 4.04 | 0.39 | 77.13 | 2.49 | 45.69 |
| native c-hostisa-vb32-u2 | 1.83 | 3.77 | 0.25 | 77.09 | 2.49 | 45.38 |
| native c-hostisa-vb32-u2-nofma | 1.91 | 4.02 | 0.33 | 77.16 | 2.50 | 45.66 |
| native c-scalar | 1.82 | 4.10 | 0.38 | 74.78 | 2.50 | 45.45 |
| native n-hostisa-auto | 1.63 | 4.04 | 0.43 | 77.22 | 2.58 | 55.62 |
| native n-hostisa-simd128 | 1.65 | 3.79 | 0.34 | 75.07 | 2.51 | 55.75 |
| native n-hostisa-simd128-u4 | 1.50 | 3.93 | 0.35 | 75.99 | 2.52 | 55.58 |
| native n-hostisa-simd128-u4-nofma | 1.68 | 3.96 | 0.42 | 75.12 | 2.52 | 55.56 |
| native n-hostisa-vb32-u2 | 5.90 | 4.82 | 0.34 | 76.51 | 2.53 | 55.72 |
| native n-hostisa-vb32-u2-nofma | 5.71 | 4.58 | 0.42 | 80.28 | 2.53 | 55.60 |
| native n-novec | 6.97 | 4.06 | 0.80 | 87.01 | 2.53 | 54.94 |
| native n-scalar | 1.64 | 3.77 | 0.44 | 77.38 | 2.52 | 54.83 |
| native n-simd128 | 1.64 | 3.78 | 0.34 | 89.00 | 2.49 | 54.94 |
| native n-simd128-u4 | 1.49 | 3.83 | 0.34 | 76.04 | 2.48 | 54.89 |
| wasmtime scalar | 8.95 | 5.07 | 2.07 | 128.10 | 2.51 | 50.80 |
| wasmtime autovec | 2.28 | 5.08 | 1.11 | 128.01 | 2.50 | 50.94 |
| wasmtime simd | 2.05 | 4.04 | 0.58 | 128.00 | 2.50 | 50.58 |
| wasmtime simd-u2 | 2.27 | 4.02 | 0.59 | 127.99 | 2.50 | 50.85 |
| wasmtime simd-u4 | 2.05 | 3.94 | 0.59 | 127.95 | 2.49 | 51.00 |
| wasmtime simd-vb32 | 2.02 | 3.98 | 0.59 | 127.96 | 2.50 | 50.95 |
| wasmtime simd-vb32-u2 | 2.06 | 3.99 | 0.59 | 127.96 | 2.50 | 50.89 |
| wasmtime relaxed | 1.88 | 3.83 | 0.55 | 127.97 | 2.50 | 50.73 |
| wasmtime relaxed-u2 | 2.03 | 3.78 | 0.55 | 128.03 | 2.51 | 50.74 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 0.90 | 0.94 | 1.12 | 1.00 | 1.01 | 1.20 |
| native c-hostisa-vb32-u2 | 0.90 | 1.00 | 1.74 | 1.00 | 1.01 | 1.21 |
| native c-hostisa-vb32-u2-nofma | 0.86 | 0.94 | 1.34 | 1.00 | 1.01 | 1.20 |
| native c-scalar | 0.90 | 0.92 | 1.14 | 1.03 | 1.01 | 1.21 |
| native n-hostisa-auto | 1.00 | 0.93 | 1.01 | 1.00 | 0.98 | 0.99 |
| native n-hostisa-simd128 | 1.00 | 1.00 | 1.29 | 1.03 | 1.00 | 0.98 |
| native n-hostisa-simd128-u4 | 1.09 | 0.96 | 1.26 | 1.02 | 1.00 | 0.99 |
| native n-hostisa-simd128-u4-nofma | 0.98 | 0.95 | 1.03 | 1.03 | 1.00 | 0.99 |
| native n-hostisa-vb32-u2 | 0.28 | 0.78 | 1.27 | 1.01 | 1.00 | 0.98 |
| native n-hostisa-vb32-u2-nofma | 0.29 | 0.82 | 1.04 | 0.96 | 1.00 | 0.99 |
| native n-novec | 0.24 | 0.93 | 0.55 | 0.89 | 1.00 | 1.00 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 1.00 | 1.00 | 1.29 | 0.87 | 1.01 | 1.00 |
| native n-simd128-u4 | 1.10 | 0.99 | 1.31 | 1.02 | 1.02 | 1.00 |
| wasmtime scalar | 0.18 | 0.74 | 0.21 | 0.60 | 1.01 | 1.08 |
| wasmtime autovec | 0.72 | 0.74 | 0.39 | 0.60 | 1.01 | 1.08 |
| wasmtime simd | 0.80 | 0.94 | 0.75 | 0.60 | 1.01 | 1.08 |
| wasmtime simd-u2 | 0.72 | 0.94 | 0.75 | 0.60 | 1.01 | 1.08 |
| wasmtime simd-u4 | 0.80 | 0.96 | 0.75 | 0.60 | 1.01 | 1.08 |
| wasmtime simd-vb32 | 0.81 | 0.95 | 0.74 | 0.60 | 1.01 | 1.08 |
| wasmtime simd-vb32-u2 | 0.79 | 0.95 | 0.75 | 0.60 | 1.01 | 1.08 |
| wasmtime relaxed | 0.87 | 0.99 | 0.81 | 0.60 | 1.01 | 1.08 |
| wasmtime relaxed-u2 | 0.81 | 1.00 | 0.80 | 0.60 | 1.00 | 1.08 |

