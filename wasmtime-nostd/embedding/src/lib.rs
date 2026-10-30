//! Wasmtime (runtime only, no_std, custom platform) behind a tiny C API.
//! The embedder (host/host.c, compiled by Cosmopolitan) defines host functions as C callbacks, hands over a precompiled .cwasm, instantiates and calls exports.
//! Many OS threads: one `WnEngine` (engine + linker + module [+ shared memory]) can be used by any number of threads; every thread makes its own `WnInst` (store + instance).
#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;
use core::alloc::{GlobalAlloc, Layout};
use core::ffi::{c_char, c_void, CStr};
use wasmtime::{Caller, Config, Engine, Extern, ExternType, FuncType, Instance, Linker, Module, Result, SharedMemory, Store, Trap, Val, ValType};

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

// ---- x28 (arm64) -------------------------------------------------------------------------------------------------------------------------------------------
// Cosmopolitan keeps its thread pointer in x28 on arm64. Stock Cranelift treats x28 as an ordinary callee-saved register, so wasm code compiled by an unpatched compiler clobbers it.
// The real fix is in the compiler (patches/cranelift-0.137-aarch64-reserve-x28.patch: x28 is never allocated), and then nothing is needed here.
// `wn_x28_save` = 1 switches on the earlier workaround (one global slot, kept ONLY to measure it against the compiler fix): x28 is recorded in wn_call and put back inside host callbacks and the signal handler.
#[no_mangle]
pub static mut wn_host_x28: usize = 0;
#[no_mangle]
pub static mut wn_x28_save: u8 = 0;
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

// ---- objects -------------------------------------------------------------------------------------------------------------------------------------------------
/// Raw callback: `inst` is the calling instance (opaque; only wn_inst_engine/wn_inst_user/wn_inst_set_user may be used on it from inside the callback), `mem`/`mem_len` its linear memory.
pub type WnCb = unsafe extern "C" fn(user: *mut c_void, inst: *mut Inst, mem: *mut u8, mem_len: usize, args: *const u64, results: *mut u64) -> i32;

/// Store data: a back pointer to the owning `Inst` (as an integer so the type is Send) and the shared memory, if the module imports one.
struct Data { inst: usize, shared: Option<SharedMemory> }

pub struct Eng { engine: Engine, linker: Linker<Data>, module: Option<Module>, shared: Option<SharedMemory>, err: Vec<u8> }
pub struct Inst { eng: *const Eng, store: Store<Data>, instance: Option<Instance>, err: Vec<u8>, user: *mut c_void }

fn eng_fail(e: &mut Eng, m: impl core::fmt::Debug) -> i32 { e.err = format!("{m:?}").into_bytes(); e.err.push(0); -1 }
fn inst_fail(i: &mut Inst, e: &wasmtime::Error) -> i32 {
    // the trap code first (stable names such as MemoryOutOfBounds, StackOverflow), then the full chain (includes "memory fault at wasm address 0x... in linear memory of size 0x..." when the fault address is known)
    let s = match e.downcast_ref::<Trap>() { Some(t) => format!("trap={t:?} :: {e:?}"), None => format!("{e:?}") };
    i.err = s.into_bytes(); i.err.push(0); -1
}
fn inst_fail_str(i: &mut Inst, m: &str) -> i32 { i.err = m.as_bytes().to_vec(); i.err.push(0); -1 }

/// mode 0: native code, signals-based traps (guard pages); 1: native code, explicit checks (no signal handlers); 2: Pulley interpreter (portable bytecode).
/// flag 0x10: wasm threads proposal on (shared memory, atomics, wait/notify); the .cwasm must have been compiled with `-W threads=y`.
#[no_mangle]
pub extern "C" fn wn_engine_new(mode: i32) -> *mut Eng {
    let mut cfg = Config::new();
    unsafe { cfg.detect_host_feature(detect); }
    if mode & 0x10 != 0 { cfg.wasm_threads(true); cfg.shared_memory(true); } else { cfg.wasm_threads(false); }
    match mode & 0xf {
        1 => { cfg.signals_based_traps(false); }
        2 => { if let Err(e) = cfg.target("pulley64") { let s = format!("target pulley64: {e:?}\n"); unsafe { wn_log(s.as_ptr(), s.len()); } return core::ptr::null_mut(); } cfg.signals_based_traps(false); }
        _ => {}
    }
    let engine = match Engine::new(&cfg) { Ok(e) => e, Err(e) => { let s = format!("Engine::new: {e:?}\n"); unsafe { wn_log(s.as_ptr(), s.len()); } return core::ptr::null_mut(); } };
    let linker = Linker::new(&engine);
    Box::into_raw(Box::new(Eng { engine, linker, module: None, shared: None, err: Vec::new() }))
}

#[no_mangle]
pub unsafe extern "C" fn wn_engine_free(e: *mut Eng) { if !e.is_null() { drop(Box::from_raw(e)); } }

