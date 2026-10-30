//! Coverage build of the Wasmtime runtime-only no_std embedding: same shape as ../../embedding, plus optional features
//! (gc, async/fibers, component model, WASI preview 2 written for this build) and the test hooks the coverage host needs.
#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};
use core::ffi::{c_char, c_void, CStr};
use wasmtime::{Caller, Config, Engine, Extern, FuncType, Instance, Linker, Module, Result, Store, Val, ValType};

#[cfg(feature = "component")]
mod cm;
#[cfg(feature = "p2")]
mod p2;

// ---- allocator and panics: the C library of the host program -----------------------------------------------------------------------------------------------
extern "C" {
    fn malloc(n: usize) -> *mut u8;
    fn calloc(n: usize, m: usize) -> *mut u8;
    fn realloc(p: *mut u8, n: usize) -> *mut u8;
    fn free(p: *mut u8);
    fn posix_memalign(out: *mut *mut u8, align: usize, size: usize) -> i32;
    fn abort() -> !;
    pub(crate) fn wn_log(msg: *const u8, len: usize);
    fn wn_idle();
}

// x28 (arm64): Cosmopolitan's thread pointer; Cranelift code uses it as a general register, so any C library call made on the way out of wasm (libcalls such as memory.grow,
// allocation from the runtime, host functions) must see the host's value. The allocator and the platform layer therefore put it back around every call.
#[cfg(target_arch = "aarch64")]
#[no_mangle]
pub static mut wn_host_x28: usize = 0;
#[cfg(not(target_arch = "aarch64"))]
#[allow(dead_code)]
static mut wn_host_x28: usize = 0;
#[cfg(target_arch = "aarch64")]
#[inline(always)]
pub(crate) unsafe fn x28_get() -> usize { let v: usize; core::arch::asm!("mov {}, x28", out(reg) v, options(nomem, nostack, preserves_flags)); v }
#[cfg(target_arch = "aarch64")]
#[inline(always)]
pub(crate) unsafe fn x28_set(v: usize) { core::arch::asm!("mov x28, {}", in(reg) v, options(nomem, nostack, preserves_flags)); }
#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
pub(crate) unsafe fn x28_get() -> usize { 0 }
#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
pub(crate) unsafe fn x28_set(_v: usize) {}

/// Runs `f` with the host's thread pointer in place (a no-op except on arm64), then puts back what was there.
#[inline(always)]
pub(crate) fn with_host<R>(f: impl FnOnce() -> R) -> R {
    unsafe {
        let h = wn_host_x28;
        if h == 0 { return f(); }
        let theirs = x28_get(); x28_set(h);
        let r = f();
        x28_set(theirs);
        r
    }
}

struct CAlloc;
unsafe impl GlobalAlloc for CAlloc {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        with_host(|| if l.align() <= 16 { malloc(l.size()) } else { let mut p = core::ptr::null_mut(); if posix_memalign(&mut p, l.align(), l.size()) != 0 { core::ptr::null_mut() } else { p } })
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        if l.align() <= 16 { with_host(|| calloc(l.size(), 1)) } else { let p = self.alloc(l); if !p.is_null() { core::ptr::write_bytes(p, 0, l.size()); } p }
    }
    unsafe fn dealloc(&self, p: *mut u8, _l: Layout) { with_host(|| free(p)) }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        if l.align() <= 16 { with_host(|| realloc(p, n)) } else {
            let q = self.alloc(Layout::from_size_align_unchecked(n, l.align()));
            if !q.is_null() { core::ptr::copy_nonoverlapping(p, q, l.size().min(n)); self.dealloc(p, l); }
            q
        }
    }
}
#[global_allocator]
static ALLOC: CAlloc = CAlloc;

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    let s = format!("wasmtime-nostd panic: {info}\n");
    unsafe { wn_log(s.as_ptr(), s.len()); abort() }
}

