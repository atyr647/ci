// Host for a WebAssembly game loop: static no_std Wasmtime (precompiled .cwasm) + Dawn (Vulkan / D3D12 / Metal), one Cosmopolitan program.
// usage: game.com [--frames=N] [--cwasm=path]     env: WGT_BACKEND=vulkan|d3d12|metal, GAME_WAV=<file> writes the audio the game produced
// The guest (game/guest/game.c) imports module "celori": a small GPU API (buffers, WGSL shaders, compute and render pipelines, a render target, readback), an input queue and an audio sink.
// Input is scripted here (frame-accurate, no window needed); the audio sink keeps what the game wrote and checks it was silent except where the script asked for a tone.
#define _COSMO_SOURCE 1
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include <cosmo.h>
#include <sys/mman.h>
#include <sys/resource.h>
#define WIN_SHIELD_WRAP_THREADS 1
#include "win_shield.h"
#define AUDIO_FOREIGN 1   // the audio thread may call libasound; the loader machinery comes with the Dawn library
#include "audio_out.h"
#include "window.h"
#include "gamepad.h"
#include <webgpu/webgpu.h>
extern "C" void DawnCosmoGpuThreadEnter();
extern "C" __attribute__((weak)) int vk_icdNegotiateLoaderICDInterfaceVersion(unsigned int *);   // present when the software driver is linked into this file
extern "C" void DawnCosmoForeignInit();
extern "C" void DawnCosmoWarmDriverHeap();

extern "C" {
typedef struct WnEngine WnEngine; typedef struct WnInst WnInst;
typedef int32_t (*WnCb)(void *, WnInst *, uint8_t *, size_t, const uint64_t *, uint64_t *);
WnEngine *wn_engine_new(int32_t mode);
const char *wn_engine_error(const WnEngine *);
int32_t wn_engine_define(WnEngine *, const char *module, const char *name, const char *sig, WnCb cb, void *user);
int32_t wn_engine_load(WnEngine *, const uint8_t *bytes, size_t len);
WnInst *wn_inst_new(const WnEngine *, char *err, size_t errlen);
const char *wn_inst_error(const WnInst *);
int32_t wn_inst_call(WnInst *, const char *name, const uint64_t *args, size_t nargs, uint64_t *res, size_t nres);
uint8_t *wn_inst_memory(WnInst *, size_t *len);
void wn_log(const uint8_t *msg, size_t len) { fwrite(msg, 1, len, stderr); fflush(stderr); }
}

using Clock = std::chrono::steady_clock;
static double ms_since(Clock::time_point t) { return std::chrono::duration<double, std::milli>(Clock::now() - t).count(); }

// ---------------------------------------------------------------- WebGPU
static WGPUInstance g_inst; static WGPUAdapter g_adapter; static WGPUDevice g_device; static WGPUQueue g_queue;
static volatile int g_done; static int g_gpu_errors;
static std::string sv(WGPUStringView s) { return s.data ? std::string(s.data, s.length == WGPU_STRLEN ? strlen(s.data) : s.length) : ""; }
static void on_adapter(WGPURequestAdapterStatus s, WGPUAdapter a, WGPUStringView m, void *, void *) { g_adapter = a; if (!a) printf("adapter request failed (status %d): %s\n", (int)s, sv(m).c_str()); g_done = 1; }
static void on_device(WGPURequestDeviceStatus s, WGPUDevice d, WGPUStringView m, void *, void *) { g_device = d; if (!d) printf("device request failed (status %d): %s\n", (int)s, sv(m).c_str()); g_done = 1; }
static void on_map(WGPUMapAsyncStatus, WGPUStringView, void *, void *) { g_done = 1; }
static void on_error(const WGPUDevice *, WGPUErrorType t, WGPUStringView m, void *, void *) { g_gpu_errors++; printf("GPU error (type %d): %s\n", (int)t, sv(m).c_str()); }
static bool pump(double limit_ms = 30000) { auto t = Clock::now(); while (!g_done) { wgpuInstanceProcessEvents(g_inst); if (ms_since(t) > limit_ms) return false; std::this_thread::yield(); } return true; }

struct Buf { WGPUBuffer b; uint64_t size; };
struct Target { WGPUTexture tex; WGPUTextureView view; int w, h; };
static std::vector<WGPUShaderModule> g_shaders; static std::vector<Buf> g_bufs; static std::vector<WGPUComputePipeline> g_cpipes; static std::vector<WGPURenderPipeline> g_rpipes; static std::vector<Target> g_targets;
static int g_last_target = -1; static WGPUCommandEncoder g_enc; static uint64_t g_submits, g_dispatches, g_draws;
// GPU timestamp queries (when the adapter has the feature): every compute and render pass writes its start and end; they are resolved at the end of each submission and read once at the end of the run
static const uint32_t kMaxQ = 2048; static const uint64_t kQBytes = 256ull * (kMaxQ / 2);   // (a resolve destination must sit at a multiple of 256 bytes: every submission gets its own 256-byte aligned slot, at most kMaxQ/2 submissions)
static bool g_ts; static WGPUQuerySet g_qs; static WGPUBuffer g_qres, g_qread; static uint32_t g_qn, g_qresolved; static int g_qwork_bad; struct QSeg { uint32_t first, count; uint64_t off; }; static std::vector<QSeg> g_qsegs; static uint64_t g_qoff;
static bool take_ts(WGPUPassTimestampWrites *w) { if (!g_ts || g_qn + 2 > kMaxQ) return false; w->querySet = g_qs; w->beginningOfPassWriteIndex = g_qn; w->endOfPassWriteIndex = g_qn + 1; g_qn += 2; return true; }
static void on_work_done(WGPUQueueWorkDoneStatus s, WGPUStringView, void *, void *) { if (s != WGPUQueueWorkDoneStatus_Success) g_qwork_bad++; g_done = 1; }

