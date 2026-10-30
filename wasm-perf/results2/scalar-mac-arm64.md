## mac-arm64: wasm-scalar run 41060937206, commit 1f76ef6f374a1af3de6857b416a9e17ac9fd951d
Apple M1 (Virtual)
s-O2-nosimd.wasm s-O3-autovec-fastmath-relaxed.wasm s-O3-autovec-fastmath.wasm s-O3-autovec-il4.wasm s-O3-autovec-pragmas.wasm s-O3-autovec-relaxed.wasm s-O3-autovec-unroll.wasm s-O3-autovec.wasm s-O3-bleeding.wasm s-O3-nosimd.wasm w-autovec-O3.wasm w-autovec-O4.wasm w-autovec-Oz.wasm w-nosimd-O3.wasm w-simd-u4-O3.wasm w-simd-u4-O4.wasm w-simd-u4-Oz.wasm x-O3-simd-relaxed-u2.wasm x-O3-simd-u4.wasm x-O3-simd-vb32-u2.wasm 
### Scalar gap mac-arm64 (ref = native cc -O3 scalar source, baseline ISA, auto-vectorised by the compiler): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform |
|---|---|---|---|
| native cc-hostisa-auto | 1.38 | 1.51 | 0.18 |
| native cc-hostisa-auto-nofma | 1.39 | 1.56 | 0.25 |
| native cc-hostisa-explicit-vb32 | 1.37 | 0.92 | 0.15 |
| native cc-novec | 6.33 | 1.86 | 0.40 |
| native cc-scalar-O2 | 1.81 | 1.47 | 0.19 |
| native cc-scalar-O3 | 1.38 | 1.47 | 0.18 |
| wasmtime s-O2-nosimd | 7.07 | 2.45 | 1.28 |
| wasmtime s-O3-autovec-fastmath-relaxed | 1.58 | 1.16 | 0.39 |
| wasmtime s-O3-autovec-fastmath | 1.74 | 1.33 | 0.44 |
| wasmtime s-O3-autovec-il4 | 1.54 | 2.44 | 0.44 |
| wasmtime s-O3-autovec-pragmas | 1.55 | 2.14 | 0.45 |
| wasmtime s-O3-autovec-relaxed | 1.57 | 2.42 | 0.40 |
| wasmtime s-O3-autovec-unroll | 1.74 | 2.42 | 0.46 |
| wasmtime s-O3-autovec | 1.72 | 2.44 | 0.45 |
| wasmtime s-O3-bleeding | 1.58 | 2.44 | 0.39 |
| wasmtime s-O3-nosimd | 7.10 | 2.44 | 1.24 |
| wasmtime w-autovec-O3 | 1.72 | 2.44 | 0.45 |
| wasmtime w-autovec-O4 | 1.72 | 2.44 | 0.45 |
| wasmtime w-autovec-Oz | 1.76 | 2.42 | 0.45 |
| wasmtime w-nosimd-O3 | 7.08 | 2.43 | 1.24 |
| wasmtime w-simd-u4-O3 | 1.51 | 1.21 | 0.41 |
| wasmtime w-simd-u4-O4 | 1.51 | 1.21 | 0.41 |
| wasmtime w-simd-u4-Oz | 1.50 | 1.22 | 0.41 |
| wasmtime x-O3-simd-relaxed-u2 | 1.56 | 1.01 | 0.37 |
| wasmtime x-O3-simd-u4 | 1.53 | 1.22 | 0.41 |
| wasmtime x-O3-simd-vb32-u2 | 1.54 | 1.22 | 0.41 |

speed relative to `native cc-scalar-O3` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform |
|---|---|---|---|
| native cc-hostisa-auto | 1.00 | 0.98 | 1.01 |
| native cc-hostisa-auto-nofma | 0.99 | 0.94 | 0.75 |
| native cc-hostisa-explicit-vb32 | 1.00 | 1.60 | 1.25 |
| native cc-novec | 0.22 | 0.79 | 0.46 |
| native cc-scalar-O2 | 0.76 | 1.00 | 0.99 |
| native cc-scalar-O3 | 1.00 | 1.00 | 1.00 |
| wasmtime s-O2-nosimd | 0.20 | 0.60 | 0.14 |
| wasmtime s-O3-autovec-fastmath-relaxed | 0.88 | 1.27 | 0.47 |
| wasmtime s-O3-autovec-fastmath | 0.79 | 1.11 | 0.42 |
| wasmtime s-O3-autovec-il4 | 0.90 | 0.60 | 0.42 |
| wasmtime s-O3-autovec-pragmas | 0.89 | 0.69 | 0.41 |
| wasmtime s-O3-autovec-relaxed | 0.88 | 0.61 | 0.47 |
| wasmtime s-O3-autovec-unroll | 0.79 | 0.61 | 0.41 |
| wasmtime s-O3-autovec | 0.80 | 0.60 | 0.41 |
| wasmtime s-O3-bleeding | 0.87 | 0.60 | 0.47 |
| wasmtime s-O3-nosimd | 0.19 | 0.60 | 0.15 |
| wasmtime w-autovec-O3 | 0.80 | 0.60 | 0.41 |
| wasmtime w-autovec-O4 | 0.80 | 0.60 | 0.41 |
| wasmtime w-autovec-Oz | 0.78 | 0.61 | 0.41 |
| wasmtime w-nosimd-O3 | 0.19 | 0.61 | 0.15 |
| wasmtime w-simd-u4-O3 | 0.91 | 1.22 | 0.45 |
| wasmtime w-simd-u4-O4 | 0.92 | 1.22 | 0.45 |
| wasmtime w-simd-u4-Oz | 0.92 | 1.21 | 0.45 |
| wasmtime x-O3-simd-relaxed-u2 | 0.89 | 1.46 | 0.49 |
| wasmtime x-O3-simd-u4 | 0.90 | 1.20 | 0.45 |
| wasmtime x-O3-simd-vb32-u2 | 0.90 | 1.21 | 0.45 |

