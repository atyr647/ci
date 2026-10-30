// One benchmark source for "Dawn built by Cosmopolitan" and "native Dawn" (same webgpu.h API, same adapter/backend, compiled by each side's own toolchain).
// What it measures is the CPU side of the stack - Dawn's validation, command recording, Tint, the allocator, mutexes, the C library - and, on whatever adapter the
// machine has, the GPU kernel. It prints one line per metric:   BENCH <name> <value> <unit>
// Environment: WGT_BACKEND=vulkan|d3d12|metal (default: Dawn's choice), WGT_FALLBACK=1 (software adapter), BENCH_SCALE=<float> (default 1; shrinks every loop).
#if defined(__COSMOPOLITAN__)
#define _COSMO_SOURCE 1
#endif
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <webgpu/webgpu.h>
#if defined(__COSMOPOLITAN__)
#include <cosmo.h>
#define WIN_SHIELD_WRAP_THREADS 1
#include "win_shield.h"
#endif

using Clock = std::chrono::steady_clock;
static double ms_since(Clock::time_point t) { return std::chrono::duration<double, std::milli>(Clock::now() - t).count(); }
static double g_scale = 1.0;
static int scaled(int n) { int v = (int)(n * g_scale); return v < 1 ? 1 : v; }
static void bench(const char *name, double v, const char *unit) { printf("BENCH %s %.4f %s\n", name, v, unit); fflush(stdout); }
static double median(std::vector<double> v) { std::sort(v.begin(), v.end()); return v.empty() ? 0 : v[v.size() / 2]; }

// ---------------------------------------------------------------- host-only baselines (no GPU): separate "Dawn is slower" from "this compiler / C library is slower"
static void host_baselines() {
    {   // allocator: new/delete of small blocks, the pattern Dawn's reference-counted objects produce
        const int n = scaled(3000000); std::vector<void *> keep(64, nullptr);
        auto t = Clock::now();
        for (int i = 0; i < n; i++) { void *&p = keep[i & 63]; ::operator delete(p); p = ::operator new(48 + (i & 63)); }
        double ms = ms_since(t); for (void *p : keep) ::operator delete(p);
        bench("host_alloc_ns", ms * 1e6 / n, "ns/op");
    }
    {   // uncontended mutex lock/unlock
        std::mutex m; const int n = scaled(8000000); volatile int x = 0; auto t = Clock::now();
        for (int i = 0; i < n; i++) { m.lock(); x = x + 1; m.unlock(); }
        bench("host_mutex_ns", ms_since(t) * 1e6 / n, "ns/op");
    }
    {   // memcpy bandwidth
        const size_t sz = 64u << 20; std::vector<char> a(sz, 1), b(sz); double best = 1e30;
        volatile char keep = 0;
        for (int r = 0; r < 6; r++) { a[r] = (char)r; auto t = Clock::now(); memcpy(b.data(), a.data(), sz); keep = keep + b[(size_t)r * 4099]; double ms = ms_since(t); if (ms < best) best = ms; }   // the copy's result is read, so the compiler cannot drop it
        bench("host_memcpy_GBps", sz / (best / 1e3) / 1e9, "GB/s");
    }
    {   // scalar integer loop (FNV-1a over a buffer)
        const size_t sz = (size_t)(64u << 20); std::vector<uint8_t> a(sz); for (size_t i = 0; i < sz; i++) a[i] = (uint8_t)(i * 31 + 7);
        double best = 1e30; uint64_t h = 0;
        for (int r = 0; r < 4; r++) { auto t = Clock::now(); uint64_t x = 1469598103934665603ull; for (size_t i = 0; i < sz; i++) x = (x ^ a[i]) * 1099511628211ull; h ^= x; double ms = ms_since(t); if (ms < best) best = ms; }
        bench("host_fnv_MBps", sz / (best / 1e3) / 1e6, "MB/s"); if (h == 42) puts("");
    }
    {   // scalar float loop with a dependency chain broken into 8 lanes (what an auto-vectorizer may or may not turn into SIMD)
        const int n = scaled(40000000); float s[8] = {1, 2, 3, 4, 5, 6, 7, 8}; auto t = Clock::now();
        for (int i = 0; i < n; i++) for (int k = 0; k < 8; k++) s[k] = s[k] * 0.9999f + 0.0001f * (float)k;
        double ms = ms_since(t); float acc = 0; for (float f : s) acc += f; if (acc == 123.f) puts("");
        bench("host_float_GFLOPs", (double)n * 8 * 3 / (ms / 1e3) / 1e9, "GFLOP/s");
    }
}