static bool gpu_init() {
    puts("host : creating the instance"); WGPUInstanceDescriptor id = WGPU_INSTANCE_DESCRIPTOR_INIT; g_inst = wgpuCreateInstance(&id); if (!g_inst) return false; puts("host : requesting an adapter");
    WGPURequestAdapterOptions ao = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    if (const char *be = getenv("WGT_BACKEND")) ao.backendType = !strcmp(be, "vulkan") ? WGPUBackendType_Vulkan : !strcmp(be, "d3d12") ? WGPUBackendType_D3D12 : !strcmp(be, "metal") ? WGPUBackendType_Metal : WGPUBackendType_Undefined;
    if (getenv("WGT_FALLBACK")) ao.forceFallbackAdapter = 1;
    ao.powerPreference = WGPUPowerPreference_HighPerformance;
    WGPURequestAdapterCallbackInfo aci = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT; aci.mode = WGPUCallbackMode_AllowProcessEvents; aci.callback = on_adapter;
    g_done = 0; wgpuInstanceRequestAdapter(g_inst, &ao, aci); pump(); if (!g_adapter) return false;
    WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT; wgpuAdapterGetInfo(g_adapter, &info);
    printf("host : adapter backend=%d type=%d device=%s\n", (int)info.backendType, (int)info.adapterType, sv(info.device).c_str());
    WGPUDeviceDescriptor dd = WGPU_DEVICE_DESCRIPTOR_INIT; dd.uncapturedErrorCallbackInfo.callback = on_error;
    WGPUFeatureName feat = WGPUFeatureName_TimestampQuery; const bool has_ts = wgpuAdapterHasFeature(g_adapter, feat) && !getenv("GAME_NO_TIMESTAMPS");
    if (has_ts) { dd.requiredFeatureCount = 1; dd.requiredFeatures = &feat; }
    static const char *k_off[] = {"timestamp_quantization"}; WGPUDawnTogglesDescriptor tg = WGPU_DAWN_TOGGLES_DESCRIPTOR_INIT; tg.disabledToggleCount = 1; tg.disabledToggles = k_off; dd.nextInChain = &tg.chain;   // Dawn rounds timestamps to 100 us unless told not to
    WGPURequestDeviceCallbackInfo dci = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT; dci.mode = WGPUCallbackMode_AllowProcessEvents; dci.callback = on_device;
    g_done = 0; wgpuAdapterRequestDevice(g_adapter, &dd, dci); pump(); if (!g_device) return false;
    g_queue = wgpuDeviceGetQueue(g_device);
    if (has_ts) {
        WGPUQuerySetDescriptor qd = WGPU_QUERY_SET_DESCRIPTOR_INIT; qd.type = WGPUQueryType_Timestamp; qd.count = kMaxQ; g_qs = wgpuDeviceCreateQuerySet(g_device, &qd);
        WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT; bd.size = kQBytes; bd.usage = WGPUBufferUsage_QueryResolve | WGPUBufferUsage_CopySrc; g_qres = wgpuDeviceCreateBuffer(g_device, &bd);
        bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst; g_qread = wgpuDeviceCreateBuffer(g_device, &bd); g_ts = g_qs && g_qres && g_qread;
    }
    printf("host : GPU timestamp queries %s\n", g_ts ? "enabled" : has_ts ? "failed to set up" : "not supported by this adapter");
    return true;
}

#define CB(n) static int32_t n(void *, WnInst *, uint8_t *mem, size_t memlen, const uint64_t *a, uint64_t *r)
#define OK(p, n) ((uint64_t)(uint32_t)(p) + (uint32_t)(n) <= memlen)
static WGPUBindGroup make_bg(WGPUBindGroupLayout layout, const int *ids, int n) {
    WGPUBindGroupEntry e[3]; int k = 0;
    for (int i = 0; i < n; i++) if (ids[i] >= 0 && ids[i] < (int)g_bufs.size()) { e[k] = WGPU_BIND_GROUP_ENTRY_INIT; e[k].binding = (uint32_t)i; e[k].buffer = g_bufs[ids[i]].b; e[k].offset = 0; e[k].size = g_bufs[ids[i]].size; k++; }
    WGPUBindGroupDescriptor d = WGPU_BIND_GROUP_DESCRIPTOR_INIT; d.layout = layout; d.entryCount = (size_t)k; d.entries = e; return wgpuDeviceCreateBindGroup(g_device, &d);
}
CB(gpu_shader) { uint32_t p = (uint32_t)a[0], n = (uint32_t)a[1]; if (!OK(p, n)) { r[0] = (uint64_t)-1; return 0; }
    WGPUShaderSourceWGSL w = WGPU_SHADER_SOURCE_WGSL_INIT; w.code = {(const char *)mem + p, n}; WGPUShaderModuleDescriptor d = WGPU_SHADER_MODULE_DESCRIPTOR_INIT; d.nextInChain = &w.chain;
    g_shaders.push_back(wgpuDeviceCreateShaderModule(g_device, &d)); r[0] = (uint32_t)(g_shaders.size() - 1); return 0; }
CB(gpu_buffer) { uint64_t size = (a[0] + 3) & ~3ull; uint32_t flags = (uint32_t)a[1]; WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT; d.size = size;
    d.usage = WGPUBufferUsage_CopyDst | WGPUBufferUsage_CopySrc | ((flags & 1) ? WGPUBufferUsage_Storage : 0) | ((flags & 2) ? WGPUBufferUsage_Uniform : 0);
    g_bufs.push_back({wgpuDeviceCreateBuffer(g_device, &d), size}); r[0] = (uint32_t)(g_bufs.size() - 1); return 0; }
CB(gpu_write) { uint32_t b = (uint32_t)a[0], off = (uint32_t)a[1], p = (uint32_t)a[2], n = (uint32_t)a[3]; if (b >= g_bufs.size() || !OK(p, n)) return 1; wgpuQueueWriteBuffer(g_queue, g_bufs[b].b, off, mem + p, n); return 0; }
CB(gpu_compute_pipeline) { uint32_t s = (uint32_t)a[0], p = (uint32_t)a[1], n = (uint32_t)a[2]; if (s >= g_shaders.size() || !OK(p, n)) { r[0] = (uint64_t)-1; return 0; }
    WGPUComputePipelineDescriptor c = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT; c.compute.module = g_shaders[s]; c.compute.entryPoint = {(const char *)mem + p, n};
    g_cpipes.push_back(wgpuDeviceCreateComputePipeline(g_device, &c)); r[0] = (uint32_t)(g_cpipes.size() - 1); return 0; }
CB(gpu_render_pipeline) { uint32_t s = (uint32_t)a[0], vp = (uint32_t)a[1], vn = (uint32_t)a[2], fp = (uint32_t)a[3], fn = (uint32_t)a[4]; if (s >= g_shaders.size() || !OK(vp, vn) || !OK(fp, fn)) { r[0] = (uint64_t)-1; return 0; }
    WGPUColorTargetState ct = WGPU_COLOR_TARGET_STATE_INIT; ct.format = WGPUTextureFormat_RGBA8Unorm;
    WGPUFragmentState fs = WGPU_FRAGMENT_STATE_INIT; fs.module = g_shaders[s]; fs.entryPoint = {(const char *)mem + fp, fn}; fs.targetCount = 1; fs.targets = &ct;
    WGPURenderPipelineDescriptor d = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT; d.vertex.module = g_shaders[s]; d.vertex.entryPoint = {(const char *)mem + vp, vn}; d.fragment = &fs;
    g_rpipes.push_back(wgpuDeviceCreateRenderPipeline(g_device, &d)); r[0] = (uint32_t)(g_rpipes.size() - 1); return 0; }