// ---- host features: the .cwasm was compiled for the baseline of its target; verify the CPU has what it needs --------------------------------------------------
#[cfg(target_arch = "x86_64")]
fn detect(feature: &str) -> Option<bool> {
    use core::arch::x86_64::{__cpuid, __cpuid_count};
    let l1 = unsafe { __cpuid(1) };
    let max = unsafe { __cpuid(0) }.eax;
    let l7 = if max >= 7 { unsafe { __cpuid_count(7, 0) } } else { unsafe { __cpuid(0) } };
    let l81 = unsafe { __cpuid(0x8000_0001) };
    let bit = |v: u32, b: u32| v & (1 << b) != 0;
    let ymm = bit(l1.ecx, 27) && unsafe { core::arch::x86_64::_xgetbv(0) } & 6 == 6;
    Some(match feature {
        "sse3" => bit(l1.ecx, 0),
        "ssse3" => bit(l1.ecx, 9),
        "sse4.1" => bit(l1.ecx, 19),
        "sse4.2" => bit(l1.ecx, 20),
        "popcnt" => bit(l1.ecx, 23),
        "fma" => bit(l1.ecx, 12) && ymm,
        "avx" => bit(l1.ecx, 28) && ymm,
        "avx2" => bit(l7.ebx, 5) && ymm,
        "bmi1" => bit(l7.ebx, 3),
        "bmi2" => bit(l7.ebx, 8),
        "lzcnt" => bit(l81.ecx, 5),
        _ => return None,
    })
}
#[cfg(not(target_arch = "x86_64"))]
fn detect(_feature: &str) -> Option<bool> { None }

// ---- state -----------------------------------------------------------------------------------------------------------------------------------------------------
pub type WnCb = unsafe extern "C" fn(user: *mut c_void, mem: *mut u8, mem_len: usize, args: *const u64, results: *mut u64) -> i32;

pub(crate) struct State {
    pub(crate) engine: Engine,
    linker: Linker<()>,
    module: Option<Module>,
    store: Option<Store<()>>,
    instance: Option<Instance>,
    pub(crate) err: Vec<u8>,
    async_mode: bool,
    pending_polls: u64,
}
static mut STATE: Option<Box<State>> = None;

pub(crate) fn st() -> &'static mut State { #[allow(static_mut_refs)] unsafe { STATE.as_mut().expect("wn_init first") } }
pub(crate) fn fail(e: impl core::fmt::Debug) -> i32 { let s = st(); s.err = format!("{e:?}").into_bytes(); s.err.push(0); -1 }
pub(crate) fn log(s: &str) { unsafe { wn_log(s.as_ptr(), s.len()) } }

/// collector: 0 default (copying), 1 deferred reference counting, 2 null, 3 copying (only with the `gc` feature).
/// mode 0: native code, signals-based traps; 1: native code, explicit checks; 2: Pulley interpreter.
#[no_mangle]
pub extern "C" fn wn_init_ex(mode: i32, collector: i32) -> i32 {
    let mut cfg = Config::new();
    unsafe { cfg.detect_host_feature(detect); }
    match mode {
        1 => { cfg.signals_based_traps(false); }
        2 => { if let Err(e) = cfg.target("pulley64") { log(&format!("target pulley64: {e:?}\n")); return -1; } cfg.signals_based_traps(false); }
        _ => {}
    }
    #[cfg(feature = "gc")]
    match collector {
        1 => { cfg.collector(wasmtime::Collector::DeferredReferenceCounting); }
        2 => { cfg.collector(wasmtime::Collector::Null); }
        3 => { cfg.collector(wasmtime::Collector::Copying); }
        _ => {}
    }
    #[cfg(not(feature = "gc"))]
    let _ = collector;
    let engine = match Engine::new(&cfg) { Ok(e) => e, Err(e) => { log(&format!("Engine::new: {e:?}\n")); return -1; } };
    let linker = Linker::new(&engine);
    unsafe { STATE = Some(Box::new(State { engine, linker, module: None, store: None, instance: None, err: Vec::new(), async_mode: false, pending_polls: 0 })); }
    0
}
#[no_mangle]
pub extern "C" fn wn_init(mode: i32) -> i32 { wn_init_ex(mode, 0) }

