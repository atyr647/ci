## linux-x64: wasm-scalar run 41065527203, commit e85b86793ee668754feb0a4edf3f4f6103831a71
model name	: AMD EPYC 7763 64-Core Processor
s-O2-nosimd.wasm s-O3-autovec-fastmath-relaxed.wasm s-O3-autovec-fastmath.wasm s-O3-autovec-il4.wasm s-O3-autovec-pragmas.wasm s-O3-autovec-relaxed.wasm s-O3-autovec-unroll.wasm s-O3-autovec.wasm s-O3-bleeding.wasm s-O3-nosimd.wasm w-autovec-O3.wasm w-autovec-O4.wasm w-autovec-Oz.wasm w-nosimd-O3.wasm w-simd-u4-O3.wasm w-simd-u4-O4.wasm w-simd-u4-Oz.wasm x-O2-simd-u4.wasm x-O3-simd-relaxed-u2.wasm x-O3-simd-u4-Os.wasm x-O3-simd-u4-nojt.wasm x-O3-simd-u4.wasm x-O3-simd-vb32-u2.wasm 
### Scalar gap linux-x64 (ref = native cc -O3 scalar source, baseline ISA, auto-vectorised by the compiler): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native cc-hostisa-auto | 0.69 | 1.22 | 0.19 | 159.38 |
| native cc-hostisa-auto-nofma | 0.69 | 1.27 | 0.18 | 159.43 |
| native cc-hostisa-explicit-vb32 | 0.92 | 1.27 | 0.35 | 153.88 |
| native cc-novec | 7.38 | 5.15 | 0.87 | 181.71 |
| native cc-scalar-O2 | 1.43 | 2.72 | 0.35 | 149.41 |
| native cc-scalar-O3 | 1.34 | 2.77 | 0.31 | 176.55 |
| native cc-scalar-nojt | 1.34 | 2.70 | 0.31 | 92.77 |
| native clang-hostisa-auto | 1.02 | 4.81 | 0.40 | 170.02 |
| native clang-hostisa-auto-fastmath | 0.94 | 1.20 | 0.41 | 167.83 |
| native clang-hostisa-auto-nofma | 0.84 | 5.10 | 0.41 | 167.72 |
| native clang-scalar-O3 | 1.64 | 5.14 | 0.40 | 130.24 |
| wasmtime s-O2-nosimd | 8.22 | 5.24 | 0.87 | 221.40 |
| wasmtime s-O3-autovec-fastmath-relaxed | 2.03 | 2.43 | 0.65 | 343.63 |
| wasmtime s-O3-autovec-fastmath | 2.34 | 2.53 | 0.67 | 344.06 |
| wasmtime s-O3-autovec-il4 | 2.18 | 5.27 | 0.71 | 345.33 |
| wasmtime s-O3-autovec-pragmas | 2.18 | 4.77 | 0.73 | 359.59 |
| wasmtime s-O3-autovec-relaxed | 2.34 | 5.24 | 0.63 | 342.71 |
| wasmtime s-O3-autovec-unroll | 2.33 | 5.23 | 0.73 | 342.73 |
| wasmtime s-O3-autovec | 2.35 | 5.23 | 0.73 | 342.62 |
| wasmtime s-O3-bleeding | 2.34 | 5.24 | 0.62 | 342.67 |
| wasmtime s-O3-nosimd | 8.22 | 5.28 | 0.86 | 216.40 |
| wasmtime w-autovec-O3 | 2.64 | 5.23 | 0.74 | 270.76 |
| wasmtime w-autovec-O4 | 2.64 | 5.23 | 0.73 | 273.35 |
| wasmtime w-autovec-Oz | 2.33 | 5.24 | 0.73 | 269.10 |
| wasmtime w-nosimd-O3 | 8.22 | 5.26 | 0.86 | 329.29 |
| wasmtime w-simd-u4-O3 | 2.18 | 2.74 | 0.27 | 267.49 |
| wasmtime w-simd-u4-O4 | 2.18 | 2.74 | 0.27 | 267.25 |
| wasmtime w-simd-u4-Oz | 2.18 | 2.73 | 0.33 | 277.20 |
| wasmtime x-O2-simd-u4 | 2.18 | 2.74 | 0.29 | 347.75 |
| wasmtime x-O3-simd-relaxed-u2 | 2.34 | 2.55 | 0.33 | 361.27 |
| wasmtime x-O3-simd-u4-Os | 2.18 | 2.77 | 0.27 | 282.67 |
| wasmtime x-O3-simd-u4-nojt | 2.17 | 2.75 | 0.29 | 131.85 |
| wasmtime x-O3-simd-u4 | 2.17 | 2.75 | 0.29 | 344.20 |
| wasmtime x-O3-simd-vb32-u2 | 1.94 | 2.75 | 0.27 | 360.15 |

