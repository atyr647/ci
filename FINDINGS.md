# What the runners showed (2026-10-29)

Same C source (`ci-webgpu-test/wgt.c`, `webgpu.h` API): compute dispatch + readback, output hash `9761e8ede774e783` on every pass.

| target (real runner) | wgpu-native direct | Dawn static (prebuilt nightly) | ONE Cosmopolitan APE dlopen(wgpu-native) |
|---|---|---|---|
| linux x64 (lavapipe) | PASS Vulkan | PASS Vulkan | PASS (also with no C compiler on PATH) |
| linux arm64 (lavapipe) | PASS | no prebuilt | PASS (also no cc) |
| windows x64 | PASS D3D12 (WARP) | PASS D3D12 only after dxcompiler.dll+dxil.dll are placed next to the exe | PASS D3D12 (after the ms_abi fix) |
| windows arm64 | PASS D3D12 | no prebuilt | PASS (APE runs as x86-64 under emulation, needs the x64 DLL) |
| macOS arm64 (Metal) | PASS | PASS | PASS |
| macOS x64 (Metal) | PASS | PASS | FAIL: Cosmopolitan 4.0.2 `dlopen()` is unsupported on x86-64 macOS |

Windows quirks of the Cosmopolitan 4.0.2 APE (real Windows, not Wine):
- process exit status comes out shifted left by 8 (`exit(7)` is seen as 1792; bash/cmd truncate that to 0). Do not rely on exit codes on Windows.
- `system("curl")`/`execvp("curl")` fail ("No such file or directory") although `C:\Windows\System32\curl.exe` exists and works when spawned by absolute path with fork+execv.
- calling a native DLL needs Microsoft-ABI function pointers and Microsoft-ABI callbacks (struct-by-value arguments break through `cosmo_dltramp`); see `ci-webgpu-test/gen-shim.py`.

Dawn on Windows: the "Windows Error 87" came from Dawn's own `DynamicLib::Open` (flag `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` is only valid with an absolute path). Dawn only finds `dxcompiler.dll`/`dxil.dll`/`d3dcompiler_47.dll` when they sit next to the module; the OS copies are not used.

Wine: Cosmopolitan APE hangs on Wine 11 because Cosmopolitan picks `0x6ffffffe0000` for a small shared mapping and Wine 11 has its ntdll image at `0x6fffffc00000-0x6ffffffedfff`; the mapping fails with STATUS_CONFLICTING_ADDRESSES and Cosmopolitan re-picks the same address forever (735k identical iterations traced). (Plain Windows executables run fine under Wine 11 once `XDG_RUNTIME_DIR` is set.)

Darling: the 2026 release has no kernel module (userspace `darlingserver`); installs and runs on ubuntu-24.04 runners and in the Claude sandbox (user namespaces + overlayfs available). Runs x86-64 Mach-O (zig-built launcher reports `macos-x86_64`). The APE loader printed nothing under Darling (not investigated). No Metal, so no GPU tests.

## Dawn built from source as a shared library (workflow `dawn-shared`, commit 106704a9)
| target | built | C source linked directly | ONE Cosmopolitan file `dlopen`ing Dawn's own library |
|---|---|---|---|
| macOS arm64 | yes (~18 min) | PASS Metal | PASS Metal |
| macOS x64 | yes (~29 min) | PASS Metal | FAIL: Cosmopolitan has no dlopen on x86-64 macOS |
| Windows arm64 | yes (~33 min) | (not read) | FAIL as expected: arm64 DLL cannot load into the x86-64 emulated file; needs an x64 build of Dawn for this route |
| Windows x64 | still building at 17:21 UTC | | |
| Linux x64 / arm64 | CMake 4 refused to configure (`dawncpp_module` module scan); fixed with `-DCMAKE_CXX_SCAN_FOR_MODULES=OFF`, re-run queued | | |

## Dawn compiled with the Cosmopolitan compiler (workflow `dawn-cosmo`, Vulkan backend only, no windowing)
Configure now succeeds (needed the APE loader as `CMAKE_CROSSCOMPILING_EMULATOR`). The compile reached step 755 of 1009 (Tint and SPIR-V-Tools largely built) and stopped on 2 failed targets; the failure text was not printed (workflow fixed to print it, re-run queued).

