//! Wasmtime (runtime only, no_std, custom platform) behind a tiny C API.
//! The embedder (host/host.c, compiled by Cosmopolitan) defines host functions as C callbacks, hands over a precompiled .cwasm, instantiates and calls exports.
#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};
use core::ffi::{c_char, c_void, CStr};
use wasmtime::{Caller, Config, Engine, Extern, FuncType, Instance, Linker, Module, Result, Store, Val, ValType};

// ---- allocator and panics: the C library of the host program --------------------------------------------------------------------------------------------
extern "C" {
    fn malloc(n: usize) -> *mut u8;
    fn calloc(n: usize, m: usize) -> *mut u8;
    fn realloc(p: *mut u8, n: usize) -> *mut u8;
    fn free(p: *mut u8);
    fn posix_memalign(out: *mut *mut u8, align: usize, size: usize) -> i32;
    fn abort() -> !;
    fn wn_log(msg: *const u8, len: usize);
}
struct CAlloc;
unsafe impl GlobalAlloc for CAlloc {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        if l.align() <= 16 { malloc(l.size()) } else { let mut p = core::ptr::null_mut(); if posix_memalign(&mut p, l.align(), l.size()) != 0 { core::ptr::null_mut() } else { p } }
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        if l.align() <= 16 { calloc(l.size(), 1) } else { let p = self.alloc(l); if !p.is_null() { core::ptr::write_bytes(p, 0, l.size()); } p }
    }
    unsafe fn dealloc(&self, p: *mut u8, _l: Layout) { free(p) }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        if l.align() <= 16 { realloc(p, n) } else {
            let q = self.alloc(Layout::from_size_align_unchecked(n, l.align()));
            if !q.is_null() { core::ptr::copy_nonoverlapping(p, q, l.size().min(n)); free(p); }
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

// ---- host features: the .cwasm was compiled for the baseline of its target; verify the CPU has what it needs ---------------------------------------------------
#[cfg(target_arch = "x86_64")]
fn detect(feature: &str) -> Option<bool> {
    use core::arch::x86_64::{__cpuid, __cpuid_count};
    let l1 = unsafe { __cpuid(1) };
    let max = unsafe { __cpuid(0) }.eax;
    let l7 = if max >= 7 { unsafe { __cpuid_count(7, 0) } } else { unsafe { __cpuid(0) } };
    let l81 = unsafe { __cpuid(0x8000_0001) };
    let bit = |v: u32, b: u32| v & (1 << b) != 0;
    // AVX needs OS support for the YMM state too: XGETBV (OSXSAVE is ecx bit 27 of leaf 1)
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

// ---- x28 (arm64): Cosmopolitan's thread pointer. Cranelift treats x28 as an ordinary callee-saved register, so while wasm runs it holds anything. The host value is
// recorded when the host enters wasm and put back while a host function runs (and in the signal handler of platform.c) ----------------------------------------------
#[cfg(target_arch = "aarch64")]
#[no_mangle]
pub static mut wn_host_x28: usize = 0;
#[cfg(target_arch = "aarch64")]
#[inline(always)]
unsafe fn x28_get() -> usize { let v: usize; core::arch::asm!("mov {}, x28", out(reg) v, options(nomem, nostack, preserves_flags)); v }
#[cfg(target_arch = "aarch64")]
#[inline(always)]
unsafe fn x28_set(v: usize) { core::arch::asm!("mov x28, {}", in(reg) v, options(nomem, nostack, preserves_flags)); }
#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
unsafe fn x28_get() -> usize { 0 }
#[cfg(not(target_arch = "aarch64"))]
#[inline(always)]
unsafe fn x28_set(_v: usize) {}
#[cfg(not(target_arch = "aarch64"))]
static mut wn_host_x28: usize = 0;

// ---- state ---------------------------------------------------------------------------------------------------------------------------------------------------
pub type WnCb = unsafe extern "C" fn(user: *mut c_void, mem: *mut u8, mem_len: usize, args: *const u64, results: *mut u64) -> i32;

struct State { engine: Engine, linker: Linker<()>, module: Option<Module>, store: Option<Store<()>>, instance: Option<Instance>, err: Vec<u8> }
static mut STATE: Option<Box<State>> = None;

fn st() -> &'static mut State { #[allow(static_mut_refs)] unsafe { STATE.as_mut().expect("wn_init first") } }
fn fail(e: impl core::fmt::Debug) -> i32 { let s = st(); s.err = format!("{e:?}").into_bytes(); s.err.push(0); -1 }

/// mode 0: native code, signals-based traps (guard pages); 1: native code, explicit checks (no signal handlers); 2: Pulley interpreter (portable bytecode).
#[no_mangle]
pub extern "C" fn wn_init(mode: i32) -> i32 {
    let mut cfg = Config::new();
    unsafe { cfg.detect_host_feature(detect); }
    match mode {
        1 => { cfg.signals_based_traps(false); }
        2 => { if let Err(e) = cfg.target("pulley64") { let s = format!("target pulley64: {e:?}\n"); unsafe { wn_log(s.as_ptr(), s.len()); } return -1; } cfg.signals_based_traps(false); }
        _ => {}
    }
    let engine = match Engine::new(&cfg) { Ok(e) => e, Err(e) => { let s = format!("Engine::new: {e:?}\n"); unsafe { wn_log(s.as_ptr(), s.len()); } return -1; } };
    let linker = Linker::new(&engine);
    unsafe { STATE = Some(Box::new(State { engine, linker, module: None, store: None, instance: None, err: Vec::new() })); }
    0
}

#[no_mangle]
pub extern "C" fn wn_last_error() -> *const c_char { let s = st(); if s.err.is_empty() { b"\0".as_ptr() as *const c_char } else { s.err.as_ptr() as *const c_char } }

fn valtype(c: u8) -> Option<ValType> { Some(match c { b'i' => ValType::I32, b'l' => ValType::I64, b'f' => ValType::F32, b'd' => ValType::F64, _ => return None }) }

/// Host function `module.name` with signature `sig` ("ii>i": i32 i32 -> i32; letters i l f d). The callback receives raw 64-bit slots.
#[no_mangle]
pub unsafe extern "C" fn wn_define(module: *const c_char, name: *const c_char, sig: *const c_char, cb: WnCb, user: *mut c_void) -> i32 {
    let (m, n, sg) = (CStr::from_ptr(module).to_str().unwrap_or(""), CStr::from_ptr(name).to_str().unwrap_or(""), CStr::from_ptr(sig).to_bytes());
    let mut params = Vec::new(); let mut results = Vec::new(); let mut after = false;
    for &c in sg { if c == b'>' { after = true; continue; } match valtype(c) { Some(t) => if after { results.push(t) } else { params.push(t) }, None => return fail("bad signature") } }
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

#[no_mangle]
pub extern "C" fn wn_instantiate() -> i32 {
    let s = st();
    let module = match &s.module { Some(m) => m.clone(), None => return fail("no module") };
    let mut store = Store::new(&s.engine, ());
    match s.linker.instantiate(&mut store, &module) { Ok(i) => { s.instance = Some(i); s.store = Some(store); 0 } Err(e) => fail(e) }
}

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
    let r = f.call(&mut *store, &a, &mut out);
    x28_set(mine);
    if let Err(e) = r { return fail(e); }
    for (i, v) in out.iter().enumerate().take(nres) { *res.add(i) = match v { Val::I32(x) => *x as u32 as u64, Val::I64(x) => *x as u64, Val::F32(x) => *x as u64, Val::F64(x) => *x, _ => 0 }; }
    0
}

/// Size of the linear memory of the instance named "memory" (0 when none).
#[no_mangle]
pub extern "C" fn wn_memory_size() -> usize {
    let s = st();
    match (&s.instance, &mut s.store) { (Some(i), Some(store)) => match i.get_memory(&mut *store, "memory") { Some(m) => m.data_size(&*store), None => 0 }, _ => 0 }
}