#[no_mangle]
pub extern "C" fn wn_last_error() -> *const c_char { let s = st(); if s.err.is_empty() { b"\0".as_ptr() as *const c_char } else { s.err.as_ptr() as *const c_char } }

/// Which optional layers this library was built with (bit 0 gc, 1 async, 2 component, 3 p2).
#[no_mangle]
pub extern "C" fn wn_features() -> i32 {
    (cfg!(feature = "gc") as i32) | ((cfg!(feature = "async") as i32) << 1) | ((cfg!(feature = "component") as i32) << 2) | ((cfg!(feature = "p2") as i32) << 3)
}

fn valtype(c: u8) -> Option<ValType> { Some(match c { b'i' => ValType::I32, b'l' => ValType::I64, b'f' => ValType::F32, b'd' => ValType::F64, _ => return None }) }

fn parse_sig(sg: &[u8]) -> Option<(Vec<ValType>, Vec<ValType>)> {
    let mut params = Vec::new(); let mut results = Vec::new(); let mut after = false;
    for &c in sg { if c == b'>' { after = true; continue; } match valtype(c) { Some(t) => if after { results.push(t) } else { params.push(t) }, None => return None } }
    Some((params, results))
}

/// Host function `module.name` with signature `sig` ("ii>i": i32 i32 -> i32; letters i l f d). The callback receives raw 64-bit slots.
#[no_mangle]
pub unsafe extern "C" fn wn_define(module: *const c_char, name: *const c_char, sig: *const c_char, cb: WnCb, user: *mut c_void) -> i32 {
    let (m, n, sg) = (CStr::from_ptr(module).to_str().unwrap_or(""), CStr::from_ptr(name).to_str().unwrap_or(""), CStr::from_ptr(sig).to_bytes());
    let (params, results) = match parse_sig(sg) { Some(x) => x, None => return fail("bad signature") };
    let s = st();
    let ty = FuncType::new(&s.engine, params, results.clone());
    let user = user as usize;
    let r = s.linker.func_new(m, n, ty, move |mut caller: Caller<'_, ()>, p: &[Val], out: &mut [Val]| -> Result<()> {
        let theirs = unsafe { let t = x28_get(); x28_set(wn_host_x28); t };
        let (mem, len) = match caller.get_export("memory") { Some(Extern::Memory(mm)) => { let d = mm.data_mut(&mut caller); (d.as_mut_ptr(), d.len()) } _ => (core::ptr::null_mut(), 0) };
        let mut a = [0u64; 16];
        for (i, v) in p.iter().enumerate().take(16) { a[i] = match v { Val::I32(x) => *x as u32 as u64, Val::I64(x) => *x as u64, Val::F32(x) => *x as u64, Val::F64(x) => *x, _ => 0 }; }
        let mut r = [0u64; 4];
        let rc = unsafe { cb(user as *mut c_void, mem, len, a.as_ptr(), r.as_mut_ptr()) };
        unsafe { x28_set(theirs); }
        if rc != 0 { wasmtime::bail!("host function returned {rc}"); }
        for (i, t) in results.iter().enumerate() {
            out[i] = match t { ValType::I32 => Val::I32(r[i] as i32), ValType::I64 => Val::I64(r[i] as i64), ValType::F32 => Val::F32(r[i] as u32), _ => Val::F64(r[i]) };
        }
        Ok(())
    });
    match r { Ok(_) => 0, Err(e) => fail(e) }
}

#[no_mangle]
pub unsafe extern "C" fn wn_load(bytes: *const u8, len: usize) -> i32 {
    let s = st();
    match Module::deserialize(&s.engine, core::slice::from_raw_parts(bytes, len)) { Ok(m) => { s.module = Some(m); 0 } Err(e) => fail(e) }
}