CB(gpu_target) { Target t; t.w = (int)a[0]; t.h = (int)a[1]; WGPUTextureDescriptor d = WGPU_TEXTURE_DESCRIPTOR_INIT; d.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc | WGPUTextureUsage_TextureBinding;
    d.size = {(uint32_t)t.w, (uint32_t)t.h, 1}; d.format = WGPUTextureFormat_RGBA8Unorm; t.tex = wgpuDeviceCreateTexture(g_device, &d); t.view = wgpuTextureCreateView(t.tex, nullptr);
    g_targets.push_back(t); r[0] = (uint32_t)(g_targets.size() - 1); return 0; }
CB(gpu_begin) { WGPUCommandEncoderDescriptor d = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; g_enc = wgpuDeviceCreateCommandEncoder(g_device, &d); return 0; }
CB(gpu_end) { if (g_ts && g_qn > g_qresolved) { uint32_t n = g_qn - g_qresolved; uint64_t off = (g_qoff + 255) & ~255ull; wgpuCommandEncoderResolveQuerySet(g_enc, g_qs, g_qresolved, n, g_qres, off);
        wgpuCommandEncoderCopyBufferToBuffer(g_enc, g_qres, off, g_qread, off, (uint64_t)n * 8); g_qsegs.push_back({g_qresolved, n, off}); g_qoff = off + (uint64_t)n * 8; g_qresolved = g_qn; }
    WGPUCommandBufferDescriptor d = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(g_enc, &d); wgpuQueueSubmit(g_queue, 1, &cb); wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(g_enc); g_enc = nullptr; g_submits++; return 0; }
CB(gpu_dispatch) { uint32_t p = (uint32_t)a[0]; int ids[3] = {(int)a[1], (int)a[2], (int)a[3]}; uint32_t groups = (uint32_t)a[4]; if (p >= g_cpipes.size() || !g_enc) return 1;
    WGPUBindGroupLayout l = wgpuComputePipelineGetBindGroupLayout(g_cpipes[p], 0); WGPUBindGroup bg = make_bg(l, ids, 3);
    WGPUComputePassDescriptor pd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT; WGPUPassTimestampWrites tw = WGPU_PASS_TIMESTAMP_WRITES_INIT; if (take_ts(&tw)) pd.timestampWrites = &tw; WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(g_enc, &pd);
    wgpuComputePassEncoderSetPipeline(pass, g_cpipes[p]); wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, nullptr); wgpuComputePassEncoderDispatchWorkgroups(pass, groups, 1, 1); wgpuComputePassEncoderEnd(pass);
    wgpuComputePassEncoderRelease(pass); wgpuBindGroupRelease(bg); wgpuBindGroupLayoutRelease(l); g_dispatches++; return 0; }
CB(gpu_draw) { g_last_target = (int)a[3]; uint32_t p = (uint32_t)a[0]; int ids[3] = {(int)a[1], (int)a[2], -1}; uint32_t t = (uint32_t)a[3], verts = (uint32_t)a[4], inst = (uint32_t)a[5], clear = (uint32_t)a[6]; if (p >= g_rpipes.size() || t >= g_targets.size() || !g_enc) return 1;
    WGPUBindGroupLayout l = wgpuRenderPipelineGetBindGroupLayout(g_rpipes[p], 0); WGPUBindGroup bg = make_bg(l, ids, 3);
    WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT; ca.view = g_targets[t].view; ca.loadOp = WGPULoadOp_Clear; ca.storeOp = WGPUStoreOp_Store;
    ca.clearValue = {(clear & 255) / 255.0, ((clear >> 8) & 255) / 255.0, ((clear >> 16) & 255) / 255.0, ((clear >> 24) & 255) / 255.0};
    WGPURenderPassDescriptor rd = WGPU_RENDER_PASS_DESCRIPTOR_INIT; rd.colorAttachmentCount = 1; rd.colorAttachments = &ca; WGPUPassTimestampWrites tw = WGPU_PASS_TIMESTAMP_WRITES_INIT; if (take_ts(&tw)) rd.timestampWrites = &tw; WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(g_enc, &rd);
    wgpuRenderPassEncoderSetPipeline(pass, g_rpipes[p]); wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, nullptr); wgpuRenderPassEncoderDraw(pass, verts, inst, 0, 0); wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass); wgpuBindGroupRelease(bg); wgpuBindGroupLayoutRelease(l); g_draws++; return 0; }
static bool map_read(WGPUBuffer b, uint64_t size, const void **out) {
    WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT; mi.mode = WGPUCallbackMode_AllowProcessEvents; mi.callback = on_map; g_done = 0;
    wgpuBufferMapAsync(b, WGPUMapMode_Read, 0, size, mi); if (!pump()) return false; *out = wgpuBufferGetConstMappedRange(b, 0, size); return *out != nullptr;
}
CB(gpu_read) { uint32_t b = (uint32_t)a[0], off = (uint32_t)a[1], p = (uint32_t)a[2], n = (uint32_t)a[3]; if (b >= g_bufs.size() || !OK(p, n) || (n & 3) || (off & 3)) return 1;
    WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT; d.size = n; d.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst; WGPUBuffer st = wgpuDeviceCreateBuffer(g_device, &d);
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(g_device, &ed); wgpuCommandEncoderCopyBufferToBuffer(e, g_bufs[b].b, off, st, 0, n);
    WGPUCommandBufferDescriptor cd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cd); wgpuQueueSubmit(g_queue, 1, &cb); wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(e);
    const void *m = nullptr; int rc = 1; if (map_read(st, n, &m)) { memcpy(mem + p, m, n); rc = 0; } wgpuBufferUnmap(st); wgpuBufferRelease(st); return rc; }
CB(gpu_read_target) { uint32_t t = (uint32_t)a[0], p = (uint32_t)a[1], n = (uint32_t)a[2]; if (t >= g_targets.size()) return 1; const Target &T = g_targets[t];
    uint32_t bpr = ((uint32_t)T.w * 4 + 255) & ~255u; if (!OK(p, n) || n < (uint32_t)T.w * T.h * 4) return 1;
    WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT; d.size = (uint64_t)bpr * T.h; d.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst; WGPUBuffer st = wgpuDeviceCreateBuffer(g_device, &d);
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(g_device, &ed);
    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT; src.texture = T.tex; WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT; dst.buffer = st; dst.layout.bytesPerRow = bpr; dst.layout.rowsPerImage = (uint32_t)T.h;
    WGPUExtent3D ext = {(uint32_t)T.w, (uint32_t)T.h, 1}; wgpuCommandEncoderCopyTextureToBuffer(e, &src, &dst, &ext);
    WGPUCommandBufferDescriptor cd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cd); wgpuQueueSubmit(g_queue, 1, &cb); wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(e);
    const uint8_t *m = nullptr; int rc = 1; if (map_read(st, d.size, (const void **)&m)) { for (int y = 0; y < T.h; y++) memcpy(mem + p + (size_t)y * T.w * 4, m + (size_t)y * bpr, (size_t)T.w * 4); rc = 0; } wgpuBufferUnmap(st); wgpuBufferRelease(st); return rc; }


