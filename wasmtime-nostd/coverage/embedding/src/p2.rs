//! WASI preview 2 host for the no_std build, written for this experiment: wasmtime-wasi needs std, so the interfaces a wasi-sdk `wasm32-wasip2` program uses are provided here,
//! on top of `wasmtime-wasi-io` (wasi:io: streams, poll, error - no_std already) and the C functions of host/wasi_p1.c (the same sandboxed file system as the preview 1 host).
//! Provided: wasi:cli (environment, exit, stdin/stdout/stderr, terminal-*), wasi:clocks (monotonic, wall), wasi:random (random, insecure, insecure-seed),
//! wasi:filesystem (types, preopens). Not provided: wasi:sockets, wasi:http (their imports are defined as functions that trap when called).
use crate::{block_on, fail, st, with_host, x28_get, x28_set, wn_host_x28};
use crate::cm::COMP;
use alloc::boxed::Box;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec;
use alloc::vec::Vec;
use core::ffi::{c_char, CStr};
use core::future::Future;
use core::pin::Pin;
use core::task::{Context, Poll};
use wasmtime::component::types::ComponentFunc;
use wasmtime::component::{Component, Linker, Resource, ResourceTable, ResourceType, Val};
use wasmtime::{bail, Engine, Result, Store, StoreContextMut};
use wasmtime_wasi_io::bytes::Bytes;
use wasmtime_wasi_io::poll::{subscribe, Pollable};
use wasmtime_wasi_io::streams::{DynInputStream, DynOutputStream, InputStream, OutputStream, StreamError, StreamResult};
use wasmtime_wasi_io::{add_to_linker_async, async_trait, IoView};

// ---- the C side ------------------------------------------------------------------------------------------------------------------------------------------------
extern "C" {
    fn wn_c_write(fd: i32, p: *const u8, n: usize) -> i64;
    fn wn_c_read(fd: i32, p: *mut u8, n: usize) -> i64;
    fn wn_c_poll(fd: i32, for_write: i32, timeout_ms: i32) -> i32;
    fn wn_c_clock_ns(id: i32) -> u64;
    fn wn_c_clock_res_ns(id: i32) -> u64;
    fn wn_c_sleep_ns(ns: u64);
    fn wn_c_random(p: *mut u8, n: usize) -> i32;
    fn wn_fs_count() -> i32;
    fn wn_fs_root_of(i: i32) -> i32;
    fn wn_fs_guest_name(i: i32) -> *const c_char;
    fn wn_fs_resolve(root: i32, base: *const c_char, path: *const c_char, follow: i32, out: *mut c_char, cap: usize) -> i32;
    fn wn_fs_stat(root: i32, rel: *const c_char, follow: i32, out: *mut u64) -> i32;
    fn wn_fs_fstat(fd: i32, out: *mut u64) -> i32;
    fn wn_fs_open(root: i32, rel: *const c_char, rd: i32, wr: i32, creat: i32, excl: i32, trunc: i32, append: i32) -> i32;
    fn wn_fs_dup(fd: i32) -> i32;
    fn wn_fs_close(fd: i32) -> i32;
    fn wn_fs_pread(fd: i32, p: *mut u8, n: usize, off: u64) -> i64;
    fn wn_fs_pwrite(fd: i32, p: *const u8, n: usize, off: u64) -> i64;
    fn wn_fs_mkdir(root: i32, rel: *const c_char) -> i32;
    fn wn_fs_rmdir(root: i32, rel: *const c_char) -> i32;
    fn wn_fs_unlink(root: i32, rel: *const c_char) -> i32;
    fn wn_fs_rename(r1: i32, rel1: *const c_char, r2: i32, rel2: *const c_char) -> i32;
    fn wn_fs_link(r1: i32, rel1: *const c_char, r2: i32, rel2: *const c_char) -> i32;
    fn wn_fs_symlink(target: *const c_char, root: i32, rel: *const c_char) -> i32;
    fn wn_fs_readlink(root: i32, rel: *const c_char, buf: *mut c_char, cap: usize) -> i32;
    fn wn_fs_ftruncate(fd: i32, size: u64) -> i32;
    fn wn_fs_fsync(fd: i32, data_only: i32) -> i32;
    fn wn_fs_utimens(root: i32, rel: *const c_char, follow: i32, am: i32, ans: u64, mm: i32, mns: u64) -> i32;
    fn wn_fs_futimens(fd: i32, am: i32, ans: u64, mm: i32, mns: u64) -> i32;
    fn wn_fs_readdir(root: i32, rel: *const c_char, out: *mut *mut u8, len: *mut usize) -> i32;
    fn wn_free(p: *mut u8);
}
fn cs(s: &str) -> Vec<u8> { let mut v = s.as_bytes().to_vec(); v.push(0); v }
fn hx<R>(f: impl FnOnce() -> R) -> R { with_host(f) }