/// Minimal executor: polls to completion; a future that returns Pending (a fiber that suspended) is polled again after a short idle. Counts the Pending polls.
pub(crate) fn block_on<F: core::future::Future>(f: F, pending: &mut u64) -> F::Output {
    use core::task::{Context, Poll, Waker};
    let mut f = core::pin::pin!(f);
    let mut cx = Context::from_waker(Waker::noop());
    loop {
        match f.as_mut().poll(&mut cx) {
            Poll::Ready(v) => return v,
            Poll::Pending => { *pending += 1; if *pending % 64 == 0 { with_host(|| unsafe { wn_idle() }); } }
        }
    }
}

#[no_mangle]
pub extern "C" fn wn_set_async(on: i32) { st().async_mode = on != 0; }
/// Number of times an async call suspended (returned Pending to the executor) since wn_init.
#[no_mangle]
pub extern "C" fn wn_pending_polls() -> u64 { st().pending_polls }

#[no_mangle]
pub extern "C" fn wn_instantiate() -> i32 {
    let s = st();
    let module = match &s.module { Some(m) => m.clone(), None => return fail("no module") };
    let mut store = Store::new(&s.engine, ());
    #[cfg(feature = "async")]
    if s.async_mode {
        let mut p = 0u64;
        let r = block_on(s.linker.instantiate_async(&mut store, &module), &mut p);
        s.pending_polls += p;
        return match r { Ok(i) => { s.instance = Some(i); s.store = Some(store); 0 } Err(e) => fail(e) };
    }
    match s.linker.instantiate(&mut store, &module) { Ok(i) => { s.instance = Some(i); s.store = Some(store); 0 } Err(e) => fail(e) }
}

/// Async host function `module.name(i32 n)`: suspends the calling fiber `n` times (Pending to the executor) before returning. Needs the `async` feature.
#[cfg(feature = "async")]
#[no_mangle]
pub unsafe extern "C" fn wn_define_yield(module: *const c_char, name: *const c_char) -> i32 {
    let (m, n) = (CStr::from_ptr(module).to_str().unwrap_or(""), CStr::from_ptr(name).to_str().unwrap_or(""));
    let s = st();
    let ty = FuncType::new(&s.engine, [ValType::I32], []);
    struct YieldN(u32);
    impl core::future::Future for YieldN {
        type Output = ();
        fn poll(mut self: core::pin::Pin<&mut Self>, cx: &mut core::task::Context<'_>) -> core::task::Poll<()> {
            if self.0 == 0 { core::task::Poll::Ready(()) } else { self.0 -= 1; cx.waker().wake_by_ref(); core::task::Poll::Pending }
        }
    }
    let r = s.linker.func_new_async(m, n, ty, |_c, p, _o| { let k = match p.first() { Some(Val::I32(x)) => *x as u32, _ => 0 }; Box::new(async move { YieldN(k).await; Ok(()) }) });
    match r { Ok(_) => 0, Err(e) => fail(e) }
}
#[cfg(not(feature = "async"))]
#[no_mangle]
pub unsafe extern "C" fn wn_define_yield(_module: *const c_char, _name: *const c_char) -> i32 { fail("built without the async feature") }

