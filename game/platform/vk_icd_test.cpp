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
    setvbuf(stdout, nullptr, _IONBF, 0);
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
    if (!n) { puts("RESULT FAIL"); return 1; }
    // Device creation in the three shapes Dawn uses: plain, with a VkPhysicalDeviceFeatures2 in the chain, with the Vulkan 1.1/1.2/1.3 feature structures behind it.
    auto createDevice = (PFN_vkCreateDevice)gipa(inst, "vkCreateDevice");
    auto getFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(inst, "vkGetPhysicalDeviceFeatures2");
    float prio = 1.0f; VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, nullptr, 0, 0, 1, &prio};
    int failures = 0;
    for (int stage = 0; stage < 4; stage++) {
        VkPhysicalDeviceFeatures2 f2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2}; VkPhysicalDeviceVulkan11Features f11 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES};
        VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}; VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
        VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, nullptr, 0, 1, &qci, 0, nullptr, 0, nullptr, nullptr};
        if (stage >= 1) dci.pNext = &f2;
        if (stage >= 2) f2.pNext = &f11;
        if (stage >= 3) { f11.pNext = &f12; f12.pNext = &f13; }
        if (stage >= 2) { printf("VKICD stage %d: querying features through the same chain\n", stage); getFeatures2(d[0], &f2); f2.features = VkPhysicalDeviceFeatures{}; }
        printf("VKICD stage %d: vkCreateDevice (chain depth %d)\n", stage, stage == 0 ? 0 : stage == 1 ? 1 : stage == 2 ? 2 : 4);
        VkDevice dev = nullptr; VkResult dr = createDevice(d[0], &dci, nullptr, &dev); printf("VKICD stage %d: vkCreateDevice -> %d\n", stage, (int)dr);
        if (dr != VK_SUCCESS || !dev) failures++;
        else { auto destroy = (PFN_vkDestroyDevice)gipa(inst, "vkDestroyDevice"); if (destroy) destroy(dev, nullptr); }
    }
    puts(failures ? "RESULT FAIL" : "RESULT PASS"); return failures ? 1 : 0;
}
