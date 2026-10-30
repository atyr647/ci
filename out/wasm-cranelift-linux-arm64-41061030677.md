## linux-arm64: wasm-cranelift run 41061030677, commit 1f76ef6f374a1af3de6857b416a9e17ac9fd951d
cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
asimd fphp asimddp sve sve2 i8mm bf16 
Settings inferred for the current host:   has_dotprod   has_fp16   has_i8mm   has_lse   has_pauth 
### Phase A linux-arm64: Wasmtime v50 settings, so-simd.wasm: ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 2.04 | 4.04 | 0.59 | 127.90 | 2.50 |
| opt-level=0 | 3.39 | 4.04 | 0.66 | 147.92 | 2.63 |
| opt-level=1 | 2.05 | 4.04 | 0.59 | 128.11 | 2.50 |
| opt-level=2 | 2.05 | 4.04 | 0.58 | 127.99 | 2.50 |
| opt-level=s | 2.05 | 4.04 | 0.59 | 128.06 | 2.50 |
| regalloc single-pass | 7.78 | 4.64 | 0.89 | 448.57 | 7.14 |
| explicit bounds checks (signals-based-traps=n) | 3.49 | 3.93 | 0.78 | 155.71 | 2.52 |
| dynamic memory (reservation 0, guard 0) | 4.05 | 4.12 | 0.87 | 167.80 | 2.67 |
| memory-may-move=y | 2.05 | 4.04 | 0.59 | 128.06 | 2.50 |
| memory-reservation=4GiB, guard=0 | 4.17 | 4.14 | 0.87 | 169.90 | 2.65 |
| fuel=1e15 | 3.76 | 4.21 | 0.76 | 177.23 | 2.54 |
| nan-canonicalization=y | 9.54 | 27.90 | 2.45 | 128.00 | 2.51 |
| inlining=y | 2.05 | 4.04 | 0.59 | 128.07 | 2.51 |
| winch (baseline compiler) | 7.16 | 5.87 | 0.92 | 245.98 | 4.07 |
| cwasm-baseline (--target only, no extra flags) | 2.05 | 4.04 | 0.58 | 128.19 | 2.50 |
| cwasm-host-default (compile without --target) | 2.05 | 4.04 | 0.59 | 128.08 | 2.50 |

