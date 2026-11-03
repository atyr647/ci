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
#define WIN_SHIELD_WRAP_THREADS 1
#include "win_shield.h"
#include <webgpu/webgpu.h>
extern "C" void DawnCosmoGpuThreadEnter();
extern "C" void DawnCosmoForeignInit();

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
static WGPUCommandEncoder g_enc; static uint64_t g_submits, g_dispatches, g_draws;
// GPU timestamp queries (when the adapter has the feature): every compute and render pass writes its start and end; they are resolved at the end of each submission and read once at the end of the run
static const uint32_t kMaxQ = 2048; static bool g_ts; static WGPUQuerySet g_qs; static WGPUBuffer g_qres, g_qread; static uint32_t g_qn, g_qresolved; static int g_qwork_bad;
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
        WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT; bd.size = kMaxQ * 8; bd.usage = WGPUBufferUsage_QueryResolve | WGPUBufferUsage_CopySrc; g_qres = wgpuDeviceCreateBuffer(g_device, &bd);
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
CB(gpu_target) { Target t; t.w = (int)a[0]; t.h = (int)a[1]; WGPUTextureDescriptor d = WGPU_TEXTURE_DESCRIPTOR_INIT; d.usage = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc;
    d.size = {(uint32_t)t.w, (uint32_t)t.h, 1}; d.format = WGPUTextureFormat_RGBA8Unorm; t.tex = wgpuDeviceCreateTexture(g_device, &d); t.view = wgpuTextureCreateView(t.tex, nullptr);
    g_targets.push_back(t); r[0] = (uint32_t)(g_targets.size() - 1); return 0; }
CB(gpu_begin) { WGPUCommandEncoderDescriptor d = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; g_enc = wgpuDeviceCreateCommandEncoder(g_device, &d); return 0; }
CB(gpu_end) { if (g_ts && g_qn > g_qresolved) { uint32_t n = g_qn - g_qresolved; wgpuCommandEncoderResolveQuerySet(g_enc, g_qs, g_qresolved, n, g_qres, (uint64_t)g_qresolved * 8);
        wgpuCommandEncoderCopyBufferToBuffer(g_enc, g_qres, (uint64_t)g_qresolved * 8, g_qread, (uint64_t)g_qresolved * 8, (uint64_t)n * 8); g_qresolved = g_qn; }
    WGPUCommandBufferDescriptor d = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(g_enc, &d); wgpuQueueSubmit(g_queue, 1, &cb); wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(g_enc); g_enc = nullptr; g_submits++; return 0; }
CB(gpu_dispatch) { uint32_t p = (uint32_t)a[0]; int ids[3] = {(int)a[1], (int)a[2], (int)a[3]}; uint32_t groups = (uint32_t)a[4]; if (p >= g_cpipes.size() || !g_enc) return 1;
    WGPUBindGroupLayout l = wgpuComputePipelineGetBindGroupLayout(g_cpipes[p], 0); WGPUBindGroup bg = make_bg(l, ids, 3);
    WGPUComputePassDescriptor pd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT; WGPUPassTimestampWrites tw = WGPU_PASS_TIMESTAMP_WRITES_INIT; if (take_ts(&tw)) pd.timestampWrites = &tw; WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(g_enc, &pd);
    wgpuComputePassEncoderSetPipeline(pass, g_cpipes[p]); wgpuComputePassEncoderSetBindGroup(pass, 0, bg, 0, nullptr); wgpuComputePassEncoderDispatchWorkgroups(pass, groups, 1, 1); wgpuComputePassEncoderEnd(pass);
    wgpuComputePassEncoderRelease(pass); wgpuBindGroupRelease(bg); wgpuBindGroupLayoutRelease(l); g_dispatches++; return 0; }