speed relative to `native cc-scalar-O3` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native cc-hostisa-auto | 1.96 | 2.26 | 1.64 | 1.11 |
| native cc-hostisa-auto-nofma | 1.95 | 2.18 | 1.68 | 1.11 |
| native cc-hostisa-explicit-vb32 | 1.46 | 2.18 | 0.87 | 1.15 |
| native cc-novec | 0.18 | 0.54 | 0.35 | 0.97 |
| native cc-scalar-O2 | 0.94 | 1.02 | 0.86 | 1.18 |
| native cc-scalar-O3 | 1.00 | 1.00 | 1.00 | 1.00 |
| native cc-scalar-nojt | 1.00 | 1.03 | 1.00 | 1.90 |
| native clang-hostisa-auto | 1.31 | 0.58 | 0.77 | 1.04 |
| native clang-hostisa-auto-fastmath | 1.42 | 2.31 | 0.75 | 1.05 |
| native clang-hostisa-auto-nofma | 1.60 | 0.54 | 0.75 | 1.05 |
| native clang-scalar-O3 | 0.82 | 0.54 | 0.76 | 1.36 |
| wasmtime s-O2-nosimd | 0.16 | 0.53 | 0.35 | 0.80 |
| wasmtime s-O3-autovec-fastmath-relaxed | 0.66 | 1.14 | 0.47 | 0.51 |
| wasmtime s-O3-autovec-fastmath | 0.58 | 1.09 | 0.46 | 0.51 |
| wasmtime s-O3-autovec-il4 | 0.62 | 0.52 | 0.43 | 0.51 |
| wasmtime s-O3-autovec-pragmas | 0.62 | 0.58 | 0.42 | 0.49 |
| wasmtime s-O3-autovec-relaxed | 0.57 | 0.53 | 0.49 | 0.52 |
| wasmtime s-O3-autovec-unroll | 0.58 | 0.53 | 0.42 | 0.52 |
| wasmtime s-O3-autovec | 0.57 | 0.53 | 0.42 | 0.52 |
| wasmtime s-O3-bleeding | 0.58 | 0.53 | 0.49 | 0.52 |
| wasmtime s-O3-nosimd | 0.16 | 0.52 | 0.35 | 0.82 |
| wasmtime w-autovec-O3 | 0.51 | 0.53 | 0.41 | 0.65 |
| wasmtime w-autovec-O4 | 0.51 | 0.53 | 0.42 | 0.65 |
| wasmtime w-autovec-Oz | 0.58 | 0.53 | 0.42 | 0.66 |
| wasmtime w-nosimd-O3 | 0.16 | 0.53 | 0.36 | 0.54 |
| wasmtime w-simd-u4-O3 | 0.62 | 1.01 | 1.13 | 0.66 |
| wasmtime w-simd-u4-O4 | 0.62 | 1.01 | 1.13 | 0.66 |
| wasmtime w-simd-u4-Oz | 0.62 | 1.01 | 0.94 | 0.64 |
| wasmtime x-O2-simd-u4 | 0.62 | 1.01 | 1.05 | 0.51 |
| wasmtime x-O3-simd-relaxed-u2 | 0.57 | 1.09 | 0.94 | 0.49 |
| wasmtime x-O3-simd-u4-Os | 0.62 | 1.00 | 1.12 | 0.62 |
| wasmtime x-O3-simd-u4-nojt | 0.62 | 1.01 | 1.07 | 1.34 |
| wasmtime x-O3-simd-u4 | 0.62 | 1.01 | 1.07 | 0.51 |
| wasmtime x-O3-simd-vb32-u2 | 0.69 | 1.01 | 1.15 | 0.49 |

