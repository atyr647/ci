## linux-arm64: wasm-scalar run 41065527203, commit e85b86793ee668754feb0a4edf3f4f6103831a71
s-O2-nosimd.wasm s-O3-autovec-fastmath-relaxed.wasm s-O3-autovec-fastmath.wasm s-O3-autovec-il4.wasm s-O3-autovec-pragmas.wasm s-O3-autovec-relaxed.wasm s-O3-autovec-unroll.wasm s-O3-autovec.wasm s-O3-bleeding.wasm s-O3-nosimd.wasm w-autovec-O3.wasm w-autovec-O4.wasm w-autovec-Oz.wasm w-nosimd-O3.wasm w-simd-u4-O3.wasm w-simd-u4-O4.wasm w-simd-u4-Oz.wasm x-O2-simd-u4.wasm x-O3-simd-relaxed-u2.wasm x-O3-simd-u4-Os.wasm x-O3-simd-u4-nojt.wasm x-O3-simd-u4.wasm x-O3-simd-vb32-u2.wasm 
### Scalar gap linux-arm64 (ref = native cc -O3 scalar source, baseline ISA, auto-vectorised by the compiler): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native cc-hostisa-auto | 1.64 | 4.04 | 0.43 | 77.13 |
| native cc-hostisa-auto-nofma | 1.82 | 4.16 | 0.48 | 75.84 |
| native cc-hostisa-explicit-vb32 | 6.21 | 4.83 | 0.34 | 76.25 |
| native cc-novec | 6.97 | 4.06 | 0.80 | 87.44 |
| native cc-scalar-O2 | 1.86 | 3.77 | 0.35 | 100.41 |
| native cc-scalar-O3 | 1.64 | 3.77 | 0.44 | 77.43 |
| native cc-scalar-nojt | 1.64 | 3.77 | 0.44 | 77.38 |
| native clang-hostisa-auto | 1.81 | 4.04 | 0.38 | 77.12 |
| native clang-hostisa-auto-fastmath | 1.81 | 3.75 | 0.39 | 77.14 |
| native clang-hostisa-auto-nofma | 1.95 | 3.94 | 0.49 | 76.92 |
| native clang-scalar-O3 | 1.82 | 4.10 | 0.39 | 74.65 |
| wasmtime s-O2-nosimd | 9.43 | 5.07 | 2.07 | 127.97 |
| wasmtime s-O3-autovec-fastmath-relaxed | 2.03 | 3.95 | 1.02 | 128.02 |
| wasmtime s-O3-autovec-fastmath | 2.40 | 4.17 | 1.07 | 127.97 |
| wasmtime s-O3-autovec-il4 | 2.10 | 5.07 | 1.11 | 128.00 |
| wasmtime s-O3-autovec-pragmas | 2.10 | 4.74 | 1.12 | 128.03 |
| wasmtime s-O3-autovec-relaxed | 2.03 | 5.03 | 1.02 | 128.01 |
| wasmtime s-O3-autovec-unroll | 2.28 | 5.08 | 1.11 | 127.98 |
| wasmtime s-O3-autovec | 2.27 | 5.07 | 1.11 | 128.00 |
| wasmtime s-O3-bleeding | 2.03 | 5.04 | 1.02 | 127.99 |
| wasmtime s-O3-nosimd | 8.94 | 5.07 | 2.07 | 128.14 |
| wasmtime w-autovec-O3 | 2.28 | 5.07 | 1.11 | 129.80 |
| wasmtime w-autovec-O4 | 2.28 | 5.07 | 1.11 | 129.84 |
| wasmtime w-autovec-Oz | 2.27 | 5.08 | 1.11 | 129.76 |
| wasmtime w-nosimd-O3 | 8.94 | 5.08 | 2.07 | 130.82 |
| wasmtime w-simd-u4-O3 | 2.10 | 3.95 | 0.58 | 129.82 |
| wasmtime w-simd-u4-O4 | 2.10 | 3.94 | 0.58 | 129.86 |
| wasmtime w-simd-u4-Oz | 2.05 | 3.94 | 0.58 | 130.73 |
| wasmtime x-O2-simd-u4 | 2.05 | 3.94 | 0.58 | 128.26 |
| wasmtime x-O3-simd-relaxed-u2 | 2.03 | 3.78 | 0.54 | 127.97 |
| wasmtime x-O3-simd-u4-Os | 2.05 | 3.96 | 0.58 | 130.20 |
| wasmtime x-O3-simd-u4-nojt | 2.05 | 3.94 | 0.58 | 117.80 |
| wasmtime x-O3-simd-u4 | 2.06 | 3.94 | 0.58 | 127.99 |
| wasmtime x-O3-simd-vb32-u2 | 2.06 | 3.99 | 0.59 | 128.01 |