speed relative to `default (host CPU features)` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB |
|---|---|---|---|---|---|
| default (host CPU features) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| opt-level=0 | 0.60 | 1.00 | 0.89 | 0.86 | 0.95 |
| opt-level=1 | 1.00 | 1.00 | 1.01 | 1.00 | 1.00 |
| opt-level=2 | 1.00 | 1.00 | 1.01 | 1.00 | 1.00 |
| opt-level=s | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| regalloc single-pass | 0.26 | 0.87 | 0.66 | 0.29 | 0.35 |
| explicit bounds checks (signals-based-traps=n) | 0.59 | 1.03 | 0.75 | 0.82 | 0.99 |
| dynamic memory (reservation 0, guard 0) | 0.50 | 0.98 | 0.68 | 0.76 | 0.94 |
| memory-may-move=y | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| memory-reservation=4GiB, guard=0 | 0.49 | 0.97 | 0.68 | 0.75 | 0.94 |
| fuel=1e15 | 0.54 | 0.96 | 0.77 | 0.72 | 0.99 |
| nan-canonicalization=y | 0.21 | 0.14 | 0.24 | 1.00 | 1.00 |
| inlining=y | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| winch (baseline compiler) | 0.29 | 0.69 | 0.64 | 0.52 | 0.62 |
| cwasm-baseline (--target only, no extra flags) | 1.00 | 1.00 | 1.01 | 1.00 | 1.00 |
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
| native c-hostisa-auto | 1.81 | 4.04 | 0.39 | 77.12 | 2.49 | 45.70 |
| native c-hostisa-vb32-u2 | 1.83 | 3.77 | 0.26 | 77.55 | 2.49 | 45.45 |
| native c-hostisa-vb32-u2-nofma | 1.91 | 4.02 | 0.34 | 77.25 | 2.49 | 45.60 |
| native c-scalar | 1.82 | 4.09 | 0.39 | 74.87 | 2.50 | 45.35 |
| native n-hostisa-auto | 1.63 | 4.04 | 0.43 | 77.06 | 2.52 | 55.57 |
| native n-hostisa-simd128 | 1.64 | 3.79 | 0.34 | 75.25 | 2.52 | 55.63 |
| native n-hostisa-simd128-u4 | 1.50 | 3.93 | 0.35 | 75.44 | 2.53 | 55.52 |
| native n-hostisa-simd128-u4-nofma | 1.66 | 3.96 | 0.43 | 75.15 | 2.52 | 55.62 |
| native n-hostisa-vb32-u2 | 5.93 | 4.82 | 0.34 | 76.49 | 2.54 | 55.93 |
| native n-hostisa-vb32-u2-nofma | 5.61 | 4.58 | 0.42 | 78.70 | 2.54 | 55.60 |
| native n-novec | 6.97 | 4.06 | 0.80 | 87.66 | 2.54 | 54.86 |
| native n-scalar | 1.63 | 3.77 | 0.44 | 77.50 | 2.52 | 54.85 |
| native n-simd128 | 1.64 | 3.78 | 0.35 | 89.60 | 2.50 | 54.91 |
| native n-simd128-u4 | 1.49 | 3.83 | 0.34 | 75.40 | 2.50 | 55.01 |
| wasmtime scalar | 8.94 | 5.07 | 2.07 | 128.10 | 2.51 | 50.76 |
| wasmtime autovec | 2.28 | 5.08 | 1.11 | 127.99 | 2.50 | 50.98 |
| wasmtime simd | 2.05 | 4.04 | 0.59 | 128.11 | 2.50 | 50.67 |
| wasmtime simd-u2 | 2.27 | 4.02 | 0.59 | 127.99 | 2.50 | 50.88 |
| wasmtime simd-u4 | 2.06 | 3.94 | 0.58 | 127.99 | 2.50 | 51.09 |
| wasmtime simd-vb32 | 2.01 | 3.98 | 0.59 | 127.94 | 2.49 | 50.96 |
| wasmtime simd-vb32-u2 | 2.07 | 3.99 | 0.59 | 127.95 | 2.50 | 50.93 |
| wasmtime relaxed | 1.89 | 3.83 | 0.55 | 128.02 | 2.50 | 50.69 |
| wasmtime relaxed-u2 | 2.04 | 3.78 | 0.55 | 128.04 | 2.51 | 50.72 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp | hash16MB | sort1M |
|---|---|---|---|---|---|---|
| native c-hostisa-auto | 0.90 | 0.94 | 1.15 | 1.01 | 1.01 | 1.20 |
| native c-hostisa-vb32-u2 | 0.89 | 1.00 | 1.72 | 1.00 | 1.01 | 1.21 |
| native c-hostisa-vb32-u2-nofma | 0.85 | 0.94 | 1.31 | 1.00 | 1.01 | 1.20 |
| native c-scalar | 0.89 | 0.92 | 1.15 | 1.04 | 1.01 | 1.21 |
| native n-hostisa-auto | 1.00 | 0.93 | 1.02 | 1.01 | 1.00 | 0.99 |
| native n-hostisa-simd128 | 0.99 | 1.00 | 1.31 | 1.03 | 1.00 | 0.99 |
| native n-hostisa-simd128-u4 | 1.09 | 0.96 | 1.26 | 1.03 | 1.00 | 0.99 |
| native n-hostisa-simd128-u4-nofma | 0.98 | 0.95 | 1.03 | 1.03 | 1.00 | 0.99 |
| native n-hostisa-vb32-u2 | 0.28 | 0.78 | 1.31 | 1.01 | 0.99 | 0.98 |
| native n-hostisa-vb32-u2-nofma | 0.29 | 0.82 | 1.04 | 0.98 | 0.99 | 0.99 |
| native n-novec | 0.23 | 0.93 | 0.56 | 0.88 | 0.99 | 1.00 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128 | 0.99 | 1.00 | 1.28 | 0.86 | 1.01 | 1.00 |
| native n-simd128-u4 | 1.09 | 0.99 | 1.30 | 1.03 | 1.01 | 1.00 |
| wasmtime scalar | 0.18 | 0.74 | 0.21 | 0.61 | 1.00 | 1.08 |
| wasmtime autovec | 0.72 | 0.74 | 0.40 | 0.61 | 1.01 | 1.08 |
| wasmtime simd | 0.80 | 0.94 | 0.75 | 0.60 | 1.01 | 1.08 |
| wasmtime simd-u2 | 0.72 | 0.94 | 0.76 | 0.61 | 1.01 | 1.08 |
| wasmtime simd-u4 | 0.79 | 0.96 | 0.76 | 0.61 | 1.01 | 1.07 |
| wasmtime simd-vb32 | 0.81 | 0.95 | 0.75 | 0.61 | 1.01 | 1.08 |
| wasmtime simd-vb32-u2 | 0.79 | 0.95 | 0.75 | 0.61 | 1.01 | 1.08 |
| wasmtime relaxed | 0.87 | 0.99 | 0.81 | 0.61 | 1.01 | 1.08 |
| wasmtime relaxed-u2 | 0.80 | 1.00 | 0.81 | 0.61 | 1.00 | 1.08 |

