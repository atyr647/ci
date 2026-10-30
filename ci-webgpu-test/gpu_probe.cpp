// Lists every GPU Dawn can see on this machine, shows what Dawn itself would hand out for each power preference, and what OUR policy picks.
// Run it on the real machine (laptop with two GPUs) and read the output: "policy picks" must be the discrete GPU.
//   gpu-probe            list + pick
//   gpu-probe --selftest only run the policy against made-up hybrid-GPU laptops
//   gpu-probe --bench    additionally run the same compute kernel on EVERY adapter and report how fast each is, then say whether the policy's pick is the fastest
//                        (the measurement that tells you, on the real machine, that the "real GPU" and not the slow one is used)
#define _COSMO_SOURCE 1
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <ctime>
#include <unistd.h>
#if defined(__COSMOPOLITAN__)
#include <cosmo.h>
#include "win_shield.h"
#endif
#include "dawn/native/DawnNative.h"
#include <webgpu/webgpu.h>
#include "gpu_policy.h"

static std::string sv(WGPUStringView s) { return s.data ? std::string(s.data, s.length == WGPU_STRLEN ? strlen(s.data) : s.length) : ""; }
static const char *type_name(int t) { return t == GPU_TYPE_DISCRETE ? "discrete" : t == GPU_TYPE_INTEGRATED ? "integrated" : t == GPU_TYPE_CPU ? "cpu/software" : "unknown"; }

static int selftest() {
  struct Case { const char *what; std::vector<gpu_candidate> list; int expect; };
  const uint64_t GB = 1ull << 30, MB = 1ull << 20;
  std::vector<Case> cases = {
    {"Windows Optimus laptop, D3D12, OS lists the Intel iGPU first", {{GPU_TYPE_INTEGRATED, GPU_BACKEND_D3D12, 128*MB, "Intel UHD"}, {GPU_TYPE_DISCRETE, GPU_BACKEND_D3D12, 6*GB, "NVIDIA RTX"}}, 1},
    {"same laptop, both D3D12 and Vulkan adapters visible", {{GPU_TYPE_INTEGRATED, GPU_BACKEND_D3D12, 128*MB, "Intel D3D12"}, {GPU_TYPE_DISCRETE, GPU_BACKEND_VULKAN, 6*GB, "NVIDIA Vulkan"}, {GPU_TYPE_DISCRETE, GPU_BACKEND_D3D12, 6*GB, "NVIDIA D3D12"}}, 2},
    {"AMD APU + discrete Radeon", {{GPU_TYPE_INTEGRATED, GPU_BACKEND_VULKAN, 512*MB, "Radeon Graphics (APU)"}, {GPU_TYPE_DISCRETE, GPU_BACKEND_VULKAN, 8*GB, "Radeon RX"}}, 1},
    {"Apple silicon, one GPU", {{GPU_TYPE_INTEGRATED, GPU_BACKEND_METAL, 16*GB, "Apple M-series"}}, 0},
    {"Intel Mac with AMD Pro + Intel iGPU (Metal)", {{GPU_TYPE_INTEGRATED, GPU_BACKEND_METAL, 1536*MB, "Intel Iris"}, {GPU_TYPE_DISCRETE, GPU_BACKEND_METAL, 4*GB, "AMD Radeon Pro"}}, 1},
    {"two discrete GPUs, more memory wins", {{GPU_TYPE_DISCRETE, GPU_BACKEND_VULKAN, 8*GB, "small"}, {GPU_TYPE_DISCRETE, GPU_BACKEND_VULKAN, 24*GB, "big"}}, 1},
    {"integrated GPU reporting a huge shared pool never beats a discrete one", {{GPU_TYPE_INTEGRATED, GPU_BACKEND_D3D12, 32*GB, "iGPU shared"}, {GPU_TYPE_DISCRETE, GPU_BACKEND_D3D12, 4*GB, "dGPU"}}, 1},
    {"VM: only software adapters, D3D12 WARP preferred over Vulkan llvmpipe", {{GPU_TYPE_CPU, GPU_BACKEND_VULKAN, 0, "llvmpipe"}, {GPU_TYPE_CPU, GPU_BACKEND_D3D12, 0, "WARP"}}, 1},
    {"software adapter listed first, real iGPU second", {{GPU_TYPE_CPU, GPU_BACKEND_D3D12, 0, "WARP"}, {GPU_TYPE_INTEGRATED, GPU_BACKEND_D3D12, 1*GB, "Intel"}}, 1},
    {"unknown adapter type loses to a known integrated GPU", {{GPU_TYPE_UNKNOWN, GPU_BACKEND_VULKAN, 0, "mystery"}, {GPU_TYPE_INTEGRATED, GPU_BACKEND_VULKAN, 1*GB, "iGPU"}}, 1},
    {"empty list", {}, -1},
  };
  int bad = 0;
  for (auto &c : cases) { int got = gpu_pick(c.list.data(), (int)c.list.size(), -1); bool ok = got == c.expect; bad += !ok; printf("  %s  %s (picked %d, expected %d)\n", ok ? "ok  " : "FAIL", c.what, got, c.expect); }
  { gpu_candidate l[2] = {{GPU_TYPE_INTEGRATED, 0, 1, "a"}, {GPU_TYPE_DISCRETE, 0, 2, "b"}}; bool ok = gpu_pick(l, 2, 0) == 0; bad += !ok; printf("  %s  explicit user choice (index 0) beats the policy\n", ok ? "ok  " : "FAIL"); }
  printf("policy selftest: %s\n", bad ? "FAIL" : "PASS"); return bad;
}


