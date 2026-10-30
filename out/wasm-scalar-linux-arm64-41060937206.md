## linux-arm64: wasm-scalar run 41060937206, commit 1f76ef6f374a1af3de6857b416a9e17ac9fd951d
s-O2-nosimd.wasm s-O3-autovec-fastmath-relaxed.wasm s-O3-autovec-fastmath.wasm s-O3-autovec-il4.wasm s-O3-autovec-pragmas.wasm s-O3-autovec-relaxed.wasm s-O3-autovec-unroll.wasm s-O3-autovec.wasm s-O3-bleeding.wasm s-O3-nosimd.wasm w-autovec-O3.wasm w-autovec-O4.wasm w-autovec-Oz.wasm w-nosimd-O3.wasm w-simd-u4-O3.wasm w-simd-u4-O4.wasm w-simd-u4-Oz.wasm x-O3-simd-relaxed-u2.wasm x-O3-simd-u4.wasm x-O3-simd-vb32-u2.wasm 
### Scalar gap linux-arm64 (ref = native cc -O3 scalar source, baseline ISA, auto-vectorised by the compiler): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform |
|---|---|---|---|
| native cc-hostisa-auto | 1.63 | 4.04 | 0.43 |
| native cc-hostisa-auto-nofma | 1.82 | 4.16 | 0.48 |
| native cc-hostisa-explicit-vb32 | 6.30 | 4.85 | 0.34 |
| native cc-novec | 6.97 | 4.06 | 0.80 |
| native cc-scalar-O2 | 1.86 | 3.77 | 0.35 |
| native cc-scalar-O3 | 1.64 | 3.77 | 0.44 |
| native clang-hostisa-auto | 1.81 | 4.04 | 0.38 |
| native clang-hostisa-auto-fastmath | 1.81 | 3.75 | 0.38 |
| native clang-hostisa-auto-nofma | 1.96 | 3.94 | 0.48 |
| native clang-scalar-O3 | 1.82 | 4.10 | 0.38 |
| wasmtime s-O2-nosimd | 9.43 | 5.07 | 2.07 |
| wasmtime s-O3-autovec-fastmath-relaxed | 2.03 | 3.95 | 1.02 |
| wasmtime s-O3-autovec-fastmath | 2.40 | 4.17 | 1.07 |
| wasmtime s-O3-autovec-il4 | 2.10 | 5.07 | 1.11 |
| wasmtime s-O3-autovec-pragmas | 2.10 | 4.73 | 1.12 |
| wasmtime s-O3-autovec-relaxed | 2.03 | 5.05 | 1.02 |
| wasmtime s-O3-autovec-unroll | 2.28 | 5.07 | 1.11 |
| wasmtime s-O3-autovec | 2.28 | 5.07 | 1.11 |
| wasmtime s-O3-bleeding | 2.03 | 5.07 | 1.02 |
| wasmtime s-O3-nosimd | 8.94 | 5.07 | 2.07 |
| wasmtime w-autovec-O3 | 2.28 | 5.07 | 1.11 |
| wasmtime w-autovec-O4 | 2.28 | 5.07 | 1.11 |
| wasmtime w-autovec-Oz | 2.27 | 5.07 | 1.11 |
| wasmtime w-nosimd-O3 | 8.94 | 5.08 | 2.07 |
| wasmtime w-simd-u4-O3 | 2.11 | 3.94 | 0.58 |
| wasmtime w-simd-u4-O4 | 2.10 | 3.95 | 0.58 |
| wasmtime w-simd-u4-Oz | 2.04 | 3.94 | 0.58 |
| wasmtime x-O3-simd-relaxed-u2 | 2.03 | 3.78 | 0.54 |
| wasmtime x-O3-simd-u4 | 2.05 | 3.94 | 0.58 |
| wasmtime x-O3-simd-vb32-u2 | 2.06 | 3.99 | 0.58 |

speed relative to `native cc-scalar-O3` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform |
|---|---|---|---|
| native cc-hostisa-auto | 1.00 | 0.93 | 1.01 |
| native cc-hostisa-auto-nofma | 0.90 | 0.91 | 0.91 |
| native cc-hostisa-explicit-vb32 | 0.26 | 0.78 | 1.30 |
| native cc-novec | 0.23 | 0.93 | 0.55 |
| native cc-scalar-O2 | 0.88 | 1.00 | 1.27 |
| native cc-scalar-O3 | 1.00 | 1.00 | 1.00 |
| native clang-hostisa-auto | 0.90 | 0.94 | 1.16 |
| native clang-hostisa-auto-fastmath | 0.91 | 1.01 | 1.15 |
| native clang-hostisa-auto-nofma | 0.84 | 0.96 | 0.92 |
| native clang-scalar-O3 | 0.90 | 0.92 | 1.16 |
| wasmtime s-O2-nosimd | 0.17 | 0.74 | 0.21 |
| wasmtime s-O3-autovec-fastmath-relaxed | 0.81 | 0.96 | 0.43 |
| wasmtime s-O3-autovec-fastmath | 0.68 | 0.91 | 0.41 |
| wasmtime s-O3-autovec-il4 | 0.78 | 0.74 | 0.39 |
| wasmtime s-O3-autovec-pragmas | 0.78 | 0.80 | 0.39 |
| wasmtime s-O3-autovec-relaxed | 0.81 | 0.75 | 0.43 |
| wasmtime s-O3-autovec-unroll | 0.72 | 0.74 | 0.40 |
| wasmtime s-O3-autovec | 0.72 | 0.74 | 0.40 |
| wasmtime s-O3-bleeding | 0.81 | 0.75 | 0.43 |
| wasmtime s-O3-nosimd | 0.18 | 0.74 | 0.21 |
| wasmtime w-autovec-O3 | 0.72 | 0.75 | 0.40 |
| wasmtime w-autovec-O4 | 0.72 | 0.74 | 0.39 |
| wasmtime w-autovec-Oz | 0.72 | 0.74 | 0.40 |
| wasmtime w-nosimd-O3 | 0.18 | 0.74 | 0.21 |
| wasmtime w-simd-u4-O3 | 0.78 | 0.96 | 0.75 |
| wasmtime w-simd-u4-O4 | 0.78 | 0.96 | 0.75 |
| wasmtime w-simd-u4-Oz | 0.80 | 0.96 | 0.75 |
| wasmtime x-O3-simd-relaxed-u2 | 0.81 | 1.00 | 0.81 |
| wasmtime x-O3-simd-u4 | 0.80 | 0.96 | 0.75 |
| wasmtime x-O3-simd-vb32-u2 | 0.79 | 0.95 | 0.75 |

