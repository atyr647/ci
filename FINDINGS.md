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