// ---- --bench: the same ALU-bound compute kernel on one adapter; returns GFLOP/s (6 flops per loop iteration per invocation) or <0 on failure ----
static volatile int g_done; static int g_status; static WGPUDevice g_device;
static void on_device(WGPURequestDeviceStatus s, WGPUDevice d, WGPUStringView, void *, void *) { g_status = s; g_device = d; g_done = 1; }
static void on_map(WGPUMapAsyncStatus s, WGPUStringView, void *, void *) { g_status = s; g_done = 1; }
static void pump(WGPUInstance inst) { for (int n = 0; !g_done && n < 200000; n++) { wgpuInstanceProcessEvents(inst); usleep(500); } }
static double now_ms() { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static double bench_adapter(WGPUInstance inst, WGPUAdapter ad, bool software, double *ms_out) {
  g_device = nullptr; g_done = 0;
  WGPUDeviceDescriptor dd = WGPU_DEVICE_DESCRIPTOR_INIT; WGPURequestDeviceCallbackInfo dci = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
  dci.mode = WGPUCallbackMode_AllowProcessEvents; dci.callback = on_device; wgpuAdapterRequestDevice(ad, &dd, dci); pump(inst);
  if (!g_device) return -1;
  WGPUDevice dev = g_device; WGPUQueue q = wgpuDeviceGetQueue(dev);
  const unsigned iters = 256;
  std::string wgsl = "@group(0) @binding(0) var<storage, read_write> d : array<f32>;\n@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g : vec3<u32>) {\n"
                     "  var a = f32(g.x) * 0.001; var b = 1.0001;\n  for (var i = 0u; i < " + std::to_string(iters) + "u; i++) { a = fma(a, b, 0.5); b = fma(b, a, 0.25) * 0.5 + 0.9; }\n  d[g.x] = a + b;\n}\n";
  WGPUShaderSourceWGSL w = WGPU_SHADER_SOURCE_WGSL_INIT; w.code = {wgsl.data(), wgsl.size()};
  WGPUShaderModuleDescriptor smd = WGPU_SHADER_MODULE_DESCRIPTOR_INIT; smd.nextInChain = &w.chain;
  WGPUShaderModule sm = wgpuDeviceCreateShaderModule(dev, &smd);
  WGPUComputePipelineDescriptor cpd = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT; cpd.compute.module = sm; cpd.compute.entryPoint = {"main", 4};
  WGPUComputePipeline pipe = wgpuDeviceCreateComputePipeline(dev, &cpd);
  const uint32_t maxGroups = software ? 4096 : 1u << 18;   // 64 invocations per group; 4 bytes each: at most 64 MB
  WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT; bd.size = (uint64_t)maxGroups * 64 * 4; bd.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc;
  WGPUBuffer sb = wgpuDeviceCreateBuffer(dev, &bd);
  bd.size = 256; bd.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst; WGPUBuffer rb = wgpuDeviceCreateBuffer(dev, &bd);
  WGPUBindGroupEntry be = WGPU_BIND_GROUP_ENTRY_INIT; be.binding = 0; be.buffer = sb; be.size = (uint64_t)maxGroups * 64 * 4;
  WGPUBindGroupDescriptor bgd = WGPU_BIND_GROUP_DESCRIPTOR_INIT; bgd.layout = wgpuComputePipelineGetBindGroupLayout(pipe, 0); bgd.entryCount = 1; bgd.entries = &be;
  WGPUBindGroup bg = wgpuDeviceCreateBindGroup(dev, &bgd);
  auto run = [&](uint32_t groups) -> double {   // wall time of one submission, in ms; <0 on failure
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT; WGPUCommandEncoder e = wgpuDeviceCreateCommandEncoder(dev, &ed);
    WGPUComputePassDescriptor pd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT; WGPUComputePassEncoder cp = wgpuCommandEncoderBeginComputePass(e, &pd);
    wgpuComputePassEncoderSetPipeline(cp, pipe); wgpuComputePassEncoderSetBindGroup(cp, 0, bg, 0, nullptr);
    wgpuComputePassEncoderDispatchWorkgroups(cp, groups, 1, 1); wgpuComputePassEncoderEnd(cp);
    wgpuCommandEncoderCopyBufferToBuffer(e, sb, 0, rb, 0, 256);
    WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT; WGPUCommandBuffer cb = wgpuCommandEncoderFinish(e, &cbd);
    double t0 = now_ms(); wgpuQueueSubmit(q, 1, &cb);
    WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT; mi.mode = WGPUCallbackMode_AllowProcessEvents; mi.callback = on_map;
    g_done = 0; wgpuBufferMapAsync(rb, WGPUMapMode_Read, 0, 256, mi); pump(inst);
    double t1 = now_ms(); if (g_status != WGPUMapAsyncStatus_Success) return -1;
    wgpuBufferUnmap(rb); wgpuCommandBufferRelease(cb); wgpuCommandEncoderRelease(e); wgpuComputePassEncoderRelease(cp);
    return t1 - t0; };
  double gflops = -1, best = 1e30; uint32_t groups = software ? 64 : 256;
  double ms = run(groups); ms = run(groups);            // warm-up (pipeline compilation, first-use costs)
  while (ms >= 0 && ms < 30 && groups < maxGroups) { groups = groups * 4 > maxGroups ? maxGroups : groups * 4; ms = run(groups); }   // grow until a run takes ~30 ms
  if (ms >= 0) { for (int r = 0; r < 5; r++) { double t = run(groups); if (t >= 0 && t < best) best = t; }
    if (best < 1e29) { gflops = (double)groups * 64 * iters * 6 / (best / 1e3) / 1e9; if (ms_out) *ms_out = best; } }
  wgpuBindGroupRelease(bg); wgpuBufferRelease(rb); wgpuBufferRelease(sb); wgpuComputePipelineRelease(pipe); wgpuShaderModuleRelease(sm); wgpuQueueRelease(q); wgpuDeviceRelease(dev);
  return gflops;
}

int main(int argc, char **argv) {
#if defined(__COSMOPOLITAN__)
  ShowCrashReports(); win_shield_install();
#endif
  if (argc > 1 && !strcmp(argv[1], "--selftest")) return selftest();
  int bad = selftest();
  // every message Dawn emits (backend start-up failures are otherwise silent: "no adapters" and nothing else)
  dawn::native::DawnInstanceDescriptor dawnDesc;
  dawnDesc.SetLoggingCallback([](wgpu::LoggingType type, wgpu::StringView m) { fprintf(stderr, "[dawn %s] %.*s\n", type == wgpu::LoggingType::Error ? "error" : type == wgpu::LoggingType::Warning ? "warning" : "info", (int)(m.length == WGPU_STRLEN ? strlen(m.data) : m.length), m.data); });
  WGPUInstanceDescriptor instDesc = WGPU_INSTANCE_DESCRIPTOR_INIT; instDesc.nextInChain = reinterpret_cast<WGPUChainedStruct *>(&dawnDesc);
  dawn::native::Instance instance(&instDesc);
  const char *prefs[] = {"Undefined", "HighPerformance", "LowPower"};
  const WGPUPowerPreference pv[] = {WGPUPowerPreference_Undefined, WGPUPowerPreference_HighPerformance, WGPUPowerPreference_LowPower};
  std::vector<gpu_candidate> cands; std::vector<std::string> names; std::vector<dawn::native::Adapter> ads;
  for (int p = 0; p < 3; p++) {
    WGPURequestAdapterOptions o = WGPU_REQUEST_ADAPTER_OPTIONS_INIT; o.powerPreference = pv[p];
    if (const char *be = getenv("WGT_BACKEND")) o.backendType = !strcmp(be, "vulkan") ? WGPUBackendType_Vulkan : !strcmp(be, "d3d12") ? WGPUBackendType_D3D12 : !strcmp(be, "metal") ? WGPUBackendType_Metal : WGPUBackendType_Undefined;   // same switches as the compute test
    if (getenv("WGT_FALLBACK")) o.forceFallbackAdapter = 1;
    auto list = instance.EnumerateAdapters(&o);
    printf("Dawn order for powerPreference=%s (%zu adapters):\n", prefs[p], list.size());
    for (size_t i = 0; i < list.size(); i++) {
      WGPUAdapterPropertiesMemoryHeaps heaps = WGPU_ADAPTER_PROPERTIES_MEMORY_HEAPS_INIT;
      WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT; info.nextInChain = &heaps.chain;
      wgpuAdapterGetInfo(list[i].Get(), &info);
      uint64_t local = 0; for (size_t h = 0; h < heaps.heapCount; h++) if (heaps.heapInfo[h].properties & WGPUHeapProperty_DeviceLocal) local += heaps.heapInfo[h].size;
      int t = info.adapterType == WGPUAdapterType_DiscreteGPU ? GPU_TYPE_DISCRETE : info.adapterType == WGPUAdapterType_IntegratedGPU ? GPU_TYPE_INTEGRATED : info.adapterType == WGPUAdapterType_CPU ? GPU_TYPE_CPU : GPU_TYPE_UNKNOWN;
      int b = (info.backendType == WGPUBackendType_Metal || info.backendType == WGPUBackendType_D3D12) ? GPU_BACKEND_D3D12 : info.backendType == WGPUBackendType_Vulkan ? GPU_BACKEND_VULKAN : GPU_BACKEND_OTHER;
      printf("  [%zu] %-12s backend=%d vendor=0x%04x device=0x%04x deviceLocalMemory=%llu MB  %s\n", i, type_name(t), info.backendType, info.vendorID, info.deviceID, (unsigned long long)(local >> 20), sv(info.device).c_str());
      if (p == 0 && info.backendType != WGPUBackendType_Null) { names.push_back(sv(info.device)); cands.push_back({t, b, local, nullptr}); ads.push_back(list[i]); }   // the Null backend is a test stub, never a candidate
      wgpuAdapterInfoFreeMembers(info);
    }
  }
  for (size_t i = 0; i < cands.size(); i++) cands[i].name = names[i].c_str();
  int forced = getenv("GAME_GPU") ? atoi(getenv("GAME_GPU")) : -1;
  int pick = gpu_pick(cands.data(), (int)cands.size(), forced);
  if (pick >= 0) printf("policy picks: [%d] %s (%s)%s\n", pick, cands[pick].name, type_name(cands[pick].type), forced >= 0 ? "  (forced by GAME_GPU)" : "");
  else printf("policy picks: none\n");
  if (argc > 1 && !strcmp(argv[1], "--bench") && !cands.empty()) {
    puts("benchmark: same ALU-bound compute kernel on every adapter (GFLOP/s, fastest of 5 runs; software adapters run a smaller workload)");
    std::vector<double> gf(cands.size(), -1); int fastest = -1;
    for (size_t i = 0; i < cands.size(); i++) {
      double ms = 0; gf[i] = bench_adapter(instance.Get(), ads[i].Get(), cands[i].type == GPU_TYPE_CPU, &ms);
      if (gf[i] >= 0) printf("  [%zu] %-12s %10.1f GFLOP/s  (%.1f ms per run)  %s\n", i, type_name(cands[i].type), gf[i], ms, cands[i].name);
      else printf("  [%zu] %-12s could not run the kernel  %s\n", i, type_name(cands[i].type), cands[i].name);
      if (gf[i] > 0 && (fastest < 0 || gf[i] > gf[fastest])) fastest = (int)i;
    }
    if (pick >= 0 && fastest >= 0) printf("fastest adapter: [%d]; policy picked [%d]: %s\n", fastest, pick, fastest == pick ? "the policy picked the fastest one" : (gf[pick] >= 0.9 * gf[fastest] ? "the policy's pick is within 10% of the fastest" : "WARNING: the policy did not pick the fastest adapter"));
  }
  puts(bad ? "RESULT FAIL" : "RESULT PASS");
  return bad;
}