/// Calls export `name` with raw 64-bit argument slots; results likewise. Returns 0, or -1 with wn_last_error() (a trap, for example).
#[no_mangle]
pub unsafe extern "C" fn wn_call(name: *const c_char, args: *const u64, nargs: usize, res: *mut u64, nres: usize) -> i32 {
    let s = st();
    let (inst, store) = match (&s.instance, &mut s.store) { (Some(i), Some(st)) => (*i, st), _ => return fail("not instantiated") };
    let nm = CStr::from_ptr(name).to_str().unwrap_or("");
    let f = match inst.get_func(&mut *store, nm) { Some(f) => f, None => return fail(format!("no export {nm}")) };
    let ty = f.ty(&*store);
    let mut a: Vec<Val> = Vec::new();
    for (i, t) in ty.params().enumerate() {
        if i >= nargs { return fail("too few arguments"); }
        let v = *args.add(i);
        a.push(match t { ValType::I32 => Val::I32(v as i32), ValType::I64 => Val::I64(v as i64), ValType::F32 => Val::F32(v as u32), _ => Val::F64(v) });
    }
    let mut out: Vec<Val> = ty.results().map(|_| Val::I32(0)).collect();
    let mine = x28_get(); wn_host_x28 = mine;
    #[cfg(feature = "async")]
    let r = if s.async_mode { let mut p = 0u64; let r = block_on(f.call_async(&mut *store, &a, &mut out), &mut p); s.pending_polls += p; r } else { f.call(&mut *store, &a, &mut out) };
    #[cfg(not(feature = "async"))]
    let r = f.call(&mut *store, &a, &mut out);
    x28_set(mine);
    if let Err(e) = r { return fail(e); }
    for (i, v) in out.iter().enumerate().take(nres) { *res.add(i) = match v { Val::I32(x) => *x as u32 as u64, Val::I64(x) => *x as u64, Val::F32(x) => *x as u64, Val::F64(x) => *x, _ => 0 }; }
    0
}

/// Names of the function exports, newline separated, written to `buf` (at most `cap` bytes); returns the length needed.
#[no_mangle]
pub unsafe extern "C" fn wn_list_exports(buf: *mut u8, cap: usize) -> usize {
    let s = st();
    let (inst, store) = match (&s.instance, &mut s.store) { (Some(i), Some(st)) => (*i, st), _ => return 0 };
    let mut names = String::new();
    for e in inst.exports(&mut *store) { let n = e.name().to_string(); if let Extern::Func(_) = e.into_extern() { names.push_str(&n); names.push('\n'); } }
    let n = names.len().min(cap); core::ptr::copy_nonoverlapping(names.as_ptr(), buf, n);
    names.len()
}

/// Size of the linear memory of the instance named "memory" (0 when none).
#[no_mangle]
pub extern "C" fn wn_memory_size() -> usize {
    let s = st();
    match (&s.instance, &mut s.store) { (Some(i), Some(store)) => match i.get_memory(&mut *store, "memory") { Some(m) => m.data_size(&*store), None => 0 }, _ => 0 }
}

// ---- asyncify (stackless "coroutines" made by wasm-opt --asyncify): the host drives unwind / rewind ----------------------------------------------------------------
pub type AsyncifyCb = unsafe extern "C" fn(user: *mut c_void, request: i32) -> i32;
struct Asy { data: u32, request: i32, result: i32, cb: Option<AsyncifyCb>, user: usize, unwinds: u64 }
static mut ASY: Asy = Asy { data: 0, request: 0, result: 0, cb: None, user: 0, unwinds: 0 };

