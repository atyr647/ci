/* Isolates where Vulkan-on-Windows breaks under Cosmopolitan: load the loader, resolve entry points, call them with the right ABI, step by step.
 * Every step prints before it runs, so the last line shown is the one that crashed. */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <cosmo.h>
#include <dlfcn.h>
#include <vulkan/vulkan.h>

#define MS __attribute__((ms_abi))
typedef void *(MS *gipa_ms_t)(void *, const char *);
typedef void *(*gipa_t)(void *, const char *);
typedef VkResult (MS *ver_ms_t)(uint32_t *);
typedef VkResult (*ver_t)(uint32_t *);
typedef VkResult (MS *ci_ms_t)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef VkResult (*ci_t)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef VkResult (MS *enum_ms_t)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef VkResult (*enum_t)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (MS *props_ms_t)(VkPhysicalDevice, VkPhysicalDeviceProperties *);
typedef void (*props_t)(VkPhysicalDevice, VkPhysicalDeviceProperties *);

/* Windows: Cosmopolitan turns every unknown SEH exception into a fatal SIGSEGV, including the harmless DBG_PRINTEXCEPTION_C that OutputDebugString raises
 * (the Vulkan loader, Dawn and many DLLs call it). A first-in-line vectored handler that swallows the debugger-message exceptions prevents that. */
typedef struct { uint32_t ExceptionCode; } ExRec;
typedef struct { ExRec *rec; void *ctx; } ExPtrs;
static MS long swallow_debug_exceptions(ExPtrs *ep) {
  uint32_t c = ep->rec->ExceptionCode;
  if (c == 0x40010006u || c == 0x4001000Au || c == 0x406D1388u) return -1;   /* EXCEPTION_CONTINUE_EXECUTION */
  return 0;                                                                   /* EXCEPTION_CONTINUE_SEARCH */
}
typedef void *(MS *addveh_t)(unsigned long first, void *handler);
static void install_exception_shield(void) {
  void *k32 = cosmo_dlopen("kernel32.dll", RTLD_NOW);
  addveh_t f = k32 ? (addveh_t)cosmo_dlsym(k32, "AddVectoredExceptionHandler") : 0;
  printf("exception shield: %s\n", f && f(1, (void *)swallow_debug_exceptions) ? "installed" : "NOT installed"); fflush(stdout);
}

#define STEP(...) do { printf("step: " __VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

int main(void) {
  ShowCrashReports();
  int win = IsWindows();
  if (win && !getenv("NO_SHIELD")) install_exception_shield();
  const char *name = win ? "vulkan-1.dll" : IsXnu() ? "libvulkan.dylib" : "libvulkan.so.1";
  STEP("windows=%d, dlopen(%s)", win, name);
  void *h = cosmo_dlopen(name, RTLD_NOW);
  if (!h) { printf("dlopen failed: %s\n", cosmo_dlerror()); return 1; }
  STEP("dlopen ok handle=%p; dlsym vkGetInstanceProcAddr", h);
  void *raw = cosmo_dlsym(h, "vkGetInstanceProcAddr");
  STEP("gipa raw=%p", raw);
  if (!raw) return 2;
  void *gipa_p = win ? raw : cosmo_dltramp(raw);
#define GIPA(inst, nm) (win ? ((gipa_ms_t)gipa_p)(inst, nm) : ((gipa_t)gipa_p)(inst, nm))
  STEP("gipa(NULL, vkEnumerateInstanceVersion)");
  void *verp = GIPA(NULL, "vkEnumerateInstanceVersion");
  STEP("vkEnumerateInstanceVersion=%p", verp);
  uint32_t ver = 0;
  if (verp) {
    VkResult r = win ? ((ver_ms_t)verp)(&ver) : ((ver_t)(cosmo_dltramp(verp)))(&ver);
    STEP("instance version -> r=%d %u.%u.%u", r, VK_VERSION_MAJOR(ver), VK_VERSION_MINOR(ver), VK_VERSION_PATCH(ver));
  }
  STEP("gipa(NULL, vkCreateInstance)");
  void *cip = GIPA(NULL, "vkCreateInstance");
  STEP("vkCreateInstance=%p", cip);
  VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "probe", 1, "probe", 1, VK_API_VERSION_1_1};
  VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &ai, 0, 0, 0, 0};
  VkInstance inst = 0;
  VkResult r = win ? ((ci_ms_t)cip)(&ici, 0, &inst) : ((ci_t)(cosmo_dltramp(cip)))(&ici, 0, &inst);
  STEP("vkCreateInstance -> r=%d instance=%p", r, (void *)inst);
  if (r) return 3;
  void *enp = GIPA(inst, "vkEnumeratePhysicalDevices");
  uint32_t n = 0;
  r = win ? ((enum_ms_t)enp)(inst, &n, 0) : ((enum_t)(cosmo_dltramp(enp)))(inst, &n, 0);
  STEP("vkEnumeratePhysicalDevices count -> r=%d n=%u", r, n);
  if (n) {
    VkPhysicalDevice pd[8]; if (n > 8) n = 8;
    r = win ? ((enum_ms_t)enp)(inst, &n, pd) : ((enum_t)(cosmo_dltramp(enp)))(inst, &n, pd);
    void *pp = GIPA(inst, "vkGetPhysicalDeviceProperties");
    VkPhysicalDeviceProperties props; memset(&props, 0, sizeof props);
    if (win) ((props_ms_t)pp)(pd[0], &props); else ((props_t)(cosmo_dltramp(pp)))(pd[0], &props);
    STEP("device 0: %s api=%u.%u", props.deviceName, VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion));
  }
  puts("RESULT PASS");
  return 0;
}