#[no_mangle]
pub unsafe extern "C" fn wn_engine_error(e: *const Eng) -> *const c_char { let e = &*e; if e.err.is_empty() { b"\0".as_ptr() as *const c_char } else { e.err.as_ptr() as *const c_char } }

fn valtype(c: u8) -> Option<ValType> { Some(match c { b'i' => ValType::I32, b'l' => ValType::I64, b'f' => ValType::F32, b'd' => ValType::F64, _ => return None }) }

unsafe fn mem_of(c: &mut Caller<'_, Data>) -> (*mut u8, usize) {
    match c.get_export("memory") {
        Some(Extern::Memory(m)) => { let d = m.data_mut(&mut *c); (d.as_mut_ptr(), d.len()) }
        Some(Extern::SharedMemory(sm)) => { let d = sm.data(); (d.as_ptr() as *mut u8, d.len()) }
        _ => match &c.data().shared { Some(sm) => { let d = sm.data(); (d.as_ptr() as *mut u8, d.len()) } None => (core::ptr::null_mut(), 0) },
    }
}

/// Host function `module.name` with signature `sig` ("ii>i": i32 i32 -> i32; letters i l f d). The callback receives raw 64-bit slots. Call before wn_engine_load, from one thread.
#[no_mangle]
pub unsafe extern "C" fn wn_engine_define(e: *mut Eng, module: *const c_char, name: *const c_char, sig: *const c_char, cb: WnCb, user: *mut c_void) -> i32 {
    let s = &mut *e;
    let (m, n, sg) = (CStr::from_ptr(module).to_str().unwrap_or(""), CStr::from_ptr(name).to_str().unwrap_or(""), CStr::from_ptr(sig).to_bytes());
    let mut params = Vec::new(); let mut results = Vec::new(); let mut after = false;
    for &c in sg { if c == b'>' { after = true; continue; } match valtype(c) { Some(t) => if after { results.push(t) } else { params.push(t) }, None => return eng_fail(s, "bad signature") } }
    let ty = FuncType::new(&s.engine, params, results.clone());
    let user = user as usize;
    let r = s.linker.func_new(m, n, ty, move |mut caller: Caller<'_, Data>, p: &[Val], out: &mut [Val]| -> Result<()> {
        let inst = caller.data().inst as *mut Inst;
        let theirs = unsafe { if wn_x28_save != 0 { let t = x28_get(); x28_set(wn_host_x28); t } else { 0 } };
        let (mem, len) = unsafe { mem_of(&mut caller) };
        let mut a = [0u64; 16];
        for (i, v) in p.iter().enumerate().take(16) { a[i] = match v { Val::I32(x) => *x as u32 as u64, Val::I64(x) => *x as u64, Val::F32(x) => *x as u64, Val::F64(x) => *x, _ => 0 }; }
        let mut r = [0u64; 4];
        let rc = unsafe { cb(user as *mut c_void, inst, mem, len, a.as_ptr(), r.as_mut_ptr()) };
        unsafe { if wn_x28_save != 0 { x28_set(theirs); } }
        if rc != 0 { wasmtime::bail!("host function returned {rc}"); }
        for (i, t) in results.iter().enumerate() {
            out[i] = match t { ValType::I32 => Val::I32(r[i] as i32), ValType::I64 => Val::I64(r[i] as i64), ValType::F32 => Val::F32(r[i] as u32), _ => Val::F64(r[i]) };
        }
        Ok(())
    });
    match r { Ok(_) => 0, Err(e2) => eng_fail(s, e2) }
}

/// Loads the precompiled module. If it imports a shared memory (wasm threads), one SharedMemory of that type is created and defined as that import for every instance.
#[no_mangle]
pub unsafe extern "C" fn wn_engine_load(e: *mut Eng, bytes: *const u8, len: usize) -> i32 {
    let s = &mut *e;
    let module = match Module::deserialize(&s.engine, core::slice::from_raw_parts(bytes, len)) { Ok(m) => m, Err(er) => return eng_fail(s, er) };
    let mut shared_import: Option<(alloc::string::String, alloc::string::String, wasmtime::MemoryType)> = None;
    for imp in module.imports() { if let ExternType::Memory(mt) = imp.ty() { if mt.is_shared() { shared_import = Some((imp.module().into(), imp.name().into(), mt)); } } }
    if let Some((m, n, mt)) = shared_import {
        let sm = match SharedMemory::new(&s.engine, mt) { Ok(x) => x, Err(er) => return eng_fail(s, er) };
        let tmp = Store::new(&s.engine, Data { inst: 0, shared: None });
        if let Err(er) = s.linker.define(&tmp, &m, &n, sm.clone()) { return eng_fail(s, er); }
        s.shared = Some(sm);
    }
    s.module = Some(module);
    0
}