/// preview 1 errno (as the C layer returns it, negated) -> wasi:filesystem error-code
fn ec(w: i32) -> &'static str {
    match w {
        2 => "access", 6 => "would-block", 7 => "already", 8 => "bad-descriptor", 10 => "busy", 16 => "deadlock", 19 => "quota", 20 => "exist", 22 => "file-too-large", 25 => "illegal-byte-sequence",
        26 => "in-progress", 27 => "interrupted", 28 => "invalid", 29 => "io", 31 => "is-directory", 32 => "loop", 34 => "too-many-links", 35 => "message-size", 37 => "name-too-long",
        43 => "no-device", 44 => "no-entry", 46 => "no-lock", 48 => "insufficient-memory", 51 => "insufficient-space", 54 => "not-directory", 55 => "not-empty", 56 => "not-recoverable",
        52 | 58 => "unsupported", 59 => "no-tty", 60 => "no-such-device", 61 => "overflow", 63 | 76 => "not-permitted", 64 => "pipe", 69 => "read-only", 70 => "invalid-seek", 74 => "text-file-busy", 75 => "cross-device",
        _ => "io",
    }
}
fn ok_none() -> Val { Val::Result(Ok(None)) }
fn ok_some(v: Val) -> Val { Val::Result(Ok(Some(Box::new(v)))) }
fn err_ec(neg: i32) -> Val { Val::Result(Err(Some(Box::new(Val::Enum(ec(-neg).to_string()))))) }
fn err_named(n: &str) -> Val { Val::Result(Err(Some(Box::new(Val::Enum(n.to_string()))))) }
fn dtype_name(t: u64) -> &'static str { match t { 1 => "block-device", 2 => "character-device", 3 => "directory", 4 => "regular-file", 6 => "socket", 7 => "symbolic-link", _ => "unknown" } }
fn datetime(ns: u64) -> Val { Val::Record(vec![("seconds".to_string(), Val::U64(ns / 1_000_000_000)), ("nanoseconds".to_string(), Val::U32((ns % 1_000_000_000) as u32))]) }
fn some_dt(ns: u64) -> Val { Val::Option(Some(Box::new(datetime(ns)))) }

// ---- state -----------------------------------------------------------------------------------------------------------------------------------------------------
pub struct P2 { table: ResourceTable, args: Vec<String>, env: Vec<(String, String)>, exit: Option<i32> }
impl IoView for P2 { fn table(&mut self) -> &mut ResourceTable { &mut self.table } }
static mut ENV: Vec<(String, String)> = Vec::new();
#[no_mangle]
pub unsafe extern "C" fn wn_p2_add_env(k: *const c_char, v: *const c_char) {
    #[allow(static_mut_refs)] ENV.push((CStr::from_ptr(k).to_string_lossy().into_owned(), CStr::from_ptr(v).to_string_lossy().into_owned()));
}

struct Yield(bool);
impl Future for Yield { type Output = (); fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> { if self.0 { Poll::Ready(()) } else { self.0 = true; cx.waker().wake_by_ref(); Poll::Pending } } }

// ---- streams ---------------------------------------------------------------------------------------------------------------------------------------------------
struct StdIn;
#[async_trait]
impl Pollable for StdIn { async fn ready(&mut self) { loop { if hx(|| unsafe { wn_c_poll(0, 0, 2) }) == 1 { return; } Yield(false).await; } } }
impl InputStream for StdIn {
    fn read(&mut self, size: usize) -> StreamResult<Bytes> {
        if hx(|| unsafe { wn_c_poll(0, 0, 0) }) != 1 { return Ok(Bytes::new()); }
        let mut buf = vec![0u8; size.clamp(1, 1 << 16)];
        let n = hx(|| unsafe { wn_c_read(0, buf.as_mut_ptr(), buf.len()) });
        if n == 0 { Err(StreamError::Closed) } else if n < 0 { Err(StreamError::LastOperationFailed(wasmtime::format_err!("stdin read failed"))) } else { buf.truncate(n as usize); Ok(Bytes::from(buf)) }
    }
}
struct StdOut(i32);
#[async_trait]
impl Pollable for StdOut { async fn ready(&mut self) {} }
impl OutputStream for StdOut {
    fn write(&mut self, bytes: Bytes) -> StreamResult<()> {
        let mut off = 0; while off < bytes.len() { let n = hx(|| unsafe { wn_c_write(self.0, bytes.as_ptr().add(off), bytes.len() - off) }); if n <= 0 { return Err(StreamError::LastOperationFailed(wasmtime::format_err!("write failed"))); } off += n as usize; }
        Ok(())
    }
    fn flush(&mut self) -> StreamResult<()> { Ok(()) }
    fn check_write(&mut self) -> StreamResult<usize> { Ok(1 << 20) }
}
struct FileIn { fd: i32, off: u64 }
impl Drop for FileIn { fn drop(&mut self) { hx(|| unsafe { wn_fs_close(self.fd); }); } }
#[async_trait]
impl Pollable for FileIn { async fn ready(&mut self) {} }
impl InputStream for FileIn {
    fn read(&mut self, size: usize) -> StreamResult<Bytes> {
        let mut buf = vec![0u8; size.clamp(1, 1 << 20)];
        let n = hx(|| unsafe { wn_fs_pread(self.fd, buf.as_mut_ptr(), buf.len(), self.off) });
        if n == 0 { Err(StreamError::Closed) } else if n < 0 { Err(StreamError::LastOperationFailed(wasmtime::format_err!("read failed ({n})"))) } else { self.off += n as u64; buf.truncate(n as usize); Ok(Bytes::from(buf)) }
    }
}
struct FileOut { fd: i32, off: u64, append: bool }
impl Drop for FileOut { fn drop(&mut self) { hx(|| unsafe { wn_fs_close(self.fd); }); } }
#[async_trait]
impl Pollable for FileOut { async fn ready(&mut self) {} }
impl OutputStream for FileOut {
    fn write(&mut self, bytes: Bytes) -> StreamResult<()> {
        let mut done = 0usize;
        while done < bytes.len() {
            let off = if self.append { let mut st = [0u64; 8]; if hx(|| unsafe { wn_fs_fstat(self.fd, st.as_mut_ptr()) }) < 0 { return Err(StreamError::LastOperationFailed(wasmtime::format_err!("fstat failed"))); } st[2] } else { self.off };
            let n = hx(|| unsafe { wn_fs_pwrite(self.fd, bytes.as_ptr().add(done), bytes.len() - done, off) });
            if n <= 0 { return Err(StreamError::LastOperationFailed(wasmtime::format_err!("write failed ({n})"))); }
            done += n as usize; self.off += n as u64;
        }
        Ok(())
    }
    fn flush(&mut self) -> StreamResult<()> { Ok(()) }
    fn check_write(&mut self) -> StreamResult<usize> { Ok(1 << 20) }
}
struct Timer { deadline: u64 }
#[async_trait]
impl Pollable for Timer {
    async fn ready(&mut self) {
        loop {
            let now = hx(|| unsafe { wn_c_clock_ns(1) });
            if now >= self.deadline { return; }
            let rem = self.deadline - now; hx(|| unsafe { wn_c_sleep_ns(rem.min(2_000_000)) });
            if hx(|| unsafe { wn_c_clock_ns(1) }) >= self.deadline { return; }
            Yield(false).await;
        }
    }
}
struct TermHandle;
struct DirStream { entries: Vec<(u8, String)>, pos: usize }