## One Cosmopolitan file -> official Wasmtime -> wasm guest (workflow `wasm-host`, Wasmtime v50.0.0, guest = wasip1 core module calling a `send`/`recv` import pair served by C)
| target | result |
|---|---|
| linux x64 | PASS, 20/20 repeated runs |
| linux arm64 | before the fix: intermittent SIGSEGV right after the first host callback, 9/20 passed (x64: 20/20). After the fix below: PASS, 20/20 |
| windows x64 / arm64 (x86-64 emulated) | PASS |
| macOS arm64 | before the fix: hang on the first call into wasm (even with the Pulley interpreter, no Mach exception thread, or explicit bounds checks). After the fix below: PASS in all four variants |
| macOS x64 | not pursued (Cosmopolitan has no `dlopen` there; not a target) |

Cause and fix (measured, both arm64 failures vanished together): on aarch64 Cosmopolitan keeps its thread pointer in register x28. Wasmtime's code may use x28 for anything, so when it calls a host function written in Cosmopolitan C, that C code runs with a garbage thread pointer (the first `printf` in the callback hung on macOS or crashed on Linux). The callback now saves Wasmtime's x28, restores Cosmopolitan's own on entry and puts Wasmtime's back on return (`TLS_ENTER`/`TLS_LEAVE` in `ci-wasm-host/wt-host.c`). This applies to ANY callback from foreign code into Cosmopolitan code on aarch64, including Dawn-to-Vulkan callbacks.

## Wasmtime C API and WASI 0.3 (workflow `wasmtime-p3-capi`)
- Patch `ci-wasm-host/wasmtime-c-api-wasip3.patch` (9 lines Rust + 1 header declaration) on the unmodified v50.0.0 tag builds on linux x64, macOS arm64 and windows x64.
- OFFICIAL library, plain-C host: a wasip2 component runs (`wasmtime_component_linker_add_wasip2_async`); for p3 there is no linker call to make (confirmed on linux x64 and macOS arm64).
- PATCHED library, plain-C host: the p2 component AND a wasm32-wasip3 component (wasi-sdk 34, `hello-wasip3.wasm`) both run and `run()` returns ok on linux x64, macOS arm64 (after making the dylib install name relocatable) and windows x64.
- Not tested: a component that uses `stream`/`future` values across the host boundary. The C API has no component value kinds for them (valkinds end at MAP), so typed async GPU calls from C would still need new API.

## Dawn compiled with the Cosmopolitan compiler (continued)
Only 5 errors in 2 files remained: `dladdr`, `Dl_info`, `RTLD_NOLOAD` (SystemUtils.cpp, DynamicLib.cpp). Patched in the workflow; the re-run (does `libwebgpu_dawn.a` link?) is in progress.

## Dawn shared, Linux arm64
`libwebgpu_dawn.so` (21 MB) built; direct link PASS and ONE Cosmopolitan APE `dlopen` PASS (Vulkan/lavapipe), hash 9761e8ede774e783.

## Adapters seen (software/virtual: no real GPU in any result)
Windows: D3D12 "Microsoft Basic Render Driver" (WARP). macOS: Metal "Apple Paravirtual device". Linux: Vulkan llvmpipe.

## Dawn under Cosmopolitan: Vulkan works on x86-64 (local run), D3D12 and Metal feasibility probes
- Vulkan backend: Dawn `106704a` + `dawn-cosmo/patch.py` compiles with 0 failed objects; the linked test runs a compute dispatch on Vulkan (lavapipe) with the expected hash, 3/3 runs (x86-64, local). The two-architecture CI run is separate.
- A GCC miscompile cost most of the debugging: with the Microsoft/System V call wrapper inlined, the 10th Vulkan call in a sequence got a clobbered first argument and the loader aborted ("Invalid physicalDevice"); marking the wrapper `noinline` fixes it. Root cause not established.
- Sizes: Dawn d3d12 backend 83 files / 19.5k lines + shared d3d code 31 files / 3.6k lines; metal backend 54 files / 12.7k lines, 24 of them Objective-C++ (.mm).
- D3D12 probe (measured): mingw-w64 Windows headers cannot be used (Windows `long` is 32-bit, Linux/Cosmopolitan `long` is 64-bit: `size_t`/`DWORD` clash); faking `_WIN32` globally switches libc++ to Windows-only code paths (about 16,700 errors). Microsoft's DirectX-Headers (Linux-safe types) DO compile under cosmocc with the right layout (`HRESULT`/`ULONG`/`DWORD` = 4 bytes, `D3D12_RESOURCE_DESC` = 56 bytes). DXGI headers are not part of that package.
- Metal probe (measured on a toy file only): cosmocc 4.0.2 bundles clang 19.1 (`cosmocc -mclang`); it compiles Objective-C++ with `-fobjc-arc -fblocks -fobjc-runtime=macosx` to x86-64 and aarch64 objects. The objects reference `objc_msgSend`, `OBJC_CLASS_$_*`, `_NSConcreteStackBlock` and keep selector/class references in ELF sections `objc_selrefs`/`objc_classrefs`, which dyld normally fixes up; nothing does that inside an APE, so a start-up registration shim would be needed. Not tried on real Dawn Metal sources (needs the Apple SDK headers, i.e. a macOS runner).
- Correction: an earlier statement that cosmocc has no Objective-C front end was wrong.