// the last rendered target as 4 bytes per pixel (R,G,B,A), top row first, for the window
static bool read_target_host(int t, std::vector<uint8_t> &out) {
    if (t < 0 || t >= (int)g_targets.size()) return false; const Target &T = g_targets[t]; uint32_t bpr = ((uint32_t)T.w * 4 + 255) & ~255u;
    WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT; d.size = (uint64_t)bpr * T.h; d.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst; WGPUBuffer st = wgpuDeviceCreateBuffer(g_device, &d);
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(g_device, &ed);
    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT; src.texture = T.tex; WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT; dst.buffer = st; dst.layout.bytesPerRow = bpr; dst.layout.rowsPerImage = (uint32_t)T.h;
    WGPUExtent3D ext = {(uint32_t)T.w, (uint32_t)T.h, 1}; wgpuCommandEncoderCopyTextureToBuffer(e, &src, &dst, &ext);
    WGPUCommandBufferDescriptor cd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cd); wgpuQueueSubmit(g_queue, 1, &cb); wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(e);
    const uint8_t *m = nullptr; bool ok = map_read(st, d.size, (const void **)&m); if (ok) { out.resize((size_t)T.w * T.h * 4); for (int y = 0; y < T.h; y++) memcpy(&out[(size_t)y * T.w * 4], m + (size_t)y * bpr, (size_t)T.w * 4); }
    wgpuBufferUnmap(st); wgpuBufferRelease(st); return ok;
}

// ---- presentation through a GPU swapchain (Dawn surface on the window's HWND or CAMetalLayer): the rendered target is drawn into the swapchain texture by a full-screen triangle, no copy through the CPU
struct SwapPresenter {
    WGPUSurface surf = nullptr; WGPURenderPipeline pipe = nullptr; WGPUSampler samp = nullptr; WGPUTextureFormat fmt = WGPUTextureFormat_Undefined; std::string note; int fails = 0; uint64_t frames = 0;
    bool init(void *hwnd, void *hinst, void *layer, int width, int height) {
        WGPUSurfaceDescriptor sd = WGPU_SURFACE_DESCRIPTOR_INIT; WGPUSurfaceSourceWindowsHWND sh = WGPU_SURFACE_SOURCE_WINDOWS_HWND_INIT; WGPUSurfaceSourceMetalLayer sm = WGPU_SURFACE_SOURCE_METAL_LAYER_INIT;
        if (IsWindows() && hwnd) { sh.hwnd = hwnd; sh.hinstance = hinst; sd.nextInChain = &sh.chain; } else if (IsXnu() && layer) { sm.layer = layer; sd.nextInChain = &sm.chain; } else { note = "no native window handle for a swapchain on this system"; return false; }
        surf = wgpuInstanceCreateSurface(g_inst, &sd); if (!surf) { note = "wgpuInstanceCreateSurface returned nothing"; return false; }
        WGPUSurfaceCapabilities caps = WGPU_SURFACE_CAPABILITIES_INIT; if (wgpuSurfaceGetCapabilities(surf, g_adapter, &caps) != WGPUStatus_Success || !caps.formatCount) { note = "the adapter cannot present to this surface"; return false; }
        fmt = caps.formats[0]; for (size_t i = 0; i < caps.formatCount; i++) if (caps.formats[i] == WGPUTextureFormat_BGRA8Unorm) fmt = caps.formats[i];
        WGPUPresentMode pm = caps.presentModes[0]; for (size_t i = 0; i < caps.presentModeCount; i++) if (caps.presentModes[i] == WGPUPresentMode_Immediate) pm = caps.presentModes[i];   // (no wait for the display's refresh: what is measured is the work, not the vsync)
        char nm[160]; snprintf(nm, sizeof nm, "swapchain format %d, present mode %d, %dx%d", (int)fmt, (int)pm, width, height); note = nm; wgpuSurfaceCapabilitiesFreeMembers(caps);
        WGPUSurfaceConfiguration cfg = WGPU_SURFACE_CONFIGURATION_INIT; cfg.device = g_device; cfg.format = fmt; cfg.usage = WGPUTextureUsage_RenderAttachment; cfg.width = (uint32_t)width; cfg.height = (uint32_t)height; cfg.presentMode = pm; wgpuSurfaceConfigure(surf, &cfg);
        static const char *wgsl = "@group(0) @binding(0) var t: texture_2d<f32>;\n@group(0) @binding(1) var s: sampler;\nstruct VOut { @builtin(position) p: vec4f, @location(0) uv: vec2f };\n"
            "@vertex fn vs(@builtin(vertex_index) i: u32) -> VOut { var pos = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0)); let p = pos[i]; var o: VOut; o.p = vec4f(p, 0.0, 1.0); o.uv = vec2f((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5); return o; }\n"
            "@fragment fn fs(@location(0) uv: vec2f) -> @location(0) vec4f { return textureSample(t, s, uv); }\n";
        WGPUShaderSourceWGSL w = WGPU_SHADER_SOURCE_WGSL_INIT; w.code = {wgsl, WGPU_STRLEN}; WGPUShaderModuleDescriptor md = WGPU_SHADER_MODULE_DESCRIPTOR_INIT; md.nextInChain = &w.chain; WGPUShaderModule m = wgpuDeviceCreateShaderModule(g_device, &md);
        WGPUColorTargetState ct = WGPU_COLOR_TARGET_STATE_INIT; ct.format = fmt; WGPUFragmentState fs = WGPU_FRAGMENT_STATE_INIT; fs.module = m; fs.entryPoint = {"fs", WGPU_STRLEN}; fs.targetCount = 1; fs.targets = &ct;
        WGPURenderPipelineDescriptor rd = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT; rd.vertex.module = m; rd.vertex.entryPoint = {"vs", WGPU_STRLEN}; rd.fragment = &fs; pipe = wgpuDeviceCreateRenderPipeline(g_device, &rd);
        WGPUSamplerDescriptor sdsc = WGPU_SAMPLER_DESCRIPTOR_INIT; samp = wgpuDeviceCreateSampler(g_device, &sdsc);
        if (!pipe || !samp) { note = "the presentation pipeline could not be made"; return false; } return true;
    }
    bool present(int target) {
        if (target < 0 || target >= (int)g_targets.size()) return false;
        WGPUSurfaceTexture st = WGPU_SURFACE_TEXTURE_INIT; wgpuSurfaceGetCurrentTexture(surf, &st);
        if (st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal && st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) { fails++; return false; }
        WGPUTextureView v = wgpuTextureCreateView(st.texture, nullptr); WGPUBindGroupLayout l = wgpuRenderPipelineGetBindGroupLayout(pipe, 0);
        WGPUBindGroupEntry e[2] = {WGPU_BIND_GROUP_ENTRY_INIT, WGPU_BIND_GROUP_ENTRY_INIT}; e[0].binding = 0; e[0].textureView = g_targets[target].view; e[1].binding = 1; e[1].sampler = samp;
        WGPUBindGroupDescriptor bd = WGPU_BIND_GROUP_DESCRIPTOR_INIT; bd.layout = l; bd.entryCount = 2; bd.entries = e; WGPUBindGroup bg = wgpuDeviceCreateBindGroup(g_device, &bd);
        WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g_device, &ed);
        WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT; ca.view = v; ca.loadOp = WGPULoadOp_Clear; ca.storeOp = WGPUStoreOp_Store; ca.clearValue = {0, 0, 0, 1};
        WGPURenderPassDescriptor rp = WGPU_RENDER_PASS_DESCRIPTOR_INIT; rp.colorAttachmentCount = 1; rp.colorAttachments = &ca; WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(enc, &rp);
        wgpuRenderPassEncoderSetPipeline(pass, pipe); wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, nullptr); wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0); wgpuRenderPassEncoderEnd(pass);
        WGPUCommandBufferDescriptor cd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cd); wgpuQueueSubmit(g_queue, 1, &cb); wgpuCommandBufferRelease(cb);
        wgpuRenderPassEncoderRelease(pass); wgpuCommandEncoderRelease(enc); wgpuBindGroupRelease(bg); wgpuBindGroupLayoutRelease(l); wgpuTextureViewRelease(v);
        WGPUStatus ps = wgpuSurfacePresent(surf); wgpuTextureRelease(st.texture); frames++; if (ps != WGPUStatus_Success) { fails++; return false; } return true;
    }
};
// ---------------------------------------------------------------- input and audio
struct Ev { uint32_t type, a, b, frame; };
static std::vector<Ev> g_queue_in; static size_t g_qhead;
static std::vector<int16_t> g_audio; static uint64_t g_audio_frames; static audio::Output g_aout;   // g_aout: the real-time ring and its audio thread (started with --realtime or GAME_AUDIO=...)
CB(input_poll) { uint32_t p = (uint32_t)a[0], mx = (uint32_t)a[1]; size_t n = 0; while (g_qhead < g_queue_in.size() && n < mx) { if (!OK(p + n * 16, 16)) break; memcpy(mem + p + n * 16, &g_queue_in[g_qhead++], 16); n++; } r[0] = n; return 0; }
CB(audio_write) { uint32_t p = (uint32_t)a[0], frames = (uint32_t)a[1]; if (!OK(p, frames * 4)) { r[0] = 0; return 0; } const int16_t *s = (const int16_t *)(mem + p); g_audio.insert(g_audio.end(), s, s + (size_t)frames * 2); g_audio_frames += frames; g_aout.submit(s, frames); r[0] = frames; return 0; }
CB(host_log) { uint32_t p = (uint32_t)a[0], n = (uint32_t)a[1]; if (OK(p, n)) fwrite(mem + p, 1, n, stdout); fflush(stdout); return 0; }