/// Defines `module.name(i32 request) -> i32` as an asyncify import: the first time it is called it unwinds the whole wasm stack to the host; when the host rewinds, it returns the result.
#[no_mangle]
pub unsafe extern "C" fn wn_define_asyncify(module: *const c_char, name: *const c_char, cb: AsyncifyCb, user: *mut c_void) -> i32 {
    let (m, n) = (CStr::from_ptr(module).to_str().unwrap_or(""), CStr::from_ptr(name).to_str().unwrap_or(""));
    #[allow(static_mut_refs)] { ASY.cb = Some(cb); ASY.user = user as usize; }
    let s = st();
    let ty = FuncType::new(&s.engine, [ValType::I32], [ValType::I32]);
    let r = s.linker.func_new(m, n, ty, |mut caller: Caller<'_, ()>, p: &[Val], out: &mut [Val]| -> Result<()> {
        let call = |caller: &mut Caller<'_, ()>, name: &str, args: &[Val], nres: usize| -> Result<Vec<Val>> {
            let f = match caller.get_export(name) { Some(Extern::Func(f)) => f, _ => wasmtime::bail!("guest lacks {name}") };
            let mut o: Vec<Val> = (0..nres).map(|_| Val::I32(0)).collect(); f.call(&mut *caller, args, &mut o)?; Ok(o)
        };
        #[allow(static_mut_refs)]
        let asy = unsafe { &mut ASY };
        let state = match call(&mut caller, "asyncify_get_state", &[], 1)?[0] { Val::I32(x) => x, _ => 0 };
        if state == 2 { call(&mut caller, "asyncify_stop_rewind", &[], 0)?; out[0] = Val::I32(asy.result); }
        else { asy.request = match p[0] { Val::I32(x) => x, _ => 0 }; asy.unwinds += 1; call(&mut caller, "asyncify_start_unwind", &[Val::I32(asy.data as i32)], 0)?; out[0] = Val::I32(0); }
        Ok(())
    });
    match r { Ok(_) => 0, Err(e) => fail(e) }
}

/// Drives export `entry` (no arguments, one i32 result) under the asyncify protocol; `data` is the guest address of the asyncify data area (cur, end, then the saved stack),
/// `size` its total size. Returns 0 and the final result in `*res`; `*unwinds` receives how many times the stack was unwound.
#[no_mangle]
pub unsafe extern "C" fn wn_asyncify_run(entry: *const c_char, data: u32, size: u32, res: *mut i32, unwinds: *mut u64) -> i32 {
    let s = st();
    let (inst, store) = match (&s.instance, &mut s.store) { (Some(i), Some(st)) => (*i, st), _ => return fail("not instantiated") };
    let mem = match inst.get_memory(&mut *store, "memory") { Some(m) => m, None => return fail("no memory") };
    { let d = mem.data_mut(&mut *store); let o = data as usize; d[o..o + 4].copy_from_slice(&(data + 8).to_le_bytes()); d[o + 4..o + 8].copy_from_slice(&(data + size).to_le_bytes()); }
    #[allow(static_mut_refs)] { ASY.data = data; ASY.unwinds = 0; }
    let nm = CStr::from_ptr(entry).to_str().unwrap_or("");
    let f = match inst.get_func(&mut *store, nm) { Some(f) => f, None => return fail(format!("no export {nm}")) };
    let g = |store: &mut Store<()>, name: &str, args: &[Val]| -> Result<()> { let f = match inst.get_func(&mut *store, name) { Some(f) => f, None => wasmtime::bail!("guest lacks {name}") }; f.call(&mut *store, args, &mut []) };
    let state_fn = match inst.get_func(&mut *store, "asyncify_get_state") { Some(f) => f, None => return fail("guest lacks asyncify_get_state") };
    let mine = x28_get(); wn_host_x28 = mine;
    let mut out = [Val::I32(0)];
    loop {
        let r = f.call(&mut *store, &[], &mut out);
        if let Err(e) = r { x28_set(mine); return fail(e); }
        let mut stv = [Val::I32(0)]; if let Err(e) = state_fn.call(&mut *store, &[], &mut stv) { return fail(e); }
        if let Val::I32(1) = stv[0] {
            if let Err(e) = g(store, "asyncify_stop_unwind", &[]) { return fail(e); }
            #[allow(static_mut_refs)]
            { let a = &mut ASY; a.result = match a.cb { Some(cb) => cb(a.user as *mut c_void, a.request), None => a.request }; }
            if let Err(e) = g(store, "asyncify_start_rewind", &[Val::I32(data as i32)]) { return fail(e); }
            continue;
        }
        break;
    }
    x28_set(mine);
    #[allow(static_mut_refs)] { *unwinds = ASY.unwinds; }
    *res = match out[0] { Val::I32(x) => x, _ => 0 };
    0
}