## Dawn compiled by Cosmopolitan, ONE fat file (workflow `dawn-cosmo`, run on commit 04fc895: x86-64 and aarch64 builds linked with apelink)
Both architectures of Dawn (Vulkan backend) build in CI (x86_64 about 26 min, aarch64 about 19 min, 0 failed objects) and link into one executable. Test = the same WebGPU compute dispatch, expected hash 9761e8ede774e783:
| target | result |
|---|---|
| linux x64 (lavapipe) | PASS |
| linux arm64 (lavapipe) | PASS |
| macOS arm64 | first run FAIL (`vkCreateInstance` returned VK_ERROR_INCOMPATIBLE_DRIVER; native Dawn behaved the same: MoltenVK only appears when the instance enables VK_KHR_portability_enumeration with the matching create flag). After `patch.py` item 10: **PASS** through MoltenVK 1.4.2 ("Apple Paravirtual device"), correct hash (run on commit 3edfd84). |
| windows x64 | FAIL: uncaught SIGSEGV (no backtrace). Crash reports now compiled into the test. |
| windows arm64 (x86-64 emulated) | FAIL: the loader reported Vulkan 1.0 ("at least 1.1.0" required) |
Native (non-Cosmopolitan) Dawn on the same Windows runner: D3D12 PASS, but its Vulkan backend with Mesa lavapipe also found no adapter, so the Windows Vulkan driver setup itself is not yet right (separate from the SIGSEGV).

Status after the second run (commit 3edfd84): ONE file with Dawn compiled by Cosmopolitan passes the compute test on linux x64, linux arm64 and macOS arm64 (Vulkan on Linux via lavapipe, on macOS via MoltenVK). Windows x64 and arm64 still crash inside the Windows Vulkan loader during adapter request; logs from that run were partly overwritten because stdout and stderr shared one redirected file on Windows (run-one.sh now uses one pipe).

