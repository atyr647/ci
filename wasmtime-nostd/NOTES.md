# Wasmtime v50 runtime-only, no_std, custom platform, inside ONE Cosmopolitan file

Everything below was measured in CI (workflow `wasmtime-nostd`, final runs listed at the end). Nothing here is a claim about hardware GPUs or about untested OS versions.

## What was built
- `embedding/`: a ~190-line `#![no_std]` Rust staticlib around `wasmtime = "=50.0.0"` with `default-features = false, features = ["runtime", "pulley", "custom-virtual-memory", "custom-native-signals"]`. No Cranelift, no std, no WASI, no rustix/libc/memfd/windows-sys. C API: `wn_init(mode)`, `wn_define(module,name,sig,cb,user)`, `wn_load(cwasm)`, `wn_instantiate`, `wn_call`, `wn_memory_size`, `wn_last_error`.
- `platform/platform.c` (~70 lines, C, compiled by cosmocc): `wasmtime_mmap_new/remap`, `munmap`, `mprotect`, `page_size`, `tls_get/set`, `init_traps` (sigaction), no memory images.
- `host/host.c`: the test host (a small WASI-p1 subset + the `send`/`recv` wire pair).
- Target: `x86_64-unknown-linux-gnu.json` / `aarch64-unknown-linux-gnu.json` derived at build time from rustc's own spec with `os = none` (so Wasmtime's `cfg(unix)` code paths and the std-only crates `rustix`, `memfd`, `libc` are not selected), `-Zbuild-std=core,alloc`, panic=abort, aarch64 additionally `+reserve-x28`, x86-64 `disable-redzone`. The spec file keeps the NAME of the real triple, because `target-lexicon`'s build script and the .cwasm compatibility check use it.
- `.cwasm` files come from the OFFICIAL Wasmtime v50 CLI: `wasmtime compile --target {x86_64,aarch64}-unknown-linux-gnu -W gc-support=n -W concurrency-support=n -W threads=n -W exceptions=n -W component-model=n -W shared-everything-threads=n -W function-references=n -O signals-based-traps={y,n}` and `--target pulley64`. The feature switches are needed because the runtime was built without the Cargo features for those proposals; each mismatch is reported precisely by `Module::deserialize` (found one by one: GC, concurrency, threads, exceptions, component_model; and Pulley needs the `pulley` Cargo feature).

## Sizes
- `libwn_embedding.a`: x86-64 2.35 MB, aarch64 2.24 MB (archives, before gc-sections).
- Linked halves: x86-64 0.96 MB, aarch64 0.80 MB. **The fat file (both architectures, runtime + host) is 1.93 MB**; with 15 .cwasm files (3 test guests x {sig x86-64, sig aarch64, nosig x86-64, nosig aarch64, pulley} + trap guest) embedded as a zip: 2.42 MB.
- For comparison, the earlier bundled form carried 4-5 official libraries of several MB each.

## Results
| target | native code, signals-based traps | native code, explicit checks | Pulley (interpreter, ONE .cwasm for every OS/arch) |
|---|---|---|---|
| Linux x86-64 | works | works | works |
| Linux arm64 | works | works (after the x28 fix below) | works |
| macOS arm64 | works | works (after the x28 fix) | works |
| Windows x64 | works, incl. all three trap kinds (after the Windows workaround below) | works, incl. all traps | works |
| Windows arm64 (x86-64 half, emulated) | kernels work (engine+load 11 ms, instantiate 4 ms under emulation); trap guest seen recovering in the last mode run | kernels work | kernels work |
All kernels print identical checksums on every runtime and mode. A trap in the middle of a call (out-of-bounds, divide by zero, `unreachable`) is reported as an error and the SAME instance keeps working afterwards (`ok -> 42` after each trap): verified explicitly on linux arm64, macOS arm64 and Windows x64 in all three modes (run 41034378094 for Windows, 41032456423 for the others).

Executable memory: `mmap` read-write, copy the code, `mprotect` read-execute works on macOS arm64 (macOS 26.6.2 runner) from a Cosmopolitan process without `MAP_JIT` (platform-probes run 41028100717: RW->RX OK, direct RWX refused, MAP_JIT RWX OK). That is how Wasmtime publishes code, and it works.

### Speed against the official Wasmtime on the same machine (interleaved, best of 3; speed relative to our static "sig" build, 1.00 = identical)
- linux arm64, run 41032456423: official CLI (JIT from .wasm) 0.99-1.00x on every kernel; official runtime on our .cwasm 1.00x on every kernel.
- linux x86-64: official runtime on our .cwasm 0.98-1.06x (the `interp` kernel is noisy on this runner: 216-363 ms between rounds of the same binary); official JIT 0.94-1.34x on `interp`, 1.00x elsewhere.
- macOS arm64: official CLI 0.91-1.09x, mostly 1.00x. (The official macOS runtime refuses our .cwasm because it was compiled for the linux-gnu triple: expected, and the reason one .cwasm works for all OSes in our runtime.)
=> The static build executes the same machine code at the same speed as the official runtime. Startup: engine+load 0.1-0.3 ms, instantiate 0.0-0.4 ms on Linux/macOS/Windows x64 (Windows arm64 under emulation: 11 ms / 4 ms).

