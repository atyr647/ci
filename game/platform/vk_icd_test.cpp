// Loads SwiftShader that is LINKED INTO this Cosmopolitan program (no dlopen, no libvulkan, no glibc) through the ICD entry point, creates an instance, lists the device and runs a trivial compute-free check
// (queue family properties, device properties). Prints "VKICD ..." lines and a RESULT line.
#include <cstdio>
#include <cstring>
#include <vector>
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
extern "C" PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance, const char *);
extern "C" VkResult vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *);   // what a Vulkan loader does first; without it the driver only accepts apiVersion 1.0
int main() {
    uint32_t ifv = 5; VkResult nr = vk_icdNegotiateLoaderICDInterfaceVersion(&ifv); printf("VKICD interface version negotiated: %u (rc %d)\n", ifv, (int)nr);
    auto gipa = (PFN_vkGetInstanceProcAddr)vk_icdGetInstanceProcAddr;
    auto createInstance = (PFN_vkCreateInstance)gipa(nullptr, "vkCreateInstance");
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, nullptr, "icd-test", 1, "none", 1, VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, nullptr, 0, &app, 0, nullptr, 0, nullptr};
    VkInstance inst = nullptr; VkResult r = createInstance(&ci, nullptr, &inst); printf("VKICD vkCreateInstance -> %d\n", (int)r);
    if (r != VK_SUCCESS) { puts("RESULT FAIL"); return 1; }
    auto enumDev = (PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices"); auto getProps = (PFN_vkGetPhysicalDeviceProperties)gipa(inst, "vkGetPhysicalDeviceProperties");
    uint32_t n = 0; enumDev(inst, &n, nullptr); std::vector<VkPhysicalDevice> d(n); enumDev(inst, &n, d.data());
    for (uint32_t i = 0; i < n; i++) { VkPhysicalDeviceProperties p; getProps(d[i], &p); printf("VKICD device %u: %s (type %d, api %u.%u)\n", i, p.deviceName, (int)p.deviceType, VK_VERSION_MAJOR(p.apiVersion), VK_VERSION_MINOR(p.apiVersion)); }
    puts(n ? "RESULT PASS" : "RESULT FAIL"); return n ? 0 : 1;
}