// ---- file system objects ---------------------------------------------------------------------------------------------------------------------------------------
enum DescKind { File { fd: i32, rd: bool, wr: bool }, Dir }
struct Desc { kind: DescKind, root: i32, rel: String }
impl Drop for Desc { fn drop(&mut self) { if let DescKind::File { fd, .. } = self.kind { hx(|| unsafe { wn_fs_close(fd); }); } } }

type Cx<'a> = StoreContextMut<'a, P2>;
macro_rules! hf {
    ($name:ident, |$cx:ident, $p:ident, $r:ident| $body:block) => {
        #[allow(unused_mut, unused_variables)]
        fn $name(mut $cx: Cx<'_>, _t: ComponentFunc, $p: &[Val], $r: &mut [Val]) -> Result<()> $body
    };
}

fn push_res<T: Send + 'static>(cx: &mut Cx<'_>, v: T) -> Result<Val> {
    let r: Resource<T> = cx.data_mut().table.push(v)?;
    Ok(Val::Resource(r.try_into_resource_any(&mut *cx)?))
}
fn get_res<T: 'static>(cx: &mut Cx<'_>, v: &Val) -> Result<Resource<T>> {
    match v { Val::Resource(a) => a.clone().try_into_resource::<T>(&mut *cx), _ => bail!("expected a resource handle") }
}
fn str_of(v: &Val) -> Result<&str> { match v { Val::String(s) => Ok(s.as_str()), _ => bail!("expected a string") } }
fn flags_of(v: &Val) -> Vec<String> { match v { Val::Flags(f) => f.clone(), _ => Vec::new() } }
fn u64_of(v: &Val) -> u64 { match v { Val::U64(x) => *x, Val::U32(x) => *x as u64, Val::U8(x) => *x as u64, _ => 0 } }
/// (root, rel, is_dir, fd) of a descriptor argument
fn desc_info(cx: &mut Cx<'_>, v: &Val) -> Result<(i32, String, bool, i32, bool, bool)> {
    let r = get_res::<Desc>(cx, v)?; let d = cx.data_mut().table.get(&r)?;
    Ok(match d.kind { DescKind::Dir => (d.root, d.rel.clone(), true, -1, false, false), DescKind::File { fd, rd, wr } => (d.root, d.rel.clone(), false, fd, rd, wr) })
}
fn timestamp_mode(v: &Val) -> (i32, u64) {   // new-timestamp: no-change | now | timestamp(datetime)
    match v {
        Val::Variant(n, payload) => match n.as_str() {
            "now" => (1, 0),
            "timestamp" => match payload.as_deref() { Some(Val::Record(f)) => { let mut s = 0u64; let mut ns = 0u64; for (k, x) in f { if k == "seconds" { s = u64_of(x); } else if k == "nanoseconds" { ns = u64_of(x); } } (2, s * 1_000_000_000 + ns) } _ => (0, 0) },
            _ => (0, 0),
        },
        _ => (0, 0),
    }
}

// ---- wasi:cli ------------------------------------------------------------------------------------------------------------------------------------------------
hf!(cli_env, |cx, p, r| { r[0] = Val::List(cx.data().env.iter().map(|(k, v)| Val::Tuple(vec![Val::String(k.clone()), Val::String(v.clone())])).collect()); Ok(()) });
hf!(cli_args, |cx, p, r| { r[0] = Val::List(cx.data().args.iter().map(|a| Val::String(a.clone())).collect()); Ok(()) });
hf!(cli_cwd, |cx, p, r| { r[0] = Val::Option(None); Ok(()) });
hf!(cli_exit, |cx, p, r| { let code = match p.first() { Some(Val::Result(Ok(_))) => 0, _ => 1 }; cx.data_mut().exit = Some(code); bail!("exit {code}") });
hf!(cli_exit_code, |cx, p, r| { let code = match p.first() { Some(Val::U8(c)) => *c as i32, _ => 1 }; cx.data_mut().exit = Some(code); bail!("exit {code}") });
hf!(cli_stdin, |cx, p, r| { r[0] = push_res::<DynInputStream>(&mut cx, Box::new(StdIn))?; Ok(()) });
hf!(cli_stdout, |cx, p, r| { r[0] = push_res::<DynOutputStream>(&mut cx, Box::new(StdOut(1)))?; Ok(()) });
hf!(cli_stderr, |cx, p, r| { r[0] = push_res::<DynOutputStream>(&mut cx, Box::new(StdOut(2)))?; Ok(()) });
hf!(cli_no_terminal, |cx, p, r| { r[0] = Val::Option(None); Ok(()) });