CB(gpu_draw) { uint32_t p = (uint32_t)a[0]; int ids[3] = {(int)a[1], (int)a[2], -1}; uint32_t t = (uint32_t)a[3], verts = (uint32_t)a[4], inst = (uint32_t)a[5], clear = (uint32_t)a[6]; if (p >= g_rpipes.size() || t >= g_targets.size() || !g_enc) return 1;
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

// ---------------------------------------------------------------- input and audio
struct Ev { uint32_t type, a, b, frame; };
static std::vector<Ev> g_queue_in; static size_t g_qhead;
static std::vector<int16_t> g_audio; static uint64_t g_audio_frames;
CB(input_poll) { uint32_t p = (uint32_t)a[0], mx = (uint32_t)a[1]; size_t n = 0; while (g_qhead < g_queue_in.size() && n < mx) { if (!OK(p + n * 16, 16)) break; memcpy(mem + p + n * 16, &g_queue_in[g_qhead++], 16); n++; } r[0] = n; return 0; }
CB(audio_write) { uint32_t p = (uint32_t)a[0], frames = (uint32_t)a[1]; if (!OK(p, frames * 4)) { r[0] = 0; return 0; } const int16_t *s = (const int16_t *)(mem + p); g_audio.insert(g_audio.end(), s, s + (size_t)frames * 2); g_audio_frames += frames; r[0] = frames; return 0; }
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

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0); ShowCrashReports(); win_shield_install();   // a crash prints a report (registers, backtrace) instead of nothing
    DawnCosmoForeignInit(); DawnCosmoGpuThreadEnter();
    int frames = 120; const char *cw = getenv("GAME_CWASM");
    for (int i = 1; i < argc; i++) { if (!strncmp(argv[i], "--frames=", 9)) frames = atoi(argv[i] + 9); else if (!strncmp(argv[i], "--cwasm=", 8)) cw = argv[i] + 8; }
    const char *arch = IsAarch64() ? "aarch64" : "x86_64"; char path[256]; snprintf(path, sizeof path, "/zip/game.sig.%s.cwasm", arch);
    size_t len = 0; uint8_t *bytes = read_all(cw ? cw : path, &len); if (!bytes) bytes = read_all("game.cwasm", &len); if (!bytes) { fprintf(stderr, "cannot read the game module (%s)\n", cw ? cw : path); return 65; }
    printf("host : platform=%s arch=%s, game module %zu bytes\n", IsWindows() ? "windows" : IsXnu() ? "macos" : "linux", arch, len);
    auto t0 = Clock::now(); if (!gpu_init()) { puts("FAIL gpu init"); return 2; } printf("host : GPU ready in %.1f ms\n", ms_since(t0));
    WnEngine *e = wn_engine_new(0); if (!e) { puts("FAIL engine"); return 3; }
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
    auto tl = Clock::now(); std::vector<double> ft, gt; int bad = 0;
    for (int f = 0; f < frames; f++) {
        script(f); auto t1 = Clock::now(); uint64_t arg[1] = {(uint64_t)f};
        if (wn_inst_call(inst, "game_frame", arg, 1, res, 1)) { printf("FAIL game_frame %d: %s\n", f, wn_inst_error(inst)); return 8; }
        wgpuInstanceProcessEvents(g_inst); ft.push_back(ms_since(t1)); if (res[0]) bad++;
        // then wait for the GPU to finish this frame's work: the time from the end of the submission side to completion (what a game that must not run ahead of the GPU would wait)
        { auto tw = Clock::now(); g_done = 0; WGPUQueueWorkDoneCallbackInfo wi = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT; wi.mode = WGPUCallbackMode_AllowProcessEvents; wi.callback = on_work_done;
          wgpuQueueOnSubmittedWorkDone(g_queue, wi); if (!pump()) { printf("FAIL frame %d: work-done callback never came\n", f); return 10; } gt.push_back(ms_since(tw)); }
    }
    double loop_ms = ms_since(tl);
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
        const uint64_t *tsv = nullptr; if (!map_read(g_qread, (uint64_t)kMaxQ * 8, (const void **)&tsv)) { puts("host : timestamp readback failed"); ts_ok = false; }
        else { std::vector<double> pass_us; int inverted = 0, zero = 0; for (uint32_t i = 0; i + 1 < g_qn; i += 2) { if (tsv[i] == 0 && tsv[i + 1] == 0) { zero++; continue; } if (tsv[i + 1] < tsv[i]) { inverted++; continue; } pass_us.push_back((double)(tsv[i + 1] - tsv[i]) / 1e3); }
            std::sort(pass_us.begin(), pass_us.end()); double tot = 0; for (double v : pass_us) tot += v;
            if (pass_us.empty()) { printf("host : GPU timestamps: %u passes written, none usable (%d zero, %d inverted)\n", g_qn / 2, zero, inverted); ts_ok = false; }
            else printf("host : GPU timestamps: %zu passes, per pass median %.1f us, p99 %.1f us, max %.1f us, total GPU pass time %.2f ms over %d frames (%d zero, %d inverted)\n", pass_us.size(), pass_us[pass_us.size() / 2], pass_us[(size_t)(pass_us.size() * 0.99)], pass_us.back(), tot / 1e3, frames, zero, inverted);
            wgpuBufferUnmap(g_qread); }
    }
    std::sort(ft.begin(), ft.end()); double med = ft[ft.size() / 2], p99 = ft[(size_t)(ft.size() * 0.99)];
    printf("host : %d frames in %.1f ms including the wait for the GPU after each frame (submission-side frame time median %.2f ms, p99 %.2f ms: wasm, GPU encode and submit); submits %llu, dispatches %llu, draws %llu\n", frames, loop_ms, med, p99, (unsigned long long)g_submits, (unsigned long long)g_dispatches, (unsigned long long)g_draws);
    printf("host : audio %llu frames, tone in game frames %d..%d (%d blocks), peak block RMS %.3f -> %s\n", (unsigned long long)g_audio_frames, tone_first, tone_last, tone_blocks, rms_max, audio_ok ? "as scripted" : "WRONG");
    bool pass = guest_fails == 0 && bad == 0 && g_gpu_errors == 0 && audio_ok && g_qwork_bad == 0 && ts_ok;
    printf("RESULT %s gameloop frames=%d guest_fails=%d frame_fails=%d gpu_errors=%d audio=%s\n", pass ? "PASS" : "FAIL", frames, guest_fails, bad, g_gpu_errors, audio_ok ? "ok" : "bad");
    fflush(stdout); return pass ? 0 : 1;
}