// ---------------------------------------------------------------- WebGPU
static WGPUInstance g_inst; static volatile int g_done; static int g_status; static WGPUAdapter g_adapter; static WGPUDevice g_device;
static void on_adapter(WGPURequestAdapterStatus s, WGPUAdapter a, WGPUStringView, void *, void *) { g_status = s; g_adapter = a; g_done = 1; }
static void on_device(WGPURequestDeviceStatus s, WGPUDevice d, WGPUStringView, void *, void *) { g_status = s; g_device = d; g_done = 1; }
static void on_map(WGPUMapAsyncStatus s, WGPUStringView, void *, void *) { g_status = s; g_done = 1; }
static bool pump(double limit_ms = 30000) { auto t = Clock::now(); while (!g_done) { wgpuInstanceProcessEvents(g_inst); if (ms_since(t) > limit_ms) return false; std::this_thread::yield(); } return true; }
static std::string sv(WGPUStringView s) { return s.data ? std::string(s.data, s.length == WGPU_STRLEN ? strlen(s.data) : s.length) : ""; }

static WGPUShaderModule make_module(WGPUDevice dev, const std::string &wgsl) {
    WGPUShaderSourceWGSL w = WGPU_SHADER_SOURCE_WGSL_INIT; w.code = {wgsl.data(), wgsl.size()};
    WGPUShaderModuleDescriptor d = WGPU_SHADER_MODULE_DESCRIPTOR_INIT; d.nextInChain = &w.chain; return wgpuDeviceCreateShaderModule(dev, &d);
}
static WGPUComputePipeline make_pipeline(WGPUDevice dev, WGPUShaderModule m) {
    WGPUComputePipelineDescriptor c = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT; c.compute.module = m; c.compute.entryPoint = {"main", 4}; return wgpuDeviceCreateComputePipeline(dev, &c);
}
// a large module for the front end (parse, resolve, validate, IR): many small functions with control flow, one entry point that touches all of them
static std::string big_wgsl(int funcs, int salt) {
    std::string s = "@group(0) @binding(0) var<storage, read_write> d : array<f32>;\nstruct S { a : f32, b : vec4<f32>, c : array<u32, 4> };\n";
    for (int i = 0; i < funcs; i++) {
        std::string n = std::to_string(i), k = std::to_string(salt * 1000 + i);
        s += "fn f" + n + "(x : f32, y : vec4<f32>) -> f32 {\n  var s : S; s.a = x + " + k + ".0; s.b = y * 0.5 + vec4<f32>(" + n + ".0);\n  var acc = 0.0;\n"
             "  for (var j = 0u; j < 8u; j++) { s.c[j & 3u] = j * " + n + "u; if (j % 2u == 0u) { acc += s.a * f32(s.c[j & 3u]); } else { acc -= dot(s.b, vec4<f32>(acc)); } }\n"
             "  return select(acc, -acc, acc < 0.0) + sin(x) * cos(s.b.x);\n}\n";
    }
    s += "@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g : vec3<u32>) {\n  var v = f32(g.x); let y = vec4<f32>(v, 1.0, 2.0, 3.0);\n";
    for (int i = 0; i < funcs; i += 4) s += "  v += f" + std::to_string(i) + "(v, y);\n";
    s += "  d[g.x] = v;\n}\n"; return s;
}