speed relative to `native cc-scalar-O3` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native cc-hostisa-auto | 1.00 | 0.93 | 1.01 | 1.00 |
| native cc-hostisa-auto-nofma | 0.90 | 0.91 | 0.91 | 1.02 |
| native cc-hostisa-explicit-vb32 | 0.26 | 0.78 | 1.31 | 1.02 |
| native cc-novec | 0.24 | 0.93 | 0.55 | 0.89 |
| native cc-scalar-O2 | 0.88 | 1.00 | 1.25 | 0.77 |
| native cc-scalar-O3 | 1.00 | 1.00 | 1.00 | 1.00 |
| native cc-scalar-nojt | 1.00 | 1.00 | 1.00 | 1.00 |
| native clang-hostisa-auto | 0.90 | 0.94 | 1.15 | 1.00 |
| native clang-hostisa-auto-fastmath | 0.91 | 1.01 | 1.12 | 1.00 |
| native clang-hostisa-auto-nofma | 0.84 | 0.96 | 0.90 | 1.01 |
| native clang-scalar-O3 | 0.90 | 0.92 | 1.13 | 1.04 |
| wasmtime s-O2-nosimd | 0.17 | 0.74 | 0.21 | 0.61 |
| wasmtime s-O3-autovec-fastmath-relaxed | 0.81 | 0.96 | 0.43 | 0.60 |
| wasmtime s-O3-autovec-fastmath | 0.68 | 0.91 | 0.41 | 0.61 |
| wasmtime s-O3-autovec-il4 | 0.78 | 0.74 | 0.40 | 0.60 |
| wasmtime s-O3-autovec-pragmas | 0.78 | 0.80 | 0.39 | 0.60 |
| wasmtime s-O3-autovec-relaxed | 0.81 | 0.75 | 0.43 | 0.60 |
| wasmtime s-O3-autovec-unroll | 0.72 | 0.74 | 0.40 | 0.61 |
| wasmtime s-O3-autovec | 0.72 | 0.74 | 0.40 | 0.60 |
| wasmtime s-O3-bleeding | 0.81 | 0.75 | 0.43 | 0.61 |
| wasmtime s-O3-nosimd | 0.18 | 0.74 | 0.21 | 0.60 |
| wasmtime w-autovec-O3 | 0.72 | 0.74 | 0.40 | 0.60 |
| wasmtime w-autovec-O4 | 0.72 | 0.74 | 0.40 | 0.60 |
| wasmtime w-autovec-Oz | 0.72 | 0.74 | 0.40 | 0.60 |
| wasmtime w-nosimd-O3 | 0.18 | 0.74 | 0.21 | 0.59 |
| wasmtime w-simd-u4-O3 | 0.78 | 0.96 | 0.75 | 0.60 |
| wasmtime w-simd-u4-O4 | 0.78 | 0.96 | 0.75 | 0.60 |
| wasmtime w-simd-u4-Oz | 0.80 | 0.96 | 0.75 | 0.59 |
| wasmtime x-O2-simd-u4 | 0.80 | 0.96 | 0.75 | 0.60 |
| wasmtime x-O3-simd-relaxed-u2 | 0.81 | 1.00 | 0.81 | 0.61 |
| wasmtime x-O3-simd-u4-Os | 0.80 | 0.95 | 0.75 | 0.59 |
| wasmtime x-O3-simd-u4-nojt | 0.80 | 0.96 | 0.75 | 0.66 |
| wasmtime x-O3-simd-u4 | 0.79 | 0.96 | 0.75 | 0.60 |
| wasmtime x-O3-simd-vb32-u2 | 0.79 | 0.95 | 0.75 | 0.60 |

