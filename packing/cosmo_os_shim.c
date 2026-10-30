// The run-time OS queries that dawn-cosmo/patch.py defines inside Dawn's Vulkan sources (vulkan/VulkanFunctions.cpp) and uses from Instance.cpp; needed when the Vulkan backend
// is compiled out (a Windows-only build).
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <cosmo.h>
bool DawnCosmoIsWindows(void) { return IsWindows(); }
bool DawnCosmoIsXnu(void) { return IsXnu(); }
bool DawnCosmoTrace(void) { static int on = -1; if (on < 0) on = getenv("DAWN_COSMO_TRACE") != 0; return on; }
void DawnCosmoTraceCall(const char *name, void *addr) { (void)addr; fprintf(stderr, "[vk] %s\n", name); fflush(stderr); }