### Cost of explicit bounds checks ("nosig": `signals-based-traps=n`, no guard pages, no signal handlers), relative to "sig"
| kernel | linux x64 | linux arm64 | macOS arm64 |
|---|---|---|---|
| matmul (scalar) | 0.61x | 0.64x | 0.55x |
| matmul (SIMD128) | 0.71x | 0.61x | 0.53x |
| triad (memory streaming, scalar guest) | 0.78x | 0.70x | 0.63x |
| vertex transform (SIMD128) | 0.61x | 0.75x | 0.69x |
| interp, sort, hash, nbody (both guests) | 0.92-1.09x | 0.82-0.97x | 0.84-1.00x |
So explicit checks cost nothing on branchy/integer code and up to ~1.6-1.9x time on dense array loops. (Wasmtime's own doc says "up to 2x".) Use signal handlers where they work.

### Pulley (interpreter) against native code, same .wasm (sig = 1.0, time ratios)
matmul scalar ~115x slower (946 vs 8.2 ms, linux x64), SIMD matmul ~95x, nbody ~40x, bytecode-interpreter loop ~14x, triad ~120x, hash ~10x, sort ~9x, vertex transform ~165x scalar and ~67x SIMD128 (26 vs 0.4 ms). Pulley is a fallback (locked-down platforms), not a performance option. One Pulley .cwasm is identical for all 5 targets.

## Problems found and their causes
1. `-Zbuild-std` with a plain `*-linux-gnu` target: `error[E0152] duplicate lang item in crate core` in `bitflags`: with `target_os = "linux"` the `runtime` feature pulls `rustix` (with `std`), `memfd`, `libc`. Fix: a target spec with `os = none`.
2. `target-lexicon` build script panicked on the spec file stem `nostd-x86_64`: name the spec file like the real triple.
3. aarch64, mode "nosig": segmentation fault right after the first host call. Cause: Cranelift treats **x28 as an ordinary callee-saved register** (cranelift/codegen/src/isa/aarch64/abi.rs: x19-x28 are callee-saves, only x18 and the optional pinned x21 are reserved), and Cosmopolitan keeps its **thread pointer in x28** (its `_Thread_local`, errno, stdio locks, malloc arena selection all go through it). While wasm runs, x28 holds anything; a host function called from wasm then runs C library code with a wrong thread pointer. Fix (measured: all aarch64 failures disappear): record x28 in `wn_call` before entering wasm, put it back at the start of every host-function callback (and in the signal handler of platform.c) and restore the wasm value afterwards; Wasmtime's `tls_get/set` use plain statics instead of `_Thread_local`. Consequence: one wasm thread per process until a lookup that does not use x28 is written (Rust side is built with x28 reserved so it never changes it).
4. Windows, signals-based traps, out-of-bounds access: Wasmtime panics `invalid fault`. Cause: Cosmopolitan's Windows exception-to-signal translation reports the **instruction address in `si_addr`** (measured: `signal 11 code 2 ip 0x6ffffff810ad ... si_addr 0x6ffffff810ad`), not the accessed address, so Wasmtime's check "the faulting address belongs to a linear memory of this store" fails. Workaround in `platform.c` (verified, run 41034378094): on Windows read `uc_mcontext.cr2`; it is 0 there too (trace: `si_addr == ip`, `cr2 0`), so the handler tells Wasmtime "address unknown" (`has_faulting_addr = false`). Wasmtime then skips only its extra check that a faulting address belongs to a linear memory; the trap itself is still recognised from the program counter via the trap table, and the out-of-bounds, divide-by-zero (SIGILL) and `unreachable` (SIGILL) cases all trap and recover. Cost: that extra security check is not available on Windows in signals mode; `nosig` mode does not have the problem. (A cleaner fix would be in Cosmopolitan: put `ExceptionInformation[1]` into `si_addr`.)
5. `.cwasm` produced for the `linux-gnu` triple is accepted by the runtime on every OS because the runtime's own triple (from the spec file name) is also `linux-gnu`; it is *not* accepted by the official macOS/Windows runtimes. This is the property that makes "one .cwasm per architecture" work.

## Not done / not claimed
- Multi-threaded wasm (x28 and TLS issue above), wasm threads proposal, WASI beyond the tiny subset in `host.c`, the component model, GC, async/fibers, stack switching.
- Wasmtime's `wasmtime-platform.h` also describes `custom-fiber`/`custom-sync` features; not enabled.
- Release-build hardening: the runtime and the CLI that produced the .cwasm must be the same Wasmtime version and configuration (the loader checks, and says what differs).

## Recommendation
- The static form is real: **one 1.9 MB file, no per-OS Wasmtime library, no extraction, same machine code and the same speed as the official Wasmtime on Linux, macOS and Windows (x86-64 and arm64)**, with precompiled `.cwasm` for the two architectures stored next to it. The price is a build pipeline: nightly Rust + `-Zbuild-std` + a derived target spec, the official CLI to precompile (same Wasmtime version and flags), and the platform layer.
- Use signals-based traps wherever signals work (all five targets here do, with the Windows workaround). Keep `nosig` as the portable fallback; budget up to ~1.6-1.9x time on dense array loops.
- Keep Pulley only as a fallback for platforms where executable memory is refused (it is 9-165x slower here).
- Not solved: more than one wasm thread (the x28/TLS issue), and shipping JIT-compiled (non-precompiled) modules, which needs Cranelift (std) and is exactly what the bundled-library form still provides.

## Runs
Workflow `wasmtime-nostd` (this repo). Runs: 41028475540 (first build attempts: duplicate lang item), 41029148368 (custom target builds), 41030588247-41031650625 (feature-by-feature cwasm compatibility), 41032456423 (x28 fix, trap guest, A/B against the official CLI on linux/mac), 41033120321 (Windows trace: `si_addr == ip`), 41034378094 (Windows workaround; all of the above green). platform-probes run 41028100717 (executable memory on macOS arm64).