// the scripted input (frame numbers): RIGHT down 10..29, UP down 40..59, FIRE 60, MOUSE (192,64) at 80, RIGHT down 90..99
enum { EV_KEY_DOWN = 1, EV_KEY_UP = 2, EV_MOUSE = 3 }; enum { K_RIGHT = 2, K_UP = 3, K_FIRE = 5 };
static void script(int f) {
    auto add = [&](uint32_t t, uint32_t x, uint32_t y) { g_queue_in.push_back({t, x, y, (uint32_t)f}); };
    if (f == 10) add(EV_KEY_DOWN, K_RIGHT, 0); if (f == 30) add(EV_KEY_UP, K_RIGHT, 0);
    if (f == 40) add(EV_KEY_DOWN, K_UP, 0); if (f == 60) { add(EV_KEY_UP, K_UP, 0); add(EV_KEY_DOWN, K_FIRE, 0); } if (f == 61) add(EV_KEY_UP, K_FIRE, 0);
    if (f == 80) add(EV_MOUSE, 192, 64); if (f == 90) add(EV_KEY_DOWN, K_RIGHT, 0); if (f == 100) add(EV_KEY_UP, K_RIGHT, 0);
}

static uint8_t *read_all(const char *path, size_t *n) { FILE *f = fopen(path, "rb"); if (!f) return nullptr; fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET); uint8_t *b = (uint8_t *)malloc(len);
    if (fread(b, 1, len, f) != (size_t)len) { fclose(f); free(b); return nullptr; } fclose(f); *n = len; return b; }


// Does this system let a program make memory it has just written executable? Wasmtime's native code and the in-file software GPU driver's JIT both need that; hardened systems refuse it
// (systemd MemoryDenyWriteExecute=yes, the kernel's MDWE, macOS hardened runtime without the JIT entitlement, Windows arbitrary-code-guard). The policy is respected, never worked around:
// without it the game runs its wasm on the Pulley interpreter (no machine code is generated) and does not use the in-file software GPU driver.
static bool exec_memory_allowed() {
    void *p = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0); if (p == MAP_FAILED) return false;
#ifdef __x86_64__
    ((uint8_t *)p)[0] = 0xC3;   // ret
#else
    *(uint32_t *)p = 0xD65F03C0;   // ret
#endif
    bool ok = mprotect(p, 4096, PROT_READ | PROT_EXEC) == 0; munmap(p, 4096); return ok;
}

