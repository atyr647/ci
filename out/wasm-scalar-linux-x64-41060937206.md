## linux-x64: wasm-scalar run 41060937206, commit 1f76ef6f374a1af3de6857b416a9e17ac9fd951d
model name	: AMD EPYC 9V74 80-Core Processor
s-O2-nosimd.wasm s-O3-autovec-fastmath-relaxed.wasm s-O3-autovec-fastmath.wasm s-O3-autovec-il4.wasm s-O3-autovec-pragmas.wasm s-O3-autovec-relaxed.wasm s-O3-autovec-unroll.wasm s-O3-autovec.wasm s-O3-bleeding.wasm s-O3-nosimd.wasm w-autovec-O3.wasm w-autovec-O4.wasm w-autovec-Oz.wasm w-nosimd-O3.wasm w-simd-u4-O3.wasm w-simd-u4-O4.wasm w-simd-u4-Oz.wasm x-O3-simd-relaxed-u2.wasm x-O3-simd-u4.wasm x-O3-simd-vb32-u2.wasm 
### Scalar gap linux-x64 (ref = native cc -O3 scalar source, baseline ISA, auto-vectorised by the compiler): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform |
|---|---|---|---|
| native cc-hostisa-auto | 0.58 | 0.93 | 0.10 |
| native cc-hostisa-auto-nofma | 0.58 | 0.94 | 0.12 |
| native cc-hostisa-explicit-vb32 | 0.61 | 1.04 | 0.29 |
| native cc-novec | 6.43 | 4.17 | 0.72 |
| native cc-scalar-O2 | 1.22 | 2.19 | 0.29 |
| native cc-scalar-O3 | 1.17 | 2.20 | 0.24 |
| native clang-hostisa-auto | 0.60 | 4.12 | 0.16 |
| native clang-hostisa-auto-fastmath | 0.60 | 0.93 | 0.17 |
| native clang-hostisa-auto-nofma | 0.62 | 4.18 | 0.17 |
| native clang-scalar-O3 | 1.26 | 4.19 | 0.33 |
| wasmtime s-O2-nosimd | 6.13 | 4.33 | 0.73 |
| wasmtime s-O3-autovec-fastmath-relaxed | 1.75 | 2.07 | 0.45 |
| wasmtime s-O3-autovec-fastmath | 2.04 | 2.12 | 0.43 |
| wasmtime s-O3-autovec-il4 | 1.88 | 4.32 | 0.42 |
| wasmtime s-O3-autovec-pragmas | 1.89 | 3.92 | 0.44 |
| wasmtime s-O3-autovec-relaxed | 2.03 | 4.32 | 0.44 |
| wasmtime s-O3-autovec-unroll | 2.03 | 4.31 | 0.43 |
| wasmtime s-O3-autovec | 2.03 | 4.33 | 0.43 |
| wasmtime s-O3-bleeding | 2.03 | 4.33 | 0.44 |
| wasmtime s-O3-nosimd | 6.15 | 4.33 | 0.74 |
| wasmtime w-autovec-O3 | 2.03 | 4.31 | 0.44 |
| wasmtime w-autovec-O4 | 2.03 | 4.31 | 0.44 |
| wasmtime w-autovec-Oz | 2.04 | 4.33 | 0.43 |
| wasmtime w-nosimd-O3 | 6.13 | 4.32 | 0.74 |
| wasmtime w-simd-u4-O3 | 1.90 | 2.29 | 0.24 |
| wasmtime w-simd-u4-O4 | 1.90 | 2.29 | 0.24 |
| wasmtime w-simd-u4-Oz | 1.89 | 2.29 | 0.24 |
| wasmtime x-O3-simd-relaxed-u2 | 2.03 | 2.10 | 0.24 |
| wasmtime x-O3-simd-u4 | 1.89 | 2.31 | 0.24 |
| wasmtime x-O3-simd-vb32-u2 | 1.67 | 2.31 | 0.24 |

speed relative to `native cc-scalar-O3` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform |
|---|---|---|---|
| native cc-hostisa-auto | 2.03 | 2.36 | 2.28 |
| native cc-hostisa-auto-nofma | 2.03 | 2.35 | 2.03 |
| native cc-hostisa-explicit-vb32 | 1.91 | 2.12 | 0.82 |
| native cc-novec | 0.18 | 0.53 | 0.33 |
| native cc-scalar-O2 | 0.96 | 1.00 | 0.81 |
| native cc-scalar-O3 | 1.00 | 1.00 | 1.00 |
| native clang-hostisa-auto | 1.95 | 0.53 | 1.48 |
| native clang-hostisa-auto-fastmath | 1.95 | 2.37 | 1.42 |
| native clang-hostisa-auto-nofma | 1.89 | 0.53 | 1.40 |
| native clang-scalar-O3 | 0.93 | 0.52 | 0.72 |
| wasmtime s-O2-nosimd | 0.19 | 0.51 | 0.33 |
| wasmtime s-O3-autovec-fastmath-relaxed | 0.67 | 1.06 | 0.53 |
| wasmtime s-O3-autovec-fastmath | 0.57 | 1.04 | 0.55 |
| wasmtime s-O3-autovec-il4 | 0.62 | 0.51 | 0.57 |
| wasmtime s-O3-autovec-pragmas | 0.62 | 0.56 | 0.54 |
| wasmtime s-O3-autovec-relaxed | 0.58 | 0.51 | 0.54 |
| wasmtime s-O3-autovec-unroll | 0.58 | 0.51 | 0.55 |
| wasmtime s-O3-autovec | 0.58 | 0.51 | 0.55 |
| wasmtime s-O3-bleeding | 0.58 | 0.51 | 0.54 |
| wasmtime s-O3-nosimd | 0.19 | 0.51 | 0.32 |
| wasmtime w-autovec-O3 | 0.58 | 0.51 | 0.55 |
| wasmtime w-autovec-O4 | 0.58 | 0.51 | 0.55 |
| wasmtime w-autovec-Oz | 0.57 | 0.51 | 0.55 |
| wasmtime w-nosimd-O3 | 0.19 | 0.51 | 0.32 |
| wasmtime w-simd-u4-O3 | 0.62 | 0.96 | 1.01 |
| wasmtime w-simd-u4-O4 | 0.62 | 0.96 | 1.00 |
| wasmtime w-simd-u4-Oz | 0.62 | 0.96 | 1.00 |
| wasmtime x-O3-simd-relaxed-u2 | 0.58 | 1.04 | 0.98 |
| wasmtime x-O3-simd-u4 | 0.62 | 0.95 | 1.01 |
| wasmtime x-O3-simd-vb32-u2 | 0.70 | 0.95 | 0.99 |