## Windows: what blocked Dawn, found one by one (all measured)
1. The Vulkan loader on Windows ignores VK_ICD_FILENAMES / VK_DRIVER_FILES when the process is elevated (GitHub's Windows runners are). A software driver (Mesa lavapipe) must be registered under `HKLM\SOFTWARE\Khronos\Vulkan\Drivers` (value name = path of the ICD json, DWORD 0). With that, a native Python process sees 1 physical device, and the Cosmopolitan probe (`ci-webgpu-test/vkprobe.c`) passes on Windows x64: loads `vulkan-1.dll`, calls it with the Microsoft ABI, finds llvmpipe.
2. Cosmopolitan on Windows turns every unknown SEH exception into a fatal SIGSEGV, including DBG_PRINTEXCEPTION_C (0x40010006) that `OutputDebugString` raises (the loader with VK_LOADER_DEBUG, Dawn's logging, many DLLs). A first-in-line vectored exception handler returning EXCEPTION_CONTINUE_EXECUTION for 0x40010006 / 0x4001000A / 0x406D1388 fixes it (`ci-webgpu-test/win_shield.h`). Verified in the probe: without the shield the process dies at the first loader log line, with it the run continues.
3. GCC miscompiled the run-time switch `IsWindows() ? ms_abi_call(args) : sysv_call(args)`: the disassembly of the compiled wrapper shows ONE call with System V registers and a tail `jmp`; the Microsoft branch was dropped (its call-merging does not compare the calling convention). On Linux/macOS the surviving System V call is the right one, on Windows every Vulkan call arrived with the wrong registers (the crash report showed a garbage handle in RCX). Earlier symptom on Linux: the 10th call of a sequence failed when the wrapper was inlined. Fix in `dawn-cosmo/patch.py`: out-of-line wrapper plus two differently worded asm statements so the branches cannot be merged. Verification in CI pending at the time of writing.

## Shader compiler pieces under Cosmopolitan and wasm (measured)
- Tint HLSL and MSL writers (needed for D3D12 and Metal): built with the Cosmopolitan toolchain, 351/351 steps, 0 failures (x86-64).
- Tint to wasm32-wasip1: first attempt failed only in platform detection (`src/utils/platform.h` "Unsupported platform"); patched with `__wasi__` and re-run queued.

## D3D12 / Metal backend facts (measured by reading the Dawn sources)
- Metal backend: 9,724 lines of Objective-C++ in 24 files; defines NO Objective-C classes; 5 NSString literals (2 files); 0 selector/array/dictionary literals; 2 block-taking calls (`addScheduledHandler`, `addCompletedHandler` in QueueMTL.mm); a handful of IOSurface/IOKit/CF C calls. cosmocc 4.0.2 bundles clang 19.1 (`cosmocc -mclang`) that compiles Objective-C++ with ARC and blocks for the Cosmopolitan target.
- D3D12 + shared D3D code: about 23k lines; about 12 distinct Win32 functions used; 27 ID3D12 interfaces, 11 IDXGI interfaces. Microsoft's DirectX-Headers compile under cosmocc with correct sizes; mingw-w64 headers do not (LLP64 vs LP64).
- Sizes: native Dawn Windows DLL 10.9 MB, macOS dylib 18 MB, Cosmopolitan Vulkan-only x86-64 half 23 MB.
- Verified locally after the fix: the compiled wrapper now contains BOTH branches (`test %al` / `jne`; the Windows branch reserves the 32-byte shadow space and moves the arguments into RCX/RDX/R8/R9 before `call *(%r15)`; the other branch tail-jumps with System V registers), and the x86-64 Linux run still passes. CI check on Windows still to come.

## Wasmtime INSIDE the Cosmopolitan file, wasm threads, wasm SIMD, Tint as wasm (measured 2026-10-30, Wasmtime v50.0.0, cosmocc 4.0.2)

**Wasmtime linked into the executable (workflow `wasmtime-bundle`, job `static-link`).** `libwasmtime.a` is built from source for the Rust musl target (C parts with the Cosmopolitan compiler) and linked with the host into one Cosmopolitan executable: no dlopen, no extraction.
- Needed: stubs for the Linux calls Cosmopolitan lacks (`epoll_*`, `eventfd`, `mkfifo`, `waitid`; `ci-wasm-host/static-stubs.c`); Rust's I/O reactor (mio) built with `--cfg mio_unsupported_force_poll_poll --cfg mio_unsupported_force_waker_pipe` so it uses poll(2) and a pipe instead of epoll/eventfd (the eventfd stub's ENOSYS reached Rust's error formatting and crashed - found with gdb on the CI artifact: `mio::Selector::new -> eventfd`). Cosmopolitan's own `strerror_r` already has the POSIX (XSI) form (measured: returns 0 and fills the buffer), so nothing is replaced there; two earlier attempts at "fixing" it (a redefinition, then `--wrap`) only added crashes (infinite recursion through Cosmopolitan's `strerror`).
- Result on Linux x86-64: **PASS** - the host loads the wasm guest, the guest calls the host import, the host answers, exit code 0 (run 8, commit 6d9b73e).
- The same code in the fat file (x86-64 + arm64, `static-fat`) on the other four targets (run 9, commit 9be6b72): **FAIL on all four, each for a different reason, all from one cause.** Rust's standard library and its `libc` crate are compiled for the Linux musl target, so they pass **Linux's numeric constants** (clock ids, `getrandom` flags, errno values, mmap/open flags, signal numbers) to Cosmopolitan's C library, which on every other OS expects *its own run-time constants* for that OS. Measured:
  - macOS arm64: `Timespec::now` -> `clock_gettime(1, ...)` returns EINVAL (1 is Linux's CLOCK_MONOTONIC, macOS's is 6) -> `unwrap()` panic during `wasm_engine_new`/`store_new`.
  - Windows x64: `getrandom(buf, n, flags=4)` (GRND_INSECURE, Linux number) -> `errno=87` -> panic in `std::sys::random` during `wasm_engine_new`.
  - Linux arm64: panic "strerror_r failure" while module compilation (some earlier call fails; the original error is hidden behind this one - not diagnosed, no debugger for arm64 here).
  - Even if each of those were translated, macOS arm64 would still not be able to run Wasmtime's JIT: code compiled for `*-linux-musl` does not use `MAP_JIT` / `pthread_jit_write_protect_np`, which Apple Silicon requires for executable memory; the official macOS library does.
  So "Wasmtime (JIT) statically linked into the Cosmopolitan file" works where the host really is Linux x86-64 and nowhere else without a translation layer of unknown size. What does work on all five targets today is the **bundled** form (the four official libraries stored inside the executable, extracted to a temp file at first use, `cosmo_dlopen`ed: run 9 `bundled-test`, 5/5 PASS).
- Option that makes one implementation really static on every OS: Wasmtime's **custom-platform / no_std** build (docs: "Building Wasmtime for a Custom Platform"): no Rust std, no libc crate; the embedder supplies ~20 C functions (mmap/mprotect, TLS, locks, fibers; compiled by Cosmopolitan, so with the right constants). Costs, from the same page: **no Cranelift/Winch** (modules must be precompiled to `.cwasm` for the exact Wasmtime version and CPU target, one per architecture), **no WASI**, `signals-based-traps` off (explicit bounds checks, slower), nightly Rust and a custom target. Not tried here.
- aarch64: the static link itself works (Rust std rebuilt with x28 reserved, Cosmopolitan keeps its thread pointer there).

**Wasm threads (workflow `wasm-perf`, job `threads-host`).** Wasmtime removed `wasi-threads` in v47 (`-Sthreads` is gone from the CLI). A host can still provide `wasi:thread-spawn` itself through the C API (shared memory object + one store/instance per thread: `ci-wasm-host/threads-host.c`, ~100 lines). The module must be linked with `--import-memory` (wasi-sdk's `wasm32-wasip1-threads` alone produced a module that defines its own memory, which cannot be shared with the extra instances). Fixed work split over N threads, wall time in ms (the guest measures itself):
| runner | wasm 1 / 2 / 4 threads | native (Cosmopolitan) 1 / 4 threads |
|---|---|---|
| linux x64 (4 vCPU) | 189 / 126 / 96 | 182 / 95 |
| linux arm64 (4 vCPU) | 140 / 71 / 54 | 139 / 35 |
| macOS arm64 (5 cores) | 68 / 33 / 20 | 81 / 21 |
Scaling is real and the 1-thread time equals native. On linux arm64 the 4-thread wasm time is 54 ms against 35 ms native; the difference is plausibly thread start-up (each thread instantiates the module; not measured separately) - a thread pool created once avoids it. One run per cell on shared runners: treat differences under ~20% as noise.

**SIMD (workflow `wasm-perf`, job `run`).** One C source, wasm built by wasi-sdk 34 clang (scalar, auto-vectorised, explicit `v4f` vector extensions = wasm SIMD128, and lowered vectors), run by Wasmtime's Cranelift JIT; native built by Cosmopolitan GCC at baseline ISA (SSE2 / NEON, no AVX). Fastest of 9 trials, ns per item (lower is better):
| runner | wasm scalar | wasm autovec | **wasm SIMD128** | native scalar | native SIMD |
|---|---|---|---|---|---|
| linux x64 vertex transform | 3.12 | 2.75 | **1.12** | 1.18 | 1.26 |
| linux x64 dot product | 1.645 | 1.644 | **0.248** | 0.938 | 0.150 |
| windows x64 transform | 3.11 | 2.76 | **1.07** | 1.18 | 1.26 |
| windows x64 dot | 1.642 | 1.637 | **0.237** | 0.937 | 0.144 |
| linux arm64 transform | 7.61 | 4.22 | **2.27** | 1.62 | 1.01 |
| linux arm64 dot | 0.964 | 0.963 | **0.213** | 0.593 | 0.169 |
| macOS arm64 transform | 5.49 | 1.69 | **1.65** | 0.69 | 0.54 |
| macOS arm64 dot | 1.650 | 1.667 | **0.248** | 1.025 | 0.111 |
Reading: with explicit SIMD128, wasm is within about 1.0x (x86-64 transform) to 3x (macOS arm64) of native 128-bit SIMD, and 1.6x-2.2x on the dot product. Scalar/auto-vectorised wasm is 2.5x-11x slower than native. So SIMD-heavy kernels can live in wasm if written with SIMD128 (clang vector extensions or `wasm_simd128.h`); anything that needs AVX2/AVX-512 or NEON-specific instructions is not expressible and stays native. Not measured: AVX2 native (the baseline was used on purpose to compare like with like), memory-bound vs cache-resident variants separately.

**Tint (WGSL compiler) as wasm (workflow `tint-wasm`).** Dawn's Tint command-line tool compiles to `wasm32-wasip1` with wasi-sdk 34: 665/665 objects, 14 MB module, 0 errors. It needs a bigger shadow stack than wasi-sdk's 1 MB default (`-Wl,-z,stack-size=33554432`; with 1 MB it died with a wasm memory fault at address 0xfffff544 = stack overflow below address 0). Run under Wasmtime on one compute shader: WGSL -> HLSL (421 bytes), MSL (1219 bytes), WGSL (241 bytes) in 0.07 s and ~70 MB each; WGSL -> SPIR-V (1048 bytes) takes 3.3 s and 245 MB (the SPIR-V path is much heavier; not investigated). So the shader compiler can be a wasm module (14 MB) next to the game's wasm instead of native code in the host.