int main(int argc, char **argv) {
#if defined(__COSMOPOLITAN__)
    ShowCrashReports(); win_shield_install();
#endif
    if (const char *e = getenv("BENCH_SCALE")) g_scale = atof(e) > 0 ? atof(e) : 1.0;
    bool hostOnly = argc > 1 && !strcmp(argv[1], "--host-only");
    auto tProc = Clock::now();
    host_baselines();
    if (hostOnly) return 0;

    auto t = Clock::now();
    WGPUInstanceDescriptor id = WGPU_INSTANCE_DESCRIPTOR_INIT; g_inst = wgpuCreateInstance(&id);
    if (!g_inst) { puts("FAIL create instance"); return 1; }
    bench("start_instance_ms", ms_since(t), "ms");
    t = Clock::now();
    WGPURequestAdapterOptions ao = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    if (const char *be = getenv("WGT_BACKEND")) ao.backendType = !strcmp(be, "vulkan") ? WGPUBackendType_Vulkan : !strcmp(be, "d3d12") ? WGPUBackendType_D3D12 : !strcmp(be, "metal") ? WGPUBackendType_Metal : WGPUBackendType_Undefined;
    if (getenv("WGT_FALLBACK")) ao.forceFallbackAdapter = 1;
    ao.powerPreference = WGPUPowerPreference_HighPerformance;
    WGPURequestAdapterCallbackInfo aci = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT; aci.mode = WGPUCallbackMode_AllowProcessEvents; aci.callback = on_adapter;
    g_done = 0; wgpuInstanceRequestAdapter(g_inst, &ao, aci); pump();
    if (!g_adapter) { puts("FAIL no adapter"); return 2; }
    bench("start_adapter_ms", ms_since(t), "ms");
    WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT; wgpuAdapterGetInfo(g_adapter, &info);
    bool software = info.adapterType == WGPUAdapterType_CPU;
    printf("adapter: backend=%d type=%d device=%s\n", (int)info.backendType, (int)info.adapterType, sv(info.device).c_str());
    t = Clock::now();
    WGPUDeviceDescriptor dd = WGPU_DEVICE_DESCRIPTOR_INIT; WGPURequestDeviceCallbackInfo dci = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
    dci.mode = WGPUCallbackMode_AllowProcessEvents; dci.callback = on_device; g_done = 0; wgpuAdapterRequestDevice(g_adapter, &dd, dci); pump();
    if (!g_device) { puts("FAIL no device"); return 3; }
    bench("start_device_ms", ms_since(t), "ms");
    WGPUDevice dev = g_device; WGPUQueue q = wgpuDeviceGetQueue(dev);

    // ---- shader front end (Tint) and pipeline creation (backend compiler)
    {
        std::vector<double> mod; const int reps = scaled(6);
        for (int i = 0; i < reps; i++) { std::string w = big_wgsl(160, i); auto t0 = Clock::now(); WGPUShaderModule m = make_module(dev, w); mod.push_back(ms_since(t0)); wgpuShaderModuleRelease(m); }
        bench("shader_module_160fn_ms", median(mod), "ms");
        std::vector<double> pip;
        for (int i = 0; i < scaled(5); i++) { std::string w = big_wgsl(12, 100 + i); auto t0 = Clock::now(); WGPUShaderModule m = make_module(dev, w); WGPUComputePipeline p = make_pipeline(dev, m); pip.push_back(ms_since(t0)); wgpuComputePipelineRelease(p); wgpuShaderModuleRelease(m); }
        bench("shader_pipeline_12fn_ms", median(pip), "ms");
    }

    // ---- common objects
    const char *tiny = "@group(0) @binding(0) var<storage, read_write> d : array<u32>;\n@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g : vec3<u32>) { d[g.x] = g.x * g.x + 7u; }\n";
    WGPUShaderModule sm = make_module(dev, tiny); WGPUComputePipeline pipe = make_pipeline(dev, sm);
    WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT; bd.size = 4096; bd.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc;
    WGPUBuffer sb = wgpuDeviceCreateBuffer(dev, &bd);
    bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst; WGPUBuffer rb = wgpuDeviceCreateBuffer(dev, &bd);
    WGPUBindGroupEntry be = WGPU_BIND_GROUP_ENTRY_INIT; be.binding = 0; be.buffer = sb; be.size = 4096;
    WGPUBindGroupDescriptor bgd = WGPU_BIND_GROUP_DESCRIPTOR_INIT; bgd.layout = wgpuComputePipelineGetBindGroupLayout(pipe, 0); bgd.entryCount = 1; bgd.entries = &be;
    WGPUBindGroup bg = wgpuDeviceCreateBindGroup(dev, &bgd);

    // ---- resource creation
    {
        const int n = scaled(4000); WGPUBufferDescriptor b = WGPU_BUFFER_DESCRIPTOR_INIT; b.size = 65536; b.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst;
        auto t0 = Clock::now(); for (int i = 0; i < n; i++) { WGPUBuffer x = wgpuDeviceCreateBuffer(dev, &b); wgpuBufferRelease(x); }
        bench("buffer_create_release_us", ms_since(t0) * 1e3 / n, "us/op");
        const int m = scaled(1500); t0 = Clock::now();
        for (int i = 0; i < m; i++) { WGPUBindGroup x = wgpuDeviceCreateBindGroup(dev, &bgd); wgpuBindGroupRelease(x); }
        bench("bindgroup_create_release_us", ms_since(t0) * 1e3 / m, "us/op");
    }
    // ---- command recording only (no submit): Dawn's validation + backend encoding
    {
        std::vector<double> v; const int reps = scaled(300);
        for (int i = 0; i < reps; i++) {
            auto t0 = Clock::now();
            WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(dev, &ed);
            WGPUComputePassDescriptor pd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT; WGPUComputePassEncoder cp = wgpuCommandEncoderBeginComputePass(e, &pd);
            wgpuComputePassEncoderSetPipeline(cp, pipe);
            for (int k = 0; k < 64; k++) { wgpuComputePassEncoderSetBindGroup(cp, 0, bg, 0, nullptr); wgpuComputePassEncoderDispatchWorkgroups(cp, 1, 1, 1); }
            wgpuComputePassEncoderEnd(cp);
            WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cbd);
            v.push_back(ms_since(t0) * 1e3);
            wgpuCommandBufferRelease(cb); wgpuComputePassEncoderRelease(cp); wgpuCommandEncoderRelease(e);
        }
        bench("encode_64dispatch_us", median(v), "us");
    }
    // ---- submit + wait + readback round trip
    auto roundtrip = [&](uint32_t groups) -> double {
        WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(dev, &ed);
        WGPUComputePassDescriptor pd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT; WGPUComputePassEncoder cp = wgpuCommandEncoderBeginComputePass(e, &pd);
        wgpuComputePassEncoderSetPipeline(cp, pipe); wgpuComputePassEncoderSetBindGroup(cp, 0, bg, 0, nullptr); wgpuComputePassEncoderDispatchWorkgroups(cp, groups, 1, 1); wgpuComputePassEncoderEnd(cp);
        wgpuCommandEncoderCopyBufferToBuffer(e, sb, 0, rb, 0, 256);
        WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cbd);
        auto t0 = Clock::now(); wgpuQueueSubmit(q, 1, &cb);
        WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT; mi.mode = WGPUCallbackMode_AllowProcessEvents; mi.callback = on_map;
        g_done = 0; wgpuBufferMapAsync(rb, WGPUMapMode_Read, 0, 256, mi); bool ok = pump(); double r = ms_since(t0) * 1e3;
        if (!ok || g_status != WGPUMapAsyncStatus_Success) return -1;
        wgpuBufferUnmap(rb); wgpuCommandBufferRelease(cb); wgpuComputePassEncoderRelease(cp); wgpuCommandEncoderRelease(e); return r;
    };
    {
        for (int i = 0; i < 5; i++) roundtrip(4);   // warm-up
        std::vector<double> v; const int reps = scaled(400);
        for (int i = 0; i < reps; i++) { double r = roundtrip(4); if (r < 0) { puts("FAIL roundtrip"); return 4; } v.push_back(r); }
        bench("submit_map_roundtrip_us", median(v), "us");
    }
    // ---- upload and readback bandwidth
    {
        const uint64_t sz = software ? (8u << 20) : (64u << 20); WGPUBufferDescriptor b = WGPU_BUFFER_DESCRIPTOR_INIT; b.size = sz; b.usage = WGPUBufferUsage_CopyDst | WGPUBufferUsage_CopySrc;
        WGPUBuffer big = wgpuDeviceCreateBuffer(dev, &b); WGPUBufferDescriptor rbd = WGPU_BUFFER_DESCRIPTOR_INIT; rbd.size = sz; rbd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
        WGPUBuffer big_rb = wgpuDeviceCreateBuffer(dev, &rbd); std::vector<uint8_t> host(sz, 3);
        double bestUp = 1e30, bestDown = 1e30;
        for (int r = 0; r < scaled(5) + 1; r++) {
            auto t0 = Clock::now(); wgpuQueueWriteBuffer(q, big, 0, host.data(), sz);
            WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(dev, &ed);
            wgpuCommandEncoderCopyBufferToBuffer(e, big, 0, big_rb, 0, 256); WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cbd);
            wgpuQueueSubmit(q, 1, &cb);
            WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT; mi.mode = WGPUCallbackMode_AllowProcessEvents; mi.callback = on_map;
            g_done = 0; wgpuBufferMapAsync(big_rb, WGPUMapMode_Read, 0, 256, mi); pump(); wgpuBufferUnmap(big_rb);
            double up = ms_since(t0); if (r > 0 && up < bestUp) bestUp = up;
            wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(e);
            // read the whole buffer back
            e = wgpuDeviceCreateCommandEncoder(dev, &ed); wgpuCommandEncoderCopyBufferToBuffer(e, big, 0, big_rb, 0, sz); cb = wgpuCommandEncoderFinish(e, &cbd);
            t0 = Clock::now(); wgpuQueueSubmit(q, 1, &cb); g_done = 0; wgpuBufferMapAsync(big_rb, WGPUMapMode_Read, 0, sz, mi); pump();
            const void *p = wgpuBufferGetConstMappedRange(big_rb, 0, sz); if (p) memcpy(host.data(), p, sz);
            double down = ms_since(t0); if (r > 0 && down < bestDown) bestDown = down;
            wgpuBufferUnmap(big_rb); wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(e);
        }
        bench("upload_MBps", sz / (bestUp / 1e3) / 1e6, "MB/s"); bench("readback_MBps", sz / (bestDown / 1e3) / 1e6, "MB/s");
        wgpuBufferRelease(big); wgpuBufferRelease(big_rb);
    }
    // ---- GPU ALU kernel
    {
        const unsigned iters = 256;
        std::string wgsl = "@group(0) @binding(0) var<storage, read_write> d : array<f32>;\n@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g : vec3<u32>) {\n"
                           "  var a = f32(g.x) * 0.001; var b = 1.0001;\n  for (var i = 0u; i < " + std::to_string(iters) + "u; i++) { a = fma(a, b, 0.5); b = fma(b, a, 0.25) * 0.5 + 0.9; }\n  d[g.x] = a + b;\n}\n";
        WGPUShaderModule m = make_module(dev, wgsl); WGPUComputePipeline p = make_pipeline(dev, m);
        const uint32_t maxGroups = software ? 4096 : 1u << 18;
        WGPUBufferDescriptor b = WGPU_BUFFER_DESCRIPTOR_INIT; b.size = (uint64_t)maxGroups * 64 * 4; b.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc; WGPUBuffer out = wgpuDeviceCreateBuffer(dev, &b);
        WGPUBindGroupEntry e0 = WGPU_BIND_GROUP_ENTRY_INIT; e0.binding = 0; e0.buffer = out; e0.size = b.size;
        WGPUBindGroupDescriptor g = WGPU_BIND_GROUP_DESCRIPTOR_INIT; g.layout = wgpuComputePipelineGetBindGroupLayout(p, 0); g.entryCount = 1; g.entries = &e0; WGPUBindGroup bg2 = wgpuDeviceCreateBindGroup(dev, &g);
        auto run = [&](uint32_t groups) -> double {
            WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(dev, &ed);
            WGPUComputePassDescriptor pd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT; WGPUComputePassEncoder cp = wgpuCommandEncoderBeginComputePass(e, &pd);
            wgpuComputePassEncoderSetPipeline(cp, p); wgpuComputePassEncoderSetBindGroup(cp, 0, bg2, 0, nullptr); wgpuComputePassEncoderDispatchWorkgroups(cp, groups, 1, 1); wgpuComputePassEncoderEnd(cp);
            wgpuCommandEncoderCopyBufferToBuffer(e, out, 0, rb, 0, 256);
            WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cbd);
            auto t0 = Clock::now(); wgpuQueueSubmit(q, 1, &cb);
            WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT; mi.mode = WGPUCallbackMode_AllowProcessEvents; mi.callback = on_map;
            g_done = 0; wgpuBufferMapAsync(rb, WGPUMapMode_Read, 0, 256, mi); bool ok = pump(); double r = ms_since(t0);
            if (!ok || g_status != WGPUMapAsyncStatus_Success) return -1;
            wgpuBufferUnmap(rb); wgpuCommandBufferRelease(cb); wgpuComputePassEncoderRelease(cp); wgpuCommandEncoderRelease(e); return r; };
        uint32_t groups = software ? 64 : 256; double ms = run(groups); ms = run(groups);
        while (ms >= 0 && ms < 30 && groups < maxGroups) { groups = groups * 4 > maxGroups ? maxGroups : groups * 4; ms = run(groups); }
        double best = 1e30; if (ms >= 0) for (int r = 0; r < 5; r++) { double x = run(groups); if (x >= 0 && x < best) best = x; }
        if (best < 1e29) bench("gpu_alu_GFLOPs", (double)groups * 64 * iters * 6 / (best / 1e3) / 1e9, "GFLOP/s");
    }
    bench("process_total_ms", ms_since(tProc), "ms");
    return 0;
}