fn write_err(buf: *mut c_char, n: usize, msg: &[u8]) { if buf.is_null() || n == 0 { return; } let k = msg.len().min(n - 1); unsafe { core::ptr::copy_nonoverlapping(msg.as_ptr(), buf as *mut u8, k); *buf.add(k) = 0; } }

/// New store + instance of the loaded module. Thread-safe: any thread may call it on a shared WnEngine. On failure returns NULL and writes the reason to `err`.
#[no_mangle]
pub unsafe extern "C" fn wn_inst_new(e: *const Eng, err: *mut c_char, errlen: usize) -> *mut Inst {
    let s = &*e;
    let module = match &s.module { Some(m) => m.clone(), None => { write_err(err, errlen, b"no module"); return core::ptr::null_mut(); } };
    let store = Store::new(&s.engine, Data { inst: 0, shared: s.shared.clone() });
    let mut b = Box::new(Inst { eng: e, store, instance: None, err: Vec::new(), user: core::ptr::null_mut() });
    let p = &*b as *const Inst as usize;
    b.store.data_mut().inst = p;
    match s.linker.instantiate(&mut b.store, &module) {
        Ok(i) => { b.instance = Some(i); Box::into_raw(b) }
        Err(er) => { let m = format!("{er:?}"); write_err(err, errlen, m.as_bytes()); core::ptr::null_mut() }
    }
}

#[no_mangle]
pub unsafe extern "C" fn wn_inst_free(i: *mut Inst) { if !i.is_null() { drop(Box::from_raw(i)); } }
#[no_mangle]
pub unsafe extern "C" fn wn_inst_error(i: *const Inst) -> *const c_char { let i = &*i; if i.err.is_empty() { b"\0".as_ptr() as *const c_char } else { i.err.as_ptr() as *const c_char } }
#[no_mangle]
pub unsafe extern "C" fn wn_inst_engine(i: *const Inst) -> *const Eng { (*i).eng }
#[no_mangle]
pub unsafe extern "C" fn wn_inst_user(i: *const Inst) -> *mut c_void { (*i).user }
#[no_mangle]
pub unsafe extern "C" fn wn_inst_set_user(i: *mut Inst, u: *mut c_void) { (*i).user = u; }

/// Calls export `name` with raw 64-bit argument slots; results likewise. Returns 0, or -1 with wn_inst_error() (a trap, for example).
#[no_mangle]
pub unsafe extern "C" fn wn_inst_call(i: *mut Inst, name: *const c_char, args: *const u64, nargs: usize, res: *mut u64, nres: usize) -> i32 {
    let s = &mut *i;
    let inst = match s.instance { Some(x) => x, None => return inst_fail_str(s, "not instantiated") };
    let nm = CStr::from_ptr(name).to_str().unwrap_or("");
    let f = match inst.get_func(&mut s.store, nm) { Some(f) => f, None => return inst_fail_str(s, &format!("no export {nm}")) };
    let ty = f.ty(&s.store);
    let mut a: Vec<Val> = Vec::new();
    for (k, t) in ty.params().enumerate() {
        if k >= nargs { return inst_fail_str(s, "too few arguments"); }
        let v = *args.add(k);
        a.push(match t { ValType::I32 => Val::I32(v as i32), ValType::I64 => Val::I64(v as i64), ValType::F32 => Val::F32(v as u32), _ => Val::F64(v) });
    }
    let mut out: Vec<Val> = ty.results().map(|_| Val::I32(0)).collect();
    let mine = if wn_x28_save != 0 { let m = x28_get(); wn_host_x28 = m; m } else { 0 };
    let r = f.call(&mut s.store, &a, &mut out);
    if wn_x28_save != 0 { x28_set(mine); }
    if let Err(e) = r { return inst_fail(s, &e); }
    for (k, v) in out.iter().enumerate().take(nres) { *res.add(k) = match v { Val::I32(x) => *x as u32 as u64, Val::I64(x) => *x as u64, Val::F32(x) => *x as u64, Val::F64(x) => *x, _ => 0 }; }
    0
}

/// Base address and size of the instance's linear memory (export "memory", or the shared memory); NULL/0 when none. Not for use from inside a host callback (use the pointer the callback receives).
#[no_mangle]
pub unsafe extern "C" fn wn_inst_memory(i: *mut Inst, len: *mut usize) -> *mut u8 {
    let s = &mut *i;
    let r = match (&s.instance, s.store.data().shared.clone()) {
        (_, Some(sm)) => { let d = sm.data(); (d.as_ptr() as *mut u8, d.len()) }
        (Some(inst), None) => match inst.get_memory(&mut s.store, "memory") { Some(m) => { let d = m.data_mut(&mut s.store); (d.as_mut_ptr(), d.len()) } None => (core::ptr::null_mut(), 0) },
        _ => (core::ptr::null_mut(), 0),
    };
    if !len.is_null() { *len = r.1; }
    r.0
}
