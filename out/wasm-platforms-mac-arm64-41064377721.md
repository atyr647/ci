## mac-arm64: wasm-platforms run 41064377721, commit cfebe33790a07a49dfd63623c437d5b105200ba9
Apple M1 (Virtual)
wasmtime 50.0.0 (ebe5e8df1 2026-10-20)
/usr/bin/clang
Apple clang version 21.0.0 (clang-2100.1.1.101)
/usr/bin/cc
Apple clang version 21.0.0 (clang-2100.1.1.101)
Python 3.15.0
### Platforms mac-arm64 (ref = native scalar source, baseline ISA, compiler auto-vectorised): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.39 | 1.52 | 0.20 | 129.29 |
| native n-hostisa-vb32-u2 | 1.34 | 0.91 | 0.15 | 127.62 |
| native n-scalar | 1.42 | 1.50 | 0.19 | 116.56 |
| native n-simd128-u2 | 1.42 | 0.97 | 0.15 | 121.44 |
| wasmtime scalar | 7.18 | 2.42 | 1.28 | 145.13 |
| wasmtime autovec | 1.72 | 2.43 | 0.45 | 165.06 |
| wasmtime simd | 1.56 | 1.39 | 0.41 | 167.16 |
| wasmtime simd-u2 | 1.74 | 1.28 | 0.41 | 155.69 |
| wasmtime simd-vb32-u2 | 1.55 | 1.23 | 0.42 | 146.99 |
| wasmtime relaxed | 1.39 | 1.09 | 0.38 | 147.40 |
| wasmtime relaxed-u2 | 1.57 | 1.01 | 0.39 | 155.13 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.02 | 0.99 | 0.96 | 0.90 |
| native n-hostisa-vb32-u2 | 1.06 | 1.66 | 1.21 | 0.91 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128-u2 | 1.00 | 1.55 | 1.21 | 0.96 |
| wasmtime scalar | 0.20 | 0.62 | 0.15 | 0.80 |
| wasmtime autovec | 0.82 | 0.62 | 0.42 | 0.71 |
| wasmtime simd | 0.91 | 1.09 | 0.46 | 0.70 |
| wasmtime simd-u2 | 0.81 | 1.17 | 0.46 | 0.75 |
| wasmtime simd-vb32-u2 | 0.91 | 1.23 | 0.44 | 0.79 |
| wasmtime relaxed | 1.02 | 1.38 | 0.50 | 0.79 |
| wasmtime relaxed-u2 | 0.90 | 1.49 | 0.49 | 0.75 |

