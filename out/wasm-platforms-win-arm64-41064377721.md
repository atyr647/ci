## win-arm64: wasm-platforms run 41064377721, commit cfebe33790a07a49dfd63623c437d5b105200ba9
model name	: Virtual CPU @ 3.39GHz
wasmtime 50.0.0 (ebe5e8df1 2026-10-20)
/c/Program Files/LLVM/bin/clang
clang version 22.1.8 (https://github.com/llvm/llvm-project ca7933e47d3a3451d81e72ac174dcb5aa28b59d1)
/c/mingw64/bin/cc
cc.exe (x86_64-posix-seh-rev2, Built by MinGW-Builds project) 14.2.0
Python 3.13.17
### Platforms win-arm64 (ref = native scalar source, baseline ISA, compiler auto-vectorised): ms per kernel (best of 3 interleaved rounds)

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 1.88 | 3.98 | 0.41 | 76.95 |
| native n-hostisa-vb32-u2 | 1.53 | 3.77 | 0.27 | 78.32 |
| native n-scalar | 1.59 | 4.03 | 0.38 | 79.22 |
| native n-simd128-u2 | 1.81 | 3.73 | 0.24 | 78.90 |
| wasmtime scalar | 8.93 | 5.06 | 2.06 | 128.22 |
| wasmtime autovec | 2.27 | 5.07 | 1.10 | 128.18 |
| wasmtime simd | 2.04 | 4.03 | 0.59 | 127.99 |
| wasmtime simd-u2 | 2.27 | 4.02 | 0.59 | 128.05 |
| wasmtime simd-vb32-u2 | 2.05 | 3.98 | 0.58 | 128.07 |
| wasmtime relaxed | 1.87 | 3.82 | 0.55 | 128.10 |
| wasmtime relaxed-u2 | 2.02 | 3.77 | 0.55 | 128.16 |

speed relative to `native n-scalar` (above 1.00 = faster); `!` = checksum differs from the reference row

| config | matmul256 | nbody1024 | transform | interp |
|---|---|---|---|---|
| native n-hostisa-auto | 0.85 | 1.01 | 0.93 | 1.03 |
| native n-hostisa-vb32-u2 | 1.04 | 1.07 | 1.40 | 1.01 |
| native n-scalar | 1.00 | 1.00 | 1.00 | 1.00 |
| native n-simd128-u2 | 0.88 | 1.08 | 1.58 | 1.00 |
| wasmtime scalar | 0.18 | 0.80 | 0.19 | 0.62 |
| wasmtime autovec | 0.70 | 0.79 | 0.35 | 0.62 |
| wasmtime simd | 0.78 | 1.00 | 0.65 | 0.62 |
| wasmtime simd-u2 | 0.70 | 1.00 | 0.65 | 0.62 |
| wasmtime simd-vb32-u2 | 0.78 | 1.01 | 0.66 | 0.62 |
| wasmtime relaxed | 0.85 | 1.05 | 0.70 | 0.62 |
| wasmtime relaxed-u2 | 0.79 | 1.07 | 0.70 | 0.62 |

