## mac-arm64: wasm-scalar run 41065527203, commit e85b86793ee668754feb0a4edf3f4f6103831a71
Apple M1 (Virtual)
s-O2-nosimd.wasm s-O3-autovec-fastmath-relaxed.wasm s-O3-autovec-fastmath.wasm s-O3-autovec-il4.wasm s-O3-autovec-pragmas.wasm s-O3-autovec-relaxed.wasm s-O3-autovec-unroll.wasm s-O3-autovec.wasm s-O3-bleeding.wasm s-O3-nosimd.wasm w-autovec-O3.wasm w-autovec-O4.wasm w-autovec-Oz.wasm w-nosimd-O3.wasm w-simd-u4-O3.wasm w-simd-u4-O4.wasm w-simd-u4-Oz.wasm x-O2-simd-u4.wasm x-O3-simd-relaxed-u2.wasm x-O3-simd-u4-nojt.wasm x-O3-simd-u4-Os.wasm x-O3-simd-u4.wasm x-O3-simd-vb32-u2.wasm 
### Scalar gap mac-arm64 (ref = native cc -O3 scalar source, baseline ISA, auto-vectorised by the compiler): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native cc-hostisa-auto | 1.33 | 1.45 | 0.19 | 107.19 |
| native cc-hostisa-auto-nofma | 1.40 | 1.58 | 0.24 | 109.01 |
| native cc-hostisa-explicit-vb32 | 1.31 | 0.87 | 0.15 | 111.28 |
| native cc-novec | 6.16 | 1.82 | 0.39 | 104.12 |
| native cc-scalar-O2 | 1.74 | 1.42 | 0.19 | 105.89 |
| native cc-scalar-O3 | 1.35 | 1.47 | 0.19 | 108.64 |
| native cc-scalar-nojt | 1.38 | 1.47 | 0.18 | 104.67 |
| wasmtime s-O2-nosimd | 6.73 | 2.32 | 1.24 | 133.24 |
| wasmtime s-O3-autovec-fastmath-relaxed | 1.57 | 1.16 | 0.39 | 136.61 |
| wasmtime s-O3-autovec-fastmath | 1.75 | 1.32 | 0.43 | 130.98 |
| wasmtime s-O3-autovec-il4 | 1.48 | 2.32 | 0.44 | 131.55 |
| wasmtime s-O3-autovec-pragmas | 1.53 | 2.12 | 0.45 | 137.42 |
| wasmtime s-O3-autovec-relaxed | 1.51 | 2.31 | 0.38 | 131.52 |
| wasmtime s-O3-autovec-unroll | 1.65 | 2.32 | 0.44 | 133.27 |
| wasmtime s-O3-autovec | 1.71 | 2.41 | 0.45 | 140.07 |
| wasmtime s-O3-bleeding | 1.58 | 2.43 | 0.38 | 131.78 |
| wasmtime s-O3-nosimd | 6.64 | 2.32 | 1.22 | 131.96 |
| wasmtime w-autovec-O3 | 1.69 | 2.39 | 0.44 | 142.19 |
| wasmtime w-autovec-O4 | 1.65 | 2.32 | 0.46 | 131.66 |
| wasmtime w-autovec-Oz | 1.76 | 2.43 | 0.46 | 145.51 |
| wasmtime w-nosimd-O3 | 6.62 | 2.29 | 1.24 | 137.95 |
| wasmtime w-simd-u4-O3 | 1.51 | 1.21 | 0.45 | 137.94 |
| wasmtime w-simd-u4-O4 | 1.53 | 1.24 | 0.41 | 144.26 |
| wasmtime w-simd-u4-Oz | 1.45 | 1.17 | 0.41 | 134.12 |
| wasmtime x-O2-simd-u4 | 1.53 | 1.20 | 0.41 | 137.57 |
| wasmtime x-O3-simd-relaxed-u2 | 1.56 | 1.01 | 0.39 | 132.00 |
| wasmtime x-O3-simd-u4-Os | 1.46 | 1.16 | 0.41 | 135.88 |
| wasmtime x-O3-simd-u4-nojt | 1.52 | 1.22 | 0.41 | 132.56 |
| wasmtime x-O3-simd-u4 | 1.52 | 1.21 | 0.44 | 139.07 |
| wasmtime x-O3-simd-vb32-u2 | 1.50 | 1.18 | 0.43 | 133.67 |

speed relative to `native cc-scalar-O3` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native cc-hostisa-auto | 1.01 | 1.01 | 1.00 | 1.01 |
| native cc-hostisa-auto-nofma | 0.97 | 0.93 | 0.76 | 1.00 |
| native cc-hostisa-explicit-vb32 | 1.03 | 1.70 | 1.27 | 0.98 |
| native cc-novec | 0.22 | 0.81 | 0.47 | 1.04 |
| native cc-scalar-O2 | 0.77 | 1.04 | 0.99 | 1.03 |
| native cc-scalar-O3 | 1.00 | 1.00 | 1.00 | 1.00 |
| native cc-scalar-nojt | 0.98 | 1.00 | 1.04 | 1.04 |
| wasmtime s-O2-nosimd | 0.20 | 0.63 | 0.15 | 0.82 |
| wasmtime s-O3-autovec-fastmath-relaxed | 0.86 | 1.27 | 0.47 | 0.80 |
| wasmtime s-O3-autovec-fastmath | 0.77 | 1.11 | 0.44 | 0.83 |
| wasmtime s-O3-autovec-il4 | 0.91 | 0.63 | 0.42 | 0.83 |
| wasmtime s-O3-autovec-pragmas | 0.88 | 0.69 | 0.41 | 0.79 |
| wasmtime s-O3-autovec-relaxed | 0.89 | 0.64 | 0.49 | 0.83 |
| wasmtime s-O3-autovec-unroll | 0.82 | 0.63 | 0.42 | 0.82 |
| wasmtime s-O3-autovec | 0.79 | 0.61 | 0.41 | 0.78 |
| wasmtime s-O3-bleeding | 0.85 | 0.60 | 0.49 | 0.82 |
| wasmtime s-O3-nosimd | 0.20 | 0.63 | 0.15 | 0.82 |
| wasmtime w-autovec-O3 | 0.80 | 0.61 | 0.42 | 0.76 |
| wasmtime w-autovec-O4 | 0.82 | 0.63 | 0.41 | 0.83 |
| wasmtime w-autovec-Oz | 0.77 | 0.61 | 0.41 | 0.75 |
| wasmtime w-nosimd-O3 | 0.20 | 0.64 | 0.15 | 0.79 |
| wasmtime w-simd-u4-O3 | 0.89 | 1.21 | 0.41 | 0.79 |
| wasmtime w-simd-u4-O4 | 0.88 | 1.19 | 0.45 | 0.75 |
| wasmtime w-simd-u4-Oz | 0.93 | 1.25 | 0.45 | 0.81 |
| wasmtime x-O2-simd-u4 | 0.88 | 1.22 | 0.45 | 0.79 |
| wasmtime x-O3-simd-relaxed-u2 | 0.87 | 1.46 | 0.48 | 0.82 |
| wasmtime x-O3-simd-u4-Os | 0.92 | 1.27 | 0.45 | 0.80 |
| wasmtime x-O3-simd-u4-nojt | 0.89 | 1.21 | 0.46 | 0.82 |
| wasmtime x-O3-simd-u4 | 0.89 | 1.21 | 0.43 | 0.78 |
| wasmtime x-O3-simd-vb32-u2 | 0.90 | 1.25 | 0.43 | 0.81 |