// ---- first-burst page faults of the system driver's heap (experiment, FINDINGS "page-fault cost"): Dawn's frees go to this program's allocator, so the driver's glibc heap starts nearly empty and grows
// (fresh pages, one page fault each) while the first thousands of buffers are created; natively Dawn and the driver share one heap that Dawn already touched. GAME_PREFAULT_KB=N touches N KiB of the driver's heap
// through its own malloc at start-up and keeps it (M_TRIM_THRESHOLD); GAME_BURST=N creates and releases N 64 KiB buffers, reports the page faults and time of that loop, and exits.
static double prefault_driver_heap(long kb) {
    auto t = Clock::now(); const bool populate = getenv("GAME_PREFAULT_POPULATE") != nullptr; void *libc = cosmo_dlopen("libc.so.6", RTLD_NOW); if (!libc || kb <= 0) return 0;
    auto pmallopt = reinterpret_cast<int (*)(int, int)>(cosmo_dltramp(cosmo_dlsym(libc, "mallopt"))); auto pmalloc = reinterpret_cast<void *(*)(unsigned long)>(cosmo_dltramp(cosmo_dlsym(libc, "malloc"))); auto pfree = reinterpret_cast<void (*)(void *)>(cosmo_dltramp(cosmo_dlsym(libc, "free")));
    if (!pmallopt || !pmalloc || !pfree) return 0;
    pmallopt(-1, 1 << 30);   // M_TRIM_THRESHOLD: do not give the memory back when it is freed
    if (populate) {   // blocks of 64 KiB (below glibc's mmap threshold, so they come from the heap), the kernel populates their pages in one call each, then they are freed and stay (trim threshold 64 MiB)
        pmallopt(-1, 64 << 20); std::vector<void *> bl; for (long k = 0; k < kb; k += 64) { void *b = pmalloc(65536 - 32); if (!b) break; bl.push_back(b);
            uintptr_t lo = ((uintptr_t)b + 4095) & ~(uintptr_t)4095, hi = ((uintptr_t)b + 65536 - 32) & ~(uintptr_t)4095; if (madvise((void *)lo, hi - lo, 23 /*MADV_POPULATE_WRITE, Linux 5.14*/)) for (uintptr_t a = lo; a < hi; a += 4096) *(volatile char *)a = 0; }
        for (void *b : bl) pfree(b); return ms_since(t);
    }
    std::vector<void *> blocks; for (long i = 0; i < kb; i++) { void *b = pmalloc(1024); if (!b) break; memset(b, 0, 1024); blocks.push_back(b); }   // malloc and write: calloc would skip the write on fresh heap memory
    for (void *b : blocks) pfree(b);
    return ms_since(t);
}
static void burst(int n) {
    WGPUBufferDescriptor b = WGPU_BUFFER_DESCRIPTOR_INIT; b.size = 65536; b.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopyDst;
    struct rusage r0, r1; getrusage(RUSAGE_SELF, &r0); auto t = Clock::now();
    const int tick = getenv("GAME_BURST_TICK") ? atoi(getenv("GAME_BURST_TICK")) : 0;   // tick the device every N calls, the way frames do in a game
    for (int i = 0; i < n; i++) { WGPUBuffer x = wgpuDeviceCreateBuffer(g_device, &b); wgpuBufferRelease(x); if (tick && i % tick == tick - 1) wgpuDeviceTick(g_device); }
    double ms = ms_since(t); getrusage(RUSAGE_SELF, &r1);
    printf("host : burst of %d buffer create+release: %.3f ms (%.3f us each), %ld page faults (%.3f per call)\n", n, ms, ms * 1e3 / n, r1.ru_minflt - r0.ru_minflt, (double)(r1.ru_minflt - r0.ru_minflt) / n);
}

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0); ShowCrashReports(); win_shield_install();   // a crash prints a report (registers, backtrace) instead of nothing
    // (before Dawn's loader looks at DAWN_COSMO_VK, which it reads once)
    const bool exec_ok = exec_memory_allowed();
    if (!exec_ok && !getenv("DAWN_COSMO_VK")) setenv("DAWN_COSMO_VK", "system", 1);
    DawnCosmoForeignInit(); DawnCosmoGpuThreadEnter();
    int frames = 120; const char *cw = getenv("GAME_CWASM"); bool force_pulley = getenv("GAME_PULLEY") != nullptr;
    for (int i = 1; i < argc; i++) { if (!strncmp(argv[i], "--frames=", 9)) frames = atoi(argv[i] + 9); else if (!strncmp(argv[i], "--cwasm=", 8)) cw = argv[i] + 8; else if (!strcmp(argv[i], "--pulley")) force_pulley = true; }
    bool swapchain = getenv("GAME_SWAPCHAIN") != nullptr; int win_w = 256, win_h = 256;
    for (int i = 1; i < argc; i++) { if (!strcmp(argv[i], "--swapchain")) swapchain = true; else if (!strncmp(argv[i], "--window=", 9)) sscanf(argv[i] + 9, "%dx%d", &win_w, &win_h); }
    bool present = getenv("GAME_PRESENT") != nullptr || swapchain, use_pad = getenv("GAME_GAMEPAD") != nullptr; for (int i = 1; i < argc; i++) { if (!strcmp(argv[i], "--present")) present = true; else if (!strcmp(argv[i], "--gamepad")) use_pad = true; }
    const bool pulley = force_pulley || !exec_ok;
    if (!exec_ok) printf("host : this system refuses executable memory that was written first (a write-xor-execute policy): the wasm runs on the Pulley interpreter and the in-file software GPU driver is not used\n");
    else if (force_pulley) puts("host : Pulley interpreter requested");
    const char *arch = IsAarch64() ? "aarch64" : "x86_64"; char path[256]; if (pulley) snprintf(path, sizeof path, "/zip/game.pulley.cwasm"); else snprintf(path, sizeof path, "/zip/game.sig.%s.cwasm", arch);
    size_t len = 0; uint8_t *bytes = read_all(cw ? cw : path, &len); if (!bytes) bytes = read_all(pulley ? "game.pulley.cwasm" : "game.cwasm", &len); if (!bytes) { fprintf(stderr, "cannot read the game module (%s)\n", cw ? cw : path); return 65; }
    printf("host : platform=%s arch=%s, game module %zu bytes (%s)\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", arch, len, pulley ? "Pulley bytecode" : "native code");
    auto t0 = Clock::now();
    if (!gpu_init()) {
        // A machine can have the Vulkan loader and no driver at all (many desktops, virtual machines, containers with libvulkan1 only): the loader opens, finds no device, and Dawn reports no adapter. The driver inside this file was never tried
        // because it is the fallback for "no loader". Start again in software mode; Dawn reads DAWN_COSMO_VK once, so the process is replaced rather than reconfigured.
        if (IsLinux() && exec_ok && !getenv("DAWN_COSMO_VK") && !getenv("GAME_REEXEC") && vk_icdNegotiateLoaderICDInterfaceVersion) {
            setenv("DAWN_COSMO_VK", "software", 1); setenv("GAME_REEXEC", "1", 1); puts("host : the system has no usable Vulkan device; starting again with the driver inside this file"); fflush(stdout); execv(GetProgramExecutableName(), argv);
        }
        puts("FAIL gpu init"); return 2;
    } printf("host : GPU ready in %.1f ms\n", ms_since(t0));
    if (const char *pk = getenv("GAME_PREFAULT_KB")) { double ms = prefault_driver_heap(atol(pk)); printf("host : pre-faulted %s KiB of the driver's heap in %.2f ms\n", pk, ms); }
    if (const char *bn = getenv("GAME_BURST")) { burst(atoi(bn)); return 0; }
    win::Window window; bool win_on = false; pad::Gamepads pads; bool pad_on = false; std::vector<double> pres_ms; int present_fail = 0, verify_mismatch = -2; bool verify_ok = false;
    SwapPresenter swap; bool swap_on = false;
    if (present) { win_on = window.open(win_w, win_h, "celori"); printf("host : window [%s]: %s\n", window.backend.c_str(), window.note.c_str()); if (!win_on) { puts("FAIL window"); return 12; }
        if (swapchain) { swap_on = swap.init(window.native_window(), window.native_instance(), window.native_window(), win_w, win_h); printf("host : GPU swapchain: %s\n", swap_on ? swap.note.c_str() : ("not used - " + swap.note).c_str()); if (!swap_on) { puts("FAIL swapchain"); return 13; } } }
    if (use_pad) { pad_on = pads.init(); printf("host : gamepads [%s]: %s\n", pads.backend.c_str(), pads.note.c_str()); }
    WnEngine *e = wn_engine_new(pulley ? 2 : 0); if (!e) { puts("FAIL engine"); return 3; }
    int rc = 0;
