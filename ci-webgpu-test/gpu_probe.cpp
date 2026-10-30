// Lists every GPU Dawn can see on this machine, shows what Dawn itself would hand out for each power preference, and what OUR policy picks.
// Run it on the real machine (laptop with two GPUs) and read the output: "policy picks" must be the discrete GPU.
//   gpu-probe            list + pick
//   gpu-probe --selftest only run the policy against made-up hybrid-GPU laptops
#define _COSMO_SOURCE 1
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
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

int main(int argc, char **argv) {
#if defined(__COSMOPOLITAN__)
  ShowCrashReports(); win_shield_install();
#endif
  if (argc > 1 && !strcmp(argv[1], "--selftest")) return selftest();
  int bad = selftest();
  dawn::native::Instance instance;
  const char *prefs[] = {"Undefined", "HighPerformance", "LowPower"};
  const WGPUPowerPreference pv[] = {WGPUPowerPreference_Undefined, WGPUPowerPreference_HighPerformance, WGPUPowerPreference_LowPower};
  std::vector<gpu_candidate> cands; std::vector<std::string> names;
  for (int p = 0; p < 3; p++) {
    WGPURequestAdapterOptions o = WGPU_REQUEST_ADAPTER_OPTIONS_INIT; o.powerPreference = pv[p];
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
      if (p == 0 && info.backendType != WGPUBackendType_Null) { names.push_back(sv(info.device)); cands.push_back({t, b, local, nullptr}); }   // the Null backend is a test stub, never a candidate
      wgpuAdapterInfoFreeMembers(info);
    }
  }
  for (size_t i = 0; i < cands.size(); i++) cands[i].name = names[i].c_str();
  int forced = getenv("GAME_GPU") ? atoi(getenv("GAME_GPU")) : -1;
  int pick = gpu_pick(cands.data(), (int)cands.size(), forced);
  if (pick >= 0) printf("policy picks: [%d] %s (%s)%s\n", pick, cands[pick].name, type_name(cands[pick].type), forced >= 0 ? "  (forced by GAME_GPU)" : "");
  else printf("policy picks: none\n");
  puts(bad ? "RESULT FAIL" : "RESULT PASS");
  return bad;
}