// ---- wasi:clocks / wasi:random -------------------------------------------------------------------------------------------------------------------------------------
hf!(mono_now, |cx, p, r| { r[0] = Val::U64(hx(|| unsafe { wn_c_clock_ns(1) })); Ok(()) });
hf!(mono_res, |cx, p, r| { r[0] = Val::U64(hx(|| unsafe { wn_c_clock_res_ns(1) })); Ok(()) });
hf!(mono_sub_instant, |cx, p, r| { let when = u64_of(&p[0]); let res = cx.data_mut().table.push(Timer { deadline: when })?; let pr = subscribe(&mut cx.data_mut().table, res)?; r[0] = Val::Resource(pr.try_into_resource_any(&mut cx)?); Ok(()) });
hf!(mono_sub_duration, |cx, p, r| { let now = hx(|| unsafe { wn_c_clock_ns(1) }); let when = now.saturating_add(u64_of(&p[0])); let res = cx.data_mut().table.push(Timer { deadline: when })?; let pr = subscribe(&mut cx.data_mut().table, res)?; r[0] = Val::Resource(pr.try_into_resource_any(&mut cx)?); Ok(()) });
hf!(wall_now, |cx, p, r| { r[0] = datetime(hx(|| unsafe { wn_c_clock_ns(0) })); Ok(()) });
hf!(wall_res, |cx, p, r| { r[0] = datetime(hx(|| unsafe { wn_c_clock_res_ns(0) })); Ok(()) });
fn random_bytes(n: u64) -> Result<Vec<Val>> { let mut b = vec![0u8; n.min(1 << 24) as usize]; if hx(|| unsafe { wn_c_random(b.as_mut_ptr(), b.len()) }) < 0 { bail!("random failed"); } Ok(b.into_iter().map(Val::U8).collect()) }
fn random_u64() -> Result<u64> { let mut b = [0u8; 8]; if hx(|| unsafe { wn_c_random(b.as_mut_ptr(), 8) }) < 0 { bail!("random failed"); } Ok(u64::from_le_bytes(b)) }
hf!(rnd_bytes, |cx, p, r| { r[0] = Val::List(random_bytes(u64_of(&p[0]))?); Ok(()) });
hf!(rnd_u64, |cx, p, r| { r[0] = Val::U64(random_u64()?); Ok(()) });
hf!(rnd_seed, |cx, p, r| { r[0] = Val::Tuple(vec![Val::U64(random_u64()?), Val::U64(random_u64()?)]); Ok(()) });