#define D(n, sg, cb) rc |= wn_engine_define(e, "celori", n, sg, cb, 0)
    D("gpu_shader", "ii>i", gpu_shader); D("gpu_buffer", "ii>i", gpu_buffer); D("gpu_write", "iiii", gpu_write); D("gpu_compute_pipeline", "iii>i", gpu_compute_pipeline);
    D("gpu_render_pipeline", "iiiii>i", gpu_render_pipeline); D("gpu_target", "ii>i", gpu_target); D("gpu_begin", "", gpu_begin); D("gpu_end", "", gpu_end);
    D("gpu_dispatch", "iiiii", gpu_dispatch); D("gpu_draw", "iiiiiii", gpu_draw); D("gpu_read", "iiii", gpu_read); D("gpu_read_target", "iii", gpu_read_target);
    D("input_poll", "ii>i", input_poll); D("audio_write", "ii>i", audio_write); D("host_log", "ii", host_log);
#undef D
    if (rc) { printf("FAIL define imports: %s\n", wn_engine_error(e)); return 4; }
    if (wn_engine_load(e, bytes, len)) { printf("FAIL load: %s\n", wn_engine_error(e)); return 5; }
    char err[512]; WnInst *inst = wn_inst_new(e, err, sizeof err); if (!inst) { printf("FAIL instantiate: %s\n", err); return 6; }
    uint64_t res[2] = {0, 0};
    if (wn_inst_call(inst, "game_init", nullptr, 0, res, 1)) { printf("FAIL game_init: %s\n", wn_inst_error(inst)); return 7; }
    const bool realtime = getenv("GAME_REALTIME") != nullptr || [&] { for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--realtime")) return true; return false; }();
    if (realtime || getenv("GAME_AUDIO")) { if (!g_aout.start(realtime && !getenv("GAME_AUDIO") ? "timed" : nullptr)) { puts("FAIL audio device required but not available"); return 11; } printf("host : audio out [%s]: %s\n", g_aout.st.backend.c_str(), g_aout.st.note.c_str()); }
    if (!getenv("GAME_PREFAULT_KB") && !getenv("GAME_BURST")) DawnCosmoWarmDriverHeap();   // after the guest created its pipelines and buffers, right before the frames: the driver's heap populated at a time that is not in the middle of a frame
    auto tl = Clock::now(); std::vector<double> ft, gt; int bad = 0; double worst_late = 0; int late_frames = 0;
    for (int f = 0; f < frames; f++) {
        if (realtime) {   // 60 frames a second: frame f starts at its time, the last 0.3 ms by spinning
            auto due = tl + std::chrono::nanoseconds((long long)f * 1000000000LL / 60); std::this_thread::sleep_until(due - std::chrono::microseconds(300)); while (Clock::now() < due) {}
            double l = std::chrono::duration<double, std::milli>(Clock::now() - due).count(); if (l > worst_late) worst_late = l; if (l > 1.0) late_frames++;
        }
        script(f); auto t1 = Clock::now(); uint64_t arg[1] = {(uint64_t)f};
        if (wn_inst_call(inst, "game_frame", arg, 1, res, 1)) { printf("FAIL game_frame %d: %s\n", f, wn_inst_error(inst)); return 8; }
        wgpuInstanceProcessEvents(g_inst); ft.push_back(ms_since(t1)); if (res[0]) bad++;
        // then wait for the GPU to finish this frame's work: the time from the end of the submission side to completion (what a game that must not run ahead of the GPU would wait)
        { auto tw = Clock::now(); g_done = 0; WGPUQueueWorkDoneCallbackInfo wi = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT; wi.mode = WGPUCallbackMode_AllowProcessEvents; wi.callback = on_work_done;
          wgpuQueueOnSubmittedWorkDone(g_queue, wi); if (!pump()) { printf("FAIL frame %d: work-done callback never came\n", f); return 10; } gt.push_back(ms_since(tw)); }
        if (win_on) {   // show the frame, then take what the window and the pads produced for the next frame
            auto tp = Clock::now(); std::vector<uint8_t> rgba;
            if (swap_on) { if (!swap.present(g_last_target)) present_fail++; if (f == frames - 1 && read_target_host(g_last_target, rgba)) verify_ok = window.verify(rgba.data(), 256, 256, verify_mismatch); }
            else if (read_target_host(g_last_target, rgba)) { if (!window.present(rgba.data(), 256, 256)) present_fail++; if (f == frames - 1) verify_ok = window.verify(rgba.data(), 256, 256, verify_mismatch); } else present_fail++;
            pres_ms.push_back(ms_since(tp)); std::vector<win::Event> we; window.poll(we);
            for (auto &x : we) { if (x.type == win::EV_KEY_DOWN) g_queue_in.push_back({EV_KEY_DOWN, (uint32_t)x.a, 0, (uint32_t)f}); else if (x.type == win::EV_KEY_UP) g_queue_in.push_back({EV_KEY_UP, (uint32_t)x.a, 0, (uint32_t)f}); else if (x.type == win::EV_MOUSE) g_queue_in.push_back({EV_MOUSE, (uint32_t)std::max(0, x.a), (uint32_t)std::max(0, x.b), (uint32_t)f}); }
        }
        if (pad_on) {   // sticks and the d-pad as the digital keys of the game, button A as fire (XInput conventions, see gamepad.h)
            static bool kl, kr, ku, kd; std::vector<pad::Event> pe; pads.poll(pe); auto set = [&](bool &k, bool v, uint32_t key) { if (k != v) { k = v; g_queue_in.push_back({v ? (uint32_t)EV_KEY_DOWN : (uint32_t)EV_KEY_UP, key, 0, (uint32_t)f}); } };
            static int lx, ly; static bool dl, dr, du, dd; for (auto &x : pe) { if (x.type == pad::EV_AXIS && x.index == pad::A_LX) lx = x.value; else if (x.type == pad::EV_AXIS && x.index == pad::A_LY) ly = x.value;
                else if (x.type == pad::EV_BUTTON && x.index == pad::B_A) g_queue_in.push_back({x.value ? (uint32_t)EV_KEY_DOWN : (uint32_t)EV_KEY_UP, 5, 0, (uint32_t)f});
                else if (x.type == pad::EV_BUTTON && x.index == pad::B_DLEFT) dl = x.value; else if (x.type == pad::EV_BUTTON && x.index == pad::B_DRIGHT) dr = x.value; else if (x.type == pad::EV_BUTTON && x.index == pad::B_DUP) du = x.value; else if (x.type == pad::EV_BUTTON && x.index == pad::B_DDOWN) dd = x.value; }
            set(kl, lx < -16000 || dl, 1); set(kr, lx > 16000 || dr, 2); set(ku, ly > 16000 || du, 3); set(kd, ly < -16000 || dd, 4);
        }
    }
    double loop_ms = ms_since(tl);
    bool aout_ok = true; if (g_aout.st.backend.size() && g_aout.st.backend != "off") { g_aout.finish(); g_aout.report("host"); aout_ok = g_aout.integrity(); if (realtime) printf("host : real-time pacing: %d of %d frames started more than 1 ms after their time, worst %.2f ms\n", late_frames, frames, worst_late); }
    if (wn_inst_call(inst, "game_result", nullptr, 0, res, 1)) { printf("FAIL game_result: %s\n", wn_inst_error(inst)); return 9; }
    int guest_fails = (int)res[0];
    // audio: 800 stereo frames per game frame; the tone must be exactly in game frames 60..71
    const int spf = 800; int tone_first = -1, tone_last = -1, tone_blocks = 0; double rms_max = 0;
    for (int f = 0; f < frames && (size_t)(f + 1) * spf * 2 <= g_audio.size(); f++) {
        double s = 0; for (int i = 0; i < spf * 2; i++) { double v = g_audio[(size_t)f * spf * 2 + i] / 32768.0; s += v * v; } double rms = std::sqrt(s / (spf * 2)); if (rms > rms_max) rms_max = rms;
        if (rms > 1e-4) { if (tone_first < 0) tone_first = f; tone_last = f; tone_blocks++; }
    }
    bool audio_ok = g_audio_frames == (uint64_t)frames * spf && tone_first == 60 && tone_last == 71 && tone_blocks == 12;
    if (const char *wav = getenv("GAME_WAV")) { FILE *w = fopen(wav, "wb"); if (w) { uint32_t dl = (uint32_t)(g_audio.size() * 2), v; uint16_t h; fwrite("RIFF", 1, 4, w); v = 36 + dl; fwrite(&v, 4, 1, w); fwrite("WAVEfmt ", 1, 8, w); v = 16; fwrite(&v, 4, 1, w);
        h = 1; fwrite(&h, 2, 1, w); h = 2; fwrite(&h, 2, 1, w); v = 48000; fwrite(&v, 4, 1, w); v = 48000 * 4; fwrite(&v, 4, 1, w); h = 4; fwrite(&h, 2, 1, w); h = 16; fwrite(&h, 2, 1, w); fwrite("data", 1, 4, w); fwrite(&dl, 4, 1, w); fwrite(g_audio.data(), 2, g_audio.size(), w); fclose(w); } }
    // GPU side: completion latency per frame (always) and the GPU's own timestamps of the passes (when supported)
    std::sort(gt.begin(), gt.end()); double gmed = gt.empty() ? 0 : gt[gt.size() / 2], gp99 = gt.empty() ? 0 : gt[(size_t)(gt.size() * 0.99)], gmax = gt.empty() ? 0 : gt.back();
    printf("host : GPU completion after the submission side finished, per frame: median %.3f ms, p99 %.3f ms, max %.3f ms (%zu frames, work-done failures %d)\n", gmed, gp99, gmax, gt.size(), g_qwork_bad);
    bool ts_ok = true;
    if (g_ts && g_qn) {
        const uint64_t *tsv = nullptr; if (!map_read(g_qread, kQBytes, (const void **)&tsv)) { puts("host : timestamp readback failed"); ts_ok = false; }
        else { std::vector<double> pass_us; int inverted = 0, zero = 0; for (const QSeg &sg : g_qsegs) for (uint32_t i = 0; i + 1 < sg.count; i += 2) { const uint64_t a = tsv[sg.off / 8 + i], b = tsv[sg.off / 8 + i + 1]; if (a == 0 && b == 0) { zero++; continue; } if (b < a) { inverted++; continue; } pass_us.push_back((double)(b - a) / 1e3); }
            std::sort(pass_us.begin(), pass_us.end()); double tot = 0; for (double v : pass_us) tot += v;
            if (pass_us.empty()) { printf("host : GPU timestamps: %u passes written, none usable (%d zero, %d inverted)\n", g_qn / 2, zero, inverted); ts_ok = false; }
            else printf("host : GPU timestamps: %zu passes, per pass median %.1f us, p99 %.1f us, max %.1f us, total GPU pass time %.2f ms over %d frames (%d zero, %d inverted)\n", pass_us.size(), pass_us[pass_us.size() / 2], pass_us[(size_t)(pass_us.size() * 0.99)], pass_us.back(), tot / 1e3, frames, zero, inverted);
            wgpuBufferUnmap(g_qread); }
    }
    std::sort(ft.begin(), ft.end()); double med = ft[ft.size() / 2], p99 = ft[(size_t)(ft.size() * 0.99)];
    printf("host : %d frames in %.1f ms including the wait for the GPU after each frame (submission-side frame time median %.2f ms, p99 %.2f ms: wasm, GPU encode and submit); submits %llu, dispatches %llu, draws %llu\n", frames, loop_ms, med, p99, (unsigned long long)g_submits, (unsigned long long)g_dispatches, (unsigned long long)g_draws);
    printf("host : audio %llu frames, tone in game frames %d..%d (%d blocks), peak block RMS %.3f -> %s\n", (unsigned long long)g_audio_frames, tone_first, tone_last, tone_blocks, rms_max, audio_ok ? "as scripted" : "WRONG");
    if (win_on) { std::sort(pres_ms.begin(), pres_ms.end()); printf("host : window: %zu frames presented through [%s], read back and shown in median %.3f ms (p99 %.3f ms), %d failed; read-back of the window after the last frame: %s\n", pres_ms.size(), window.backend.c_str(), pres_ms.empty() ? 0 : pres_ms[pres_ms.size() / 2], pres_ms.empty() ? 0 : pres_ms[(size_t)(pres_ms.size() * 0.99)], present_fail,
        verify_ok ? (verify_mismatch == 0 ? "exact, 0 pixels differ" : "DIFFERS") : "not possible on this display system");
        if (verify_ok && !window.detail().empty()) printf("host : window read-back detail: %d pixels differ; %s\n", verify_mismatch, window.detail().c_str());
        window.close(); }
    bool win_ok = !win_on || (present_fail == 0 && (!verify_ok || verify_mismatch == 0 || window.backend == "appkit" || swap_on));   // (a swapchain window is read back through the desktop compositor: reported with numbers, not gated)   // (macOS: the capture is colour managed and only approximately equal; the numbers are in window_test)
    bool pass = win_ok && guest_fails == 0 && bad == 0 && g_gpu_errors == 0 && audio_ok && g_qwork_bad == 0 && ts_ok && aout_ok;
    printf("RESULT %s gameloop frames=%d guest_fails=%d frame_fails=%d gpu_errors=%d audio=%s\n", pass ? "PASS" : "FAIL", frames, guest_fails, bad, g_gpu_errors, audio_ok ? "ok" : "bad");
    fflush(stdout); return pass ? 0 : 1;
}
