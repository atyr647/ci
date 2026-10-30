## mac-x64: wasm-platforms run 41064377721, commit cfebe33790a07a49dfd63623c437d5b105200ba9
Intel(R) Core(TM) i7-8700B CPU @ 3.20GHz
wasmtime 50.0.0 (ebe5e8df1 2026-10-20)
/usr/bin/clang
Apple clang version 17.0.0 (clang-1700.0.13.5)
/usr/bin/cc
Apple clang version 17.0.0 (clang-1700.0.13.5)
Python 3.14.7
### Platforms mac-x64 (ref = native scalar source, baseline ISA, compiler auto-vectorised): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.73 | 4.19 | 0.66 | 755.13 |
| native n-hostisa-vb32-u2 | 1.76 | 1.80 | 0.69 | 856.71 |
| native n-scalar | 3.28 | 5.75 | 0.95 | 734.34 |
| native n-simd128-u2 | 2.97 | 2.94 | 0.70 | 737.15 |
| wasmtime scalar | 15.38 | 6.25 | 1.58 | 894.46 |
| wasmtime autovec | 4.42 | 6.00 | 1.42 | 991.92 |
| wasmtime simd | 3.77 | 3.77 | 0.76 | 1005.03 |
| wasmtime simd-u2 | 3.72 | 3.41 | 0.96 | 988.50 |
| wasmtime simd-vb32-u2 | 3.61 | 3.54 | 0.95 | 1004.17 |
| wasmtime relaxed | 3.34 | 2.74 | 0.69 | 1031.63 |
| wasmtime relaxed-u2 | 4.08 | 2.47 | 0.81 | 1020.98 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.90 | 1.37 | 1.43 | 0.97 |
| native n-hostisa-vb32-u2 | 1.86 | 3.19 | 1.38 | 0.86 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128-u2 | 1.11 | 1.96 | 1.36 | 1.00 |
| wasmtime scalar | 0.21 | 0.92 | 0.60 | 0.82 |
| wasmtime autovec | 0.74 | 0.96 | 0.67 | 0.74 |
| wasmtime simd | 0.87 | 1.53 | 1.25 | 0.73 |
| wasmtime simd-u2 | 0.88 | 1.68 | 0.99 | 0.74 |
| wasmtime simd-vb32-u2 | 0.91 | 1.62 | 1.00 | 0.73 |
| wasmtime relaxed | 0.98 | 2.10 | 1.38 | 0.71 |
| wasmtime relaxed-u2 | 0.80 | 2.33 | 1.18 | 0.72 |

