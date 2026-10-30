## win-x64: wasm-platforms run 41064377721, commit cfebe33790a07a49dfd63623c437d5b105200ba9
model name	: AMD EPYC 9V74 80-Core Processor                
wasmtime 50.0.0 (ebe5e8df1 2026-10-20)
/c/Program Files/LLVM/bin/clang
clang version 20.1.8
/c/mingw64/bin/cc
cc.exe (x86_64-posix-seh-rev1, Built by MinGW-Builds project) 15.2.0
Python 3.12.10
### Platforms win-x64 (ref = native scalar source, baseline ISA, compiler auto-vectorised): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 0.60 | 4.13 | 0.20 | 144.01 |
| native n-hostisa-vb32-u2 | 0.58 | 1.02 | 0.18 | 103.55 |
| native n-scalar | 1.25 | 4.15 | 0.35 | 107.99 |
| native n-simd128-u2 | 1.26 | 2.12 | 0.27 | 112.13 |
| wasmtime scalar | 6.15 | 4.21 | 0.88 | 121.40 |
| wasmtime autovec | 2.04 | 4.21 | 0.44 | 170.57 |
| wasmtime simd | 1.75 | 2.22 | 0.31 | 170.32 |
| wasmtime simd-u2 | 2.04 | 2.19 | 0.31 | 173.64 |
| wasmtime simd-vb32-u2 | 1.66 | 2.28 | 0.31 | 171.27 |
| wasmtime relaxed | 1.77 | 2.10 | 0.32 | 171.09 |
| wasmtime relaxed-u2 | 2.04 | 2.08 | 0.51 | 226.46 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 2.07 | 1.00 | 1.77 | 0.75 |
| native n-hostisa-vb32-u2 | 2.15 | 4.06 | 1.92 | 1.04 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128-u2 | 0.99 | 1.95 | 1.30 | 0.96 |
| wasmtime scalar | 0.20 | 0.98 | 0.40 | 0.89 |
| wasmtime autovec | 0.61 | 0.99 | 0.78 | 0.63 |
| wasmtime simd | 0.71 | 1.87 | 1.11 | 0.63 |
| wasmtime simd-u2 | 0.61 | 1.89 | 1.14 | 0.62 |
| wasmtime simd-vb32-u2 | 0.75 | 1.82 | 1.13 | 0.63 |
| wasmtime relaxed | 0.70 | 1.97 | 1.10 | 0.63 |
| wasmtime relaxed-u2 | 0.61 | 1.99 | 0.68 | 0.48 |