// ---- wasi:filesystem -----------------------------------------------------------------------------------------------------------------------------------------------
hf!(fs_preopens, |cx, p, r| {
    let n = hx(|| unsafe { wn_fs_count() }); let mut v = Vec::new();
    for i in 0..n {
        let root = hx(|| unsafe { wn_fs_root_of(i) }); let name = hx(|| unsafe { CStr::from_ptr(wn_fs_guest_name(i)).to_string_lossy().into_owned() });
        v.push(Val::Tuple(vec![push_res::<Desc>(&mut cx, Desc { kind: DescKind::Dir, root, rel: String::new() })?, Val::String(name)]));
    }
    r[0] = Val::List(v); Ok(())
});
hf!(fs_err_code, |cx, p, r| { r[0] = Val::Option(None); Ok(()) });
fn stat_record(st: &[u64; 8]) -> Val {
    Val::Record(vec![("type".to_string(), Val::Enum(dtype_name(st[0]).to_string())), ("link-count".to_string(), Val::U64(st[1])), ("size".to_string(), Val::U64(st[2])),
        ("data-access-timestamp".to_string(), some_dt(st[3])), ("data-modification-timestamp".to_string(), some_dt(st[4])), ("status-change-timestamp".to_string(), some_dt(st[5]))])
}
hf!(fs_get_type, |cx, p, r| {
    let (root, rel, is_dir, fd, _, _) = desc_info(&mut cx, &p[0])?; let mut st = [0u64; 8];
    let e = if is_dir { let c = cs(&rel); hx(|| unsafe { wn_fs_stat(root, c.as_ptr() as *const c_char, 1, st.as_mut_ptr()) }) } else { hx(|| unsafe { wn_fs_fstat(fd, st.as_mut_ptr()) }) };
    r[0] = if e < 0 { err_ec(e) } else { ok_some(Val::Enum(dtype_name(st[0]).to_string())) }; Ok(())
});
hf!(fs_stat, |cx, p, r| {
    let (root, rel, is_dir, fd, _, _) = desc_info(&mut cx, &p[0])?; let mut st = [0u64; 8];
    let e = if is_dir { let c = cs(&rel); hx(|| unsafe { wn_fs_stat(root, c.as_ptr() as *const c_char, 1, st.as_mut_ptr()) }) } else { hx(|| unsafe { wn_fs_fstat(fd, st.as_mut_ptr()) }) };
    r[0] = if e < 0 { err_ec(e) } else { ok_some(stat_record(&st)) }; Ok(())
});
/// resolves `path` relative to descriptor p[0] (path argument at index `pi`, path-flags at index `fi`, or follow when None)
fn resolve_in(cx: &mut Cx<'_>, d: &Val, path: &Val, follow: bool) -> Result<core::result::Result<(i32, String), i32>> {
    let (root, rel, is_dir, ..) = desc_info(cx, d)?;
    if !is_dir { return Ok(Err(-54)); }
    let (b, pth) = (cs(&rel), cs(str_of(path)?)); let mut out = vec![0u8; 4096];
    let e = hx(|| unsafe { wn_fs_resolve(root, b.as_ptr() as *const c_char, pth.as_ptr() as *const c_char, follow as i32, out.as_mut_ptr() as *mut c_char, out.len()) });
    if e < 0 { return Ok(Err(e)); }
    let n = out.iter().position(|&c| c == 0).unwrap_or(0); Ok(Ok((root, String::from_utf8_lossy(&out[..n]).into_owned())))
}
hf!(fs_stat_at, |cx, p, r| {
    let follow = flags_of(&p[1]).iter().any(|f| f == "symlink-follow");
    match resolve_in(&mut cx, &p[0], &p[2], follow)? {
        Err(e) => r[0] = err_ec(e),
        Ok((root, rel)) => { let mut st = [0u64; 8]; let c = cs(&rel); let e = hx(|| unsafe { wn_fs_stat(root, c.as_ptr() as *const c_char, follow as i32, st.as_mut_ptr()) }); r[0] = if e < 0 { err_ec(e) } else { ok_some(stat_record(&st)) }; }
    }
    Ok(())
});
hf!(fs_open_at, |cx, p, r| {
    let follow = flags_of(&p[1]).iter().any(|f| f == "symlink-follow");
    let of = flags_of(&p[3]); let df = flags_of(&p[4]);
    let has = |v: &Vec<String>, n: &str| v.iter().any(|f| f == n);
    let (create, directory, excl, trunc) = (has(&of, "create"), has(&of, "directory"), has(&of, "exclusive"), has(&of, "truncate"));
    let (rd, wr) = (has(&df, "read"), has(&df, "write"));
    let (root, rel) = match resolve_in(&mut cx, &p[0], &p[2], follow)? { Err(e) => { r[0] = err_ec(e); return Ok(()); } Ok(x) => x };
    let c = cs(&rel); let mut st = [0u64; 8];
    let exists = hx(|| unsafe { wn_fs_stat(root, c.as_ptr() as *const c_char, follow as i32, st.as_mut_ptr()) }) >= 0;
    if exists && st[0] == 3 {
        if wr || trunc { r[0] = err_named("is-directory"); return Ok(()); }
        if create && excl { r[0] = err_named("exist"); return Ok(()); }
        r[0] = ok_some(push_res::<Desc>(&mut cx, Desc { kind: DescKind::Dir, root, rel })?); return Ok(());
    }
    if directory { r[0] = err_named(if exists { "not-directory" } else { "no-entry" }); return Ok(()); }
    let (rd2, wr2) = if !rd && !wr { (true, false) } else { (rd, wr) };
    let fd = hx(|| unsafe { wn_fs_open(root, c.as_ptr() as *const c_char, rd2 as i32, wr2 as i32, create as i32, excl as i32, trunc as i32, 0) });
    if fd < 0 { r[0] = err_ec(fd); return Ok(()); }
    r[0] = ok_some(push_res::<Desc>(&mut cx, Desc { kind: DescKind::File { fd, rd: rd2, wr: wr2 }, root, rel })?); Ok(())
});
hf!(fs_read_via_stream, |cx, p, r| {
    let (_, _, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; if is_dir { r[0] = err_named("is-directory"); return Ok(()); }
    let d = hx(|| unsafe { wn_fs_dup(fd) }); if d < 0 { r[0] = err_ec(d); return Ok(()); }
    r[0] = ok_some(push_res::<DynInputStream>(&mut cx, Box::new(FileIn { fd: d, off: u64_of(&p[1]) }))?); Ok(())
});
hf!(fs_write_via_stream, |cx, p, r| {
    let (_, _, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; if is_dir { r[0] = err_named("is-directory"); return Ok(()); }
    let d = hx(|| unsafe { wn_fs_dup(fd) }); if d < 0 { r[0] = err_ec(d); return Ok(()); }
    r[0] = ok_some(push_res::<DynOutputStream>(&mut cx, Box::new(FileOut { fd: d, off: u64_of(&p[1]), append: false }))?); Ok(())
});
hf!(fs_append_via_stream, |cx, p, r| {
    let (_, _, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; if is_dir { r[0] = err_named("is-directory"); return Ok(()); }
    let d = hx(|| unsafe { wn_fs_dup(fd) }); if d < 0 { r[0] = err_ec(d); return Ok(()); }
    r[0] = ok_some(push_res::<DynOutputStream>(&mut cx, Box::new(FileOut { fd: d, off: 0, append: true }))?); Ok(())
});
hf!(fs_read, |cx, p, r| {
    let (_, _, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; if is_dir { r[0] = err_named("is-directory"); return Ok(()); }
    let mut buf = vec![0u8; u64_of(&p[1]).min(1 << 24) as usize];
    let n = hx(|| unsafe { wn_fs_pread(fd, buf.as_mut_ptr(), buf.len(), u64_of(&p[2])) });
    r[0] = if n < 0 { err_ec(n as i32) } else { buf.truncate(n as usize); ok_some(Val::Tuple(vec![Val::List(buf.into_iter().map(Val::U8).collect()), Val::Bool(n == 0)])) }; Ok(())
});
hf!(fs_write, |cx, p, r| {
    let (_, _, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; if is_dir { r[0] = err_named("is-directory"); return Ok(()); }
    let data: Vec<u8> = match &p[1] { Val::List(l) => l.iter().map(|v| if let Val::U8(b) = v { *b } else { 0 }).collect(), _ => Vec::new() };
    let n = hx(|| unsafe { wn_fs_pwrite(fd, data.as_ptr(), data.len(), u64_of(&p[2])) });
    r[0] = if n < 0 { err_ec(n as i32) } else { ok_some(Val::U64(n as u64)) }; Ok(())
});
hf!(fs_create_dir, |cx, p, r| {
    match resolve_in(&mut cx, &p[0], &p[1], false)? { Err(e) => r[0] = err_ec(e), Ok((root, rel)) => { let c = cs(&rel); let e = hx(|| unsafe { wn_fs_mkdir(root, c.as_ptr() as *const c_char) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; } } Ok(())
});
hf!(fs_remove_dir, |cx, p, r| {
    match resolve_in(&mut cx, &p[0], &p[1], false)? { Err(e) => r[0] = err_ec(e), Ok((root, rel)) => { let c = cs(&rel); let e = hx(|| unsafe { wn_fs_rmdir(root, c.as_ptr() as *const c_char) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; } } Ok(())
});
hf!(fs_unlink, |cx, p, r| {
    match resolve_in(&mut cx, &p[0], &p[1], false)? { Err(e) => r[0] = err_ec(e), Ok((root, rel)) => { let c = cs(&rel); let e = hx(|| unsafe { wn_fs_unlink(root, c.as_ptr() as *const c_char) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; } } Ok(())
});
hf!(fs_rename, |cx, p, r| {
    let a = resolve_in(&mut cx, &p[0], &p[1], false)?; let b = resolve_in(&mut cx, &p[2], &p[3], false)?;
    match (a, b) { (Err(e), _) | (_, Err(e)) => r[0] = err_ec(e), (Ok((r1, x)), Ok((r2, y))) => { let (cx1, cy) = (cs(&x), cs(&y)); let e = hx(|| unsafe { wn_fs_rename(r1, cx1.as_ptr() as *const c_char, r2, cy.as_ptr() as *const c_char) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; } } Ok(())
});
hf!(fs_link_at, |cx, p, r| {   // (self, old-path-flags, old-path, new-descriptor, new-path)
    let follow = flags_of(&p[1]).iter().any(|f| f == "symlink-follow");
    let a = resolve_in(&mut cx, &p[0], &p[2], follow)?; let b = resolve_in(&mut cx, &p[3], &p[4], false)?;
    match (a, b) { (Err(e), _) | (_, Err(e)) => r[0] = err_ec(e), (Ok((r1, x)), Ok((r2, y))) => { let (cx1, cy) = (cs(&x), cs(&y)); let e = hx(|| unsafe { wn_fs_link(r1, cx1.as_ptr() as *const c_char, r2, cy.as_ptr() as *const c_char) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; } } Ok(())
});
hf!(fs_symlink_at, |cx, p, r| {   // (self, old-path, new-path)
    match resolve_in(&mut cx, &p[0], &p[2], false)? { Err(e) => r[0] = err_ec(e), Ok((root, rel)) => { let (t, c) = (cs(str_of(&p[1])?), cs(&rel)); let e = hx(|| unsafe { wn_fs_symlink(t.as_ptr() as *const c_char, root, c.as_ptr() as *const c_char) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; } } Ok(())
});
hf!(fs_readlink_at, |cx, p, r| {
    match resolve_in(&mut cx, &p[0], &p[1], false)? { Err(e) => r[0] = err_ec(e), Ok((root, rel)) => { let c = cs(&rel); let mut buf = vec![0u8; 4096]; let n = hx(|| unsafe { wn_fs_readlink(root, c.as_ptr() as *const c_char, buf.as_mut_ptr() as *mut c_char, buf.len()) }); r[0] = if n < 0 { err_ec(n) } else { ok_some(Val::String(String::from_utf8_lossy(&buf[..n as usize]).into_owned())) }; } } Ok(())
});
hf!(fs_set_size, |cx, p, r| {
    let (_, _, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; if is_dir { r[0] = err_named("is-directory"); return Ok(()); }
    let e = hx(|| unsafe { wn_fs_ftruncate(fd, u64_of(&p[1])) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; Ok(())
});
hf!(fs_sync, |cx, p, r| {
    let (_, _, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; if is_dir { r[0] = ok_none(); return Ok(()); }
    let e = hx(|| unsafe { wn_fs_fsync(fd, 0) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; Ok(())
});
hf!(fs_advise, |cx, p, r| { r[0] = ok_none(); Ok(()) });
hf!(fs_get_flags, |cx, p, r| {
    let (_, _, is_dir, _, rd, wr) = desc_info(&mut cx, &p[0])?; let mut f = Vec::new(); if is_dir || rd { f.push("read".to_string()); } if wr { f.push("write".to_string()); }
    r[0] = ok_some(Val::Flags(f)); Ok(())
});
hf!(fs_set_times, |cx, p, r| {   // (self, atime, mtime)
    let (root, rel, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; let (am, an) = timestamp_mode(&p[1]); let (mm, mn) = timestamp_mode(&p[2]);
    let c = cs(&rel);
    let e = if is_dir { hx(|| unsafe { wn_fs_utimens(root, c.as_ptr() as *const c_char, 1, am, an, mm, mn) }) } else { hx(|| unsafe { wn_fs_futimens(fd, am, an, mm, mn) }) };
    r[0] = if e < 0 { err_ec(e) } else { ok_none() }; Ok(())
});
hf!(fs_set_times_at, |cx, p, r| {   // (self, path-flags, path, atime, mtime)
    let follow = flags_of(&p[1]).iter().any(|f| f == "symlink-follow"); let (am, an) = timestamp_mode(&p[3]); let (mm, mn) = timestamp_mode(&p[4]);
    match resolve_in(&mut cx, &p[0], &p[2], follow)? { Err(e) => r[0] = err_ec(e), Ok((root, rel)) => { let c = cs(&rel); let e = hx(|| unsafe { wn_fs_utimens(root, c.as_ptr() as *const c_char, follow as i32, am, an, mm, mn) }); r[0] = if e < 0 { err_ec(e) } else { ok_none() }; } } Ok(())
});
fn hash_val(st: &[u64; 8]) -> Val { Val::Record(vec![("lower".to_string(), Val::U64(st[6])), ("upper".to_string(), Val::U64(st[7]))]) }
hf!(fs_metadata_hash, |cx, p, r| {
    let (root, rel, is_dir, fd, ..) = desc_info(&mut cx, &p[0])?; let mut st = [0u64; 8];
    let e = if is_dir { let c = cs(&rel); hx(|| unsafe { wn_fs_stat(root, c.as_ptr() as *const c_char, 1, st.as_mut_ptr()) }) } else { hx(|| unsafe { wn_fs_fstat(fd, st.as_mut_ptr()) }) };
    r[0] = if e < 0 { err_ec(e) } else { ok_some(hash_val(&st)) }; Ok(())
});
hf!(fs_metadata_hash_at, |cx, p, r| {
    let follow = flags_of(&p[1]).iter().any(|f| f == "symlink-follow");
    match resolve_in(&mut cx, &p[0], &p[2], follow)? { Err(e) => r[0] = err_ec(e), Ok((root, rel)) => { let mut st = [0u64; 8]; let c = cs(&rel); let e = hx(|| unsafe { wn_fs_stat(root, c.as_ptr() as *const c_char, follow as i32, st.as_mut_ptr()) }); r[0] = if e < 0 { err_ec(e) } else { ok_some(hash_val(&st)) }; } } Ok(())
});
hf!(fs_is_same, |cx, p, r| {
    let (r1, rel1, d1, f1, ..) = desc_info(&mut cx, &p[0])?; let (r2, rel2, d2, f2, ..) = desc_info(&mut cx, &p[1])?; let (mut a, mut b) = ([0u64; 8], [0u64; 8]);
    let ea = if d1 { let c = cs(&rel1); hx(|| unsafe { wn_fs_stat(r1, c.as_ptr() as *const c_char, 1, a.as_mut_ptr()) }) } else { hx(|| unsafe { wn_fs_fstat(f1, a.as_mut_ptr()) }) };
    let eb = if d2 { let c = cs(&rel2); hx(|| unsafe { wn_fs_stat(r2, c.as_ptr() as *const c_char, 1, b.as_mut_ptr()) }) } else { hx(|| unsafe { wn_fs_fstat(f2, b.as_mut_ptr()) }) };
    r[0] = Val::Bool(ea >= 0 && eb >= 0 && a[6] == b[6] && a[7] == b[7]); Ok(())
});
hf!(fs_read_directory, |cx, p, r| {
    let (root, rel, is_dir, ..) = desc_info(&mut cx, &p[0])?; if !is_dir { r[0] = err_named("not-directory"); return Ok(()); }
    let c = cs(&rel); let mut buf: *mut u8 = core::ptr::null_mut(); let mut len = 0usize;
    let e = hx(|| unsafe { wn_fs_readdir(root, c.as_ptr() as *const c_char, &mut buf, &mut len) });
    if e < 0 { r[0] = err_ec(e); return Ok(()); }
    let bytes = unsafe { core::slice::from_raw_parts(buf, len) }; let mut entries = Vec::new(); let mut i = 0;
    while i + 5 <= bytes.len() { let ty = bytes[i]; let nl = u32::from_le_bytes([bytes[i + 1], bytes[i + 2], bytes[i + 3], bytes[i + 4]]) as usize; let name = String::from_utf8_lossy(&bytes[i + 5..i + 5 + nl]).into_owned(); entries.push((ty, name)); i += 5 + nl; }
    hx(|| unsafe { wn_free(buf) });
    r[0] = ok_some(push_res::<DirStream>(&mut cx, DirStream { entries, pos: 0 })?); Ok(())
});
hf!(fs_read_dir_entry, |cx, p, r| {
    let res = get_res::<DirStream>(&mut cx, &p[0])?; let ds = cx.data_mut().table.get_mut(&res)?;
    r[0] = if ds.pos < ds.entries.len() { let (t, n) = ds.entries[ds.pos].clone(); ds.pos += 1; ok_some(Val::Option(Some(Box::new(Val::Record(vec![("type".to_string(), Val::Enum(dtype_name(t as u64).to_string())), ("name".to_string(), Val::String(n))]))))) } else { ok_some(Val::Option(None)) };
    Ok(())
});

fn add_all(l: &mut Linker<P2>) -> Result<()> {
    let v = "0.2.12";
    let n = |s: &str| format!("{s}@{v}");
    { let mut i = l.instance(&n("wasi:cli/environment"))?; i.func_new("get-environment", cli_env)?; i.func_new("get-arguments", cli_args)?; i.func_new("initial-cwd", cli_cwd)?; }
    { let mut i = l.instance(&n("wasi:cli/exit"))?; i.func_new("exit", cli_exit)?; i.func_new("exit-with-code", cli_exit_code)?; }
    { let mut i = l.instance(&n("wasi:cli/stdin"))?; i.func_new("get-stdin", cli_stdin)?; }
    { let mut i = l.instance(&n("wasi:cli/stdout"))?; i.func_new("get-stdout", cli_stdout)?; }
    { let mut i = l.instance(&n("wasi:cli/stderr"))?; i.func_new("get-stderr", cli_stderr)?; }
    { let mut i = l.instance(&n("wasi:cli/terminal-input"))?; i.resource("terminal-input", ResourceType::host::<TermHandle>(), |_, _| Ok(()))?; }
    { let mut i = l.instance(&n("wasi:cli/terminal-output"))?; i.resource("terminal-output", ResourceType::host::<TermHandle>(), |_, _| Ok(()))?; }
    { let mut i = l.instance(&n("wasi:cli/terminal-stdin"))?; i.func_new("get-terminal-stdin", cli_no_terminal)?; }
    { let mut i = l.instance(&n("wasi:cli/terminal-stdout"))?; i.func_new("get-terminal-stdout", cli_no_terminal)?; }
    { let mut i = l.instance(&n("wasi:cli/terminal-stderr"))?; i.func_new("get-terminal-stderr", cli_no_terminal)?; }
    { let mut i = l.instance(&n("wasi:clocks/monotonic-clock"))?; i.func_new("now", mono_now)?; i.func_new("resolution", mono_res)?; i.func_new("subscribe-instant", mono_sub_instant)?; i.func_new("subscribe-duration", mono_sub_duration)?; }
    { let mut i = l.instance(&n("wasi:clocks/wall-clock"))?; i.func_new("now", wall_now)?; i.func_new("resolution", wall_res)?; }
    { let mut i = l.instance(&n("wasi:random/random"))?; i.func_new("get-random-bytes", rnd_bytes)?; i.func_new("get-random-u64", rnd_u64)?; }
    { let mut i = l.instance(&n("wasi:random/insecure"))?; i.func_new("get-insecure-random-bytes", rnd_bytes)?; i.func_new("get-insecure-random-u64", rnd_u64)?; }
    { let mut i = l.instance(&n("wasi:random/insecure-seed"))?; i.func_new("insecure-seed", rnd_seed)?; }
    { let mut i = l.instance(&n("wasi:filesystem/preopens"))?; i.func_new("get-directories", fs_preopens)?; }
    {
        let mut i = l.instance(&n("wasi:filesystem/types"))?;
        i.resource("descriptor", ResourceType::host::<Desc>(), |mut cx, rep| { let _ = cx.data_mut().table.delete(Resource::<Desc>::new_own(rep)); Ok(()) })?;
        i.resource("directory-entry-stream", ResourceType::host::<DirStream>(), |mut cx, rep| { let _ = cx.data_mut().table.delete(Resource::<DirStream>::new_own(rep)); Ok(()) })?;
        i.func_new("filesystem-error-code", fs_err_code)?;
        i.func_new("[method]descriptor.read-via-stream", fs_read_via_stream)?; i.func_new("[method]descriptor.write-via-stream", fs_write_via_stream)?; i.func_new("[method]descriptor.append-via-stream", fs_append_via_stream)?;
        i.func_new("[method]descriptor.advise", fs_advise)?; i.func_new("[method]descriptor.sync-data", fs_sync)?; i.func_new("[method]descriptor.sync", fs_sync)?;
        i.func_new("[method]descriptor.get-flags", fs_get_flags)?; i.func_new("[method]descriptor.get-type", fs_get_type)?; i.func_new("[method]descriptor.set-size", fs_set_size)?;
        i.func_new("[method]descriptor.set-times", fs_set_times)?; i.func_new("[method]descriptor.read", fs_read)?; i.func_new("[method]descriptor.write", fs_write)?;
        i.func_new("[method]descriptor.read-directory", fs_read_directory)?; i.func_new("[method]descriptor.create-directory-at", fs_create_dir)?;
        i.func_new("[method]descriptor.stat", fs_stat)?; i.func_new("[method]descriptor.stat-at", fs_stat_at)?; i.func_new("[method]descriptor.set-times-at", fs_set_times_at)?;
        i.func_new("[method]descriptor.link-at", fs_link_at)?; i.func_new("[method]descriptor.open-at", fs_open_at)?; i.func_new("[method]descriptor.readlink-at", fs_readlink_at)?;
        i.func_new("[method]descriptor.remove-directory-at", fs_remove_dir)?; i.func_new("[method]descriptor.rename-at", fs_rename)?; i.func_new("[method]descriptor.symlink-at", fs_symlink_at)?;
        i.func_new("[method]descriptor.unlink-file-at", fs_unlink)?; i.func_new("[method]descriptor.is-same-object", fs_is_same)?;
        i.func_new("[method]descriptor.metadata-hash", fs_metadata_hash)?; i.func_new("[method]descriptor.metadata-hash-at", fs_metadata_hash_at)?;
        i.func_new("[method]directory-entry-stream.read-directory-entry", fs_read_dir_entry)?;
    }
    Ok(())
}

async fn run_component(linker: &Linker<P2>, comp: &Component, store: &mut Store<P2>, engine: &Engine) -> Result<i32> {
    let inst = linker.instantiate_async(&mut *store, comp).await?;
    let mut found: Option<String> = None;
    for (n, _) in comp.component_type().exports(engine) { if n.starts_with("wasi:cli/run@") { found = Some(n.to_string()); } }
    let name = match found { Some(n) => n, None => bail!("the component does not export wasi:cli/run") };
    let idx = match inst.get_export_index(&mut *store, None, &name) { Some(i) => i, None => bail!("no export {name}") };
    let fidx = match inst.get_export_index(&mut *store, Some(&idx), "run") { Some(i) => i, None => bail!("no run in {name}") };
    let f = match inst.get_func(&mut *store, &fidx) { Some(f) => f, None => bail!("run is not a function") };
    let mut res = [Val::Bool(false)];
    match f.call_async(&mut *store, &[], &mut res).await {
        Ok(()) => Ok(match &res[0] { Val::Result(Ok(_)) => 0, _ => 1 }),
        Err(e) => match store.data().exit { Some(c) => Ok(c), None => Err(e) },
    }
}

/// Runs the loaded component's `wasi:cli/run`. `argv[0]` is the program name. Returns 0 and the exit code in `*exit_code`, or -1 with wn_last_error().
#[no_mangle]
pub unsafe extern "C" fn wn_p2_run(argc: i32, argv: *const *const c_char, exit_code: *mut i32) -> i32 {
    #[allow(static_mut_refs)]
    let comp = match COMP.as_ref() { Some(c) => c, None => return fail("no component loaded") };
    let s = st();
    let mut linker: Linker<P2> = Linker::new(&s.engine);
    if let Err(e) = add_to_linker_async(&mut linker) { return fail(e); }
    if let Err(e) = add_all(&mut linker) { return fail(e); }
    if let Err(e) = linker.define_unknown_imports_as_traps(comp) { return fail(e); }
    let args: Vec<String> = (0..argc as usize).map(|i| CStr::from_ptr(*argv.add(i)).to_string_lossy().into_owned()).collect();
    #[allow(static_mut_refs)]
    let env = ENV.clone();
    let mut store = Store::new(&s.engine, P2 { table: ResourceTable::new(), args, env, exit: None });
    let mine = x28_get(); wn_host_x28 = mine;
    let mut polls = 0u64;
    let r = block_on(run_component(&linker, comp, &mut store, &s.engine), &mut polls);
    x28_set(mine);
    s.pending_polls += polls;
    match r { Ok(c) => { *exit_code = c; 0 } Err(e) => fail(e) }
}
