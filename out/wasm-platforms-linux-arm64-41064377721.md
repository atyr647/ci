## linux-arm64: wasm-platforms run 41064377721, commit cfebe33790a07a49dfd63623c437d5b105200ba9
(cpu name unavailable)
wasmtime 50.0.0 (ebe5e8df1 2026-10-20)
/usr/bin/clang
Ubuntu clang version 18.1.3 (1ubuntu1)
/usr/bin/cc
cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0
Python 3.12.3
### Platforms linux-arm64 (ref = native scalar source, baseline ISA, compiler auto-vectorised): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.64 | 4.04 | 0.43 | 77.12 |
| native n-hostisa-vb32-u2 | 6.29 | 4.85 | 0.34 | 76.41 |
| native n-scalar | 1.63 | 3.77 | 0.44 | 77.54 |
| native n-simd128-u2 | 1.54 | 3.74 | 0.34 | 76.72 |
| wasmtime scalar | 8.94 | 5.07 | 2.07 | 128.12 |
| wasmtime autovec | 2.28 | 5.07 | 1.11 | 127.98 |
| wasmtime simd | 2.05 | 4.04 | 0.58 | 128.14 |
| wasmtime simd-u2 | 2.28 | 4.02 | 0.58 | 127.98 |
| wasmtime simd-vb32-u2 | 2.07 | 3.99 | 0.58 | 128.00 |
| wasmtime relaxed | 1.88 | 3.83 | 0.54 | 127.96 |
| wasmtime relaxed-u2 | 2.03 | 3.78 | 0.55 | 128.05 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.00 | 0.93 | 1.01 | 1.01 |
| native n-hostisa-vb32-u2 | 0.26 | 0.78 | 1.30 | 1.01 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128-u2 | 1.06 | 1.01 | 1.27 | 1.01 |
| wasmtime scalar | 0.18 | 0.74 | 0.21 | 0.61 |
| wasmtime autovec | 0.72 | 0.74 | 0.40 | 0.61 |
| wasmtime simd | 0.80 | 0.94 | 0.75 | 0.61 |
| wasmtime simd-u2 | 0.71 | 0.94 | 0.75 | 0.61 |
| wasmtime simd-vb32-u2 | 0.79 | 0.95 | 0.75 | 0.61 |
| wasmtime relaxed | 0.87 | 0.99 | 0.81 | 0.61 |
| wasmtime relaxed-u2 | 0.80 | 1.00 | 0.80 | 0.61 |

