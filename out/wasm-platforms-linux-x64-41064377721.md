## linux-x64: wasm-platforms run 41064377721, commit cfebe33790a07a49dfd63623c437d5b105200ba9
model name	: AMD EPYC 7763 64-Core Processor
wasmtime 50.0.0 (ebe5e8df1 2026-10-20)
/usr/bin/clang
Ubuntu clang version 18.1.3 (1ubuntu1)
/usr/bin/cc
cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
Python 3.12.3
### Platforms linux-x64 (ref = native scalar source, baseline ISA, compiler auto-vectorised): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 0.69 | 1.23 | 0.15 | 145.12 |
| native n-hostisa-vb32-u2 | 0.93 | 1.27 | 0.35 | 147.53 |
| native n-scalar | 1.35 | 2.75 | 0.30 | 166.85 |
| native n-simd128-u2 | 1.97 | 2.59 | 0.35 | 170.16 |
| wasmtime scalar | 8.22 | 5.28 | 0.85 | 216.22 |
| wasmtime autovec | 2.36 | 5.23 | 0.73 | 343.17 |
| wasmtime simd | 2.06 | 2.79 | 0.28 | 344.09 |
| wasmtime simd-u2 | 2.73 | 2.75 | 0.29 | 345.84 |
| wasmtime simd-vb32-u2 | 1.93 | 2.75 | 0.27 | 362.04 |
| wasmtime relaxed | 2.06 | 2.58 | 0.27 | 363.73 |
| wasmtime relaxed-u2 | 2.35 | 2.55 | 0.33 | 360.76 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.96 | 2.24 | 1.99 | 1.15 |
| native n-hostisa-vb32-u2 | 1.45 | 2.16 | 0.86 | 1.13 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128-u2 | 0.68 | 1.06 | 0.86 | 0.98 |
| wasmtime scalar | 0.16 | 0.52 | 0.36 | 0.77 |
| wasmtime autovec | 0.57 | 0.53 | 0.42 | 0.49 |
| wasmtime simd | 0.65 | 0.99 | 1.07 | 0.48 |
| wasmtime simd-u2 | 0.49 | 1.00 | 1.05 | 0.48 |
| wasmtime simd-vb32-u2 | 0.70 | 1.00 | 1.13 | 0.46 |
| wasmtime relaxed | 0.65 | 1.07 | 1.12 | 0.46 |
| wasmtime relaxed-u2 | 0.58 | 1.08 | 0.93 | 0.46 |

