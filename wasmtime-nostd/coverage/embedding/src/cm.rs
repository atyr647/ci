//! Component model in the no_std build: load a precompiled component, and a self-test of the canonical ABI (strings, lists, records, results, a host import, a trap)
//! against a component written by hand (guest/cm.wat).
use crate::{fail, log, st};
use alloc::boxed::Box;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec;
use alloc::vec::Vec;
use wasmtime::component::{Component, Linker, Val};
use wasmtime::Store;

extern "C" {
    fn wn_out(msg: *const u8, len: usize);
}
pub(crate) fn out(s: &str) { unsafe { wn_out(s.as_ptr(), s.len()) } }

pub(crate) static mut COMP: Option<Component> = None;
static mut LOGS: Vec<String> = Vec::new();

#[no_mangle]
pub unsafe extern "C" fn wn_cm_load(bytes: *const u8, len: usize) -> i32 {
    let s = st();
    match Component::deserialize(&s.engine, core::slice::from_raw_parts(bytes, len)) { Ok(c) => { COMP = Some(c); 0 } Err(e) => fail(e) }
}

fn expect_string(v: &Val) -> Option<&str> { if let Val::String(s) = v { Some(s.as_str()) } else { None } }

/// Runs the canonical-ABI checks; prints PASS/FAIL lines and a SUMMARY. Returns 0 when everything passed.
#[no_mangle]
pub extern "C" fn wn_cm_selftest() -> i32 {
    #[allow(static_mut_refs)]
    let comp = match unsafe { COMP.as_ref() } { Some(c) => c, None => return fail("no component loaded") };
    let s = st();
    let mut linker: Linker<()> = Linker::new(&s.engine);
    if let Err(e) = linker.root().func_wrap("log", |_cx, (msg,): (String,)| { #[allow(static_mut_refs)] unsafe { LOGS.push(msg); } Ok(()) }) { return fail(e); }
    let mut store = Store::new(&s.engine, ());
    let inst = match linker.instantiate(&mut store, comp) { Ok(i) => i, Err(e) => return fail(e) };
    let (mut pass, mut failed) = (0, 0);
    let mut report = |name: &str, ok: bool, detail: String| { if ok { pass += 1; out(&format!("PASS {name}\n")); } else { failed += 1; out(&format!("FAIL {name} {detail}\n")); } };

    // dynamic values
    let f = inst.get_func(&mut store, "upper");
    match f {
        Some(f) => { let mut r = [Val::Bool(false)]; let e = f.call(&mut store, &[Val::String("hello, world".to_string())], &mut r); report("cm_string_roundtrip", e.is_ok() && expect_string(&r[0]) == Some("HELLO, WORLD"), format!("{e:?} {:?}", r)); }
        None => report("cm_string_roundtrip", false, "no export upper".to_string()),
    }
    if let Some(f) = inst.get_func(&mut store, "sum") {
        let xs: Vec<Val> = (1..=1000u32).map(Val::U32).chain([Val::U32(u32::MAX)]).collect();
        let mut r = [Val::Bool(false)]; let e = f.call(&mut store, &[Val::List(xs)], &mut r);
        report("cm_list_u32_sum", e.is_ok() && matches!(r[0], Val::U64(x) if x == 500500 + u32::MAX as u64), format!("{e:?} {:?}", r));
    } else { report("cm_list_u32_sum", false, "no export".to_string()); }
    if let Some(f) = inst.get_func(&mut store, "div") {
        let mut r = [Val::Bool(false)];
        let e1 = f.call(&mut store, &[Val::S32(84), Val::S32(2)], &mut r);
        report("cm_result_ok", e1.is_ok() && matches!(&r[0], Val::Result(Ok(Some(b))) if matches!(**b, Val::S32(42))), format!("{e1:?} {:?}", r));
        let e2 = f.call(&mut store, &[Val::S32(1), Val::S32(0)], &mut r);
        report("cm_result_err_string", e2.is_ok() && matches!(&r[0], Val::Result(Err(Some(b))) if matches!(&**b, Val::String(m) if m == "division by zero")), format!("{e2:?} {:?}", r));
    } else { report("cm_result", false, "no export".to_string()); }
    if let Some(f) = inst.get_func(&mut store, "area") {
        let mut r = [Val::Bool(false)];
        let e = f.call(&mut store, &[Val::Record(vec![("w".to_string(), Val::U32(6)), ("h".to_string(), Val::U32(7))])], &mut r);
        report("cm_record_param", e.is_ok() && matches!(r[0], Val::U32(42)), format!("{e:?} {:?}", r));
    } else { report("cm_record_param", false, "no export".to_string()); }
    if let Some(f) = inst.get_func(&mut store, "greet") {
        let e = f.call(&mut store, &[Val::String("component".to_string())], &mut []);
        #[allow(static_mut_refs)] let got = unsafe { LOGS.last().cloned() };
        report("cm_host_import_string", e.is_ok() && got.as_deref() == Some("hello, component"), format!("{e:?} {got:?}"));
    } else { report("cm_host_import_string", false, "no export".to_string()); }
    // typed API
    match inst.get_typed_func::<(String,), (String,)>(&mut store, "upper") {
        Ok(t) => { let r = t.call(&mut store, ("typed api".to_string(),)); report("cm_typed_func", matches!(&r, Ok((x,)) if x == "TYPED API"), format!("{r:?}")); }
        Err(e) => report("cm_typed_func", false, format!("{e:?}")),
    }
    // a trap ends the call with an error and must not take the process down
    if let Some(f) = inst.get_func(&mut store, "boom") {
        let e = f.call(&mut store, &[], &mut []);
        report("cm_trap_is_an_error", e.is_err(), "boom returned".to_string());
    }
    out(&format!("SUMMARY tests={} pass={} fail={}\n", pass + failed, pass, failed));
    let _ = (log, Box::new(0u8));
    if failed == 0 { 0 } else { -1 }
}
