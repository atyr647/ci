#!/usr/bin/env python3
"""Patches a Dawn checkout so the Vulkan backend compiles with the Cosmopolitan toolchain and picks the OS-specific parts at RUN time
(one binary, several operating systems). Idempotent: every edit is skipped when its marker is already present.
usage: patch.py <dawn-source-dir>"""
import sys, re, os
root = sys.argv[1]
MARK = 'COSMO-PATCH'

def edit(rel, fn):
    p = os.path.join(root, rel)
    s = open(p).read()
    if MARK in s:
        print('already patched:', rel); return
    t = fn(s)
    assert t != s, 'no change for ' + rel
    open(p, 'w').write(t); print('patched:', rel)

def insert_after_last_include(s, text):
    m = list(re.finditer(r'^#include .*$', s, re.M))[-1]
    return s[:m.end()] + '\n' + text + s[m.end():]

# 1. Cosmopolitan defines neither __linux__ nor _WIN32: treat it as Linux for compile-time platform detection
def platform_h(s):
    return s.replace('#elif defined(__linux__)\n', '#elif defined(__linux__) || defined(__COSMOPOLITAN__)  // %s\n' % MARK, 1)
edit('src/utils/platform.h', platform_h)

# 2. dlopen family -> cosmo_dlopen family; symbols are wrapped by cosmo_dltramp (thread-pointer / ABI switch) except on Windows,
#    where the Vulkan wrapper below calls them with the Microsoft ABI itself
def dynlib(s):
    hdr = ('// %s\n#ifdef __COSMOPOLITAN__\n#include <cosmo.h>\n#include <dlfcn.h>\n#ifndef RTLD_NOLOAD\n#define RTLD_NOLOAD 0\n#endif\n'
           '#define dlopen cosmo_dlopen\n#define dlsym cosmo_dlsym\n#define dlclose cosmo_dlclose\n#define dlerror cosmo_dlerror\n#endif\n') % MARK
    i = s.index('#include')
    return s[:i] + hdr + s[i:]
edit('src/dawn/common/DynamicLib.cpp', dynlib)

# 3. no dladdr in Cosmopolitan: the module is the executable
def sysutils(s):
    a = s.index('    static int placeholderSymbol = 0;')
    end = '    return absolutePath.data();\n'
    b = s.index(end, a) + len(end)
    return s[:a] + '#ifdef __COSMOPOLITAN__  // %s\n    return GetExecutablePath();\n#else\n' % MARK + s[a:b] + '#endif\n' + s[b:]
edit('src/dawn/common/SystemUtils.cpp', sysutils)

# 4. Vulkan library name chosen at run time
def backend(s):
    s = s.replace('constexpr char kVulkanLibName[] = "libvulkan.so.1";',
                  'constexpr char kVulkanLibName[] = "libvulkan.so.1";  // %s' % MARK, 1)
    s = s.replace('DAWN_TRY(LoadVulkan(kVulkanLibName));',
                  '''#ifdef __COSMOPOLITAN__
            DAWN_TRY(LoadVulkan(IsWindows() ? "vulkan-1.dll" : IsXnu() ? "libvulkan.dylib" : kVulkanLibName));
#else
            DAWN_TRY(LoadVulkan(kVulkanLibName));
#endif''', 1)
    return insert_after_last_include(s, '#ifdef __COSMOPOLITAN__\n#include <cosmo.h>\n#endif')
edit('src/dawn/native/vulkan/BackendVk.cpp', backend)

# 5. Vulkan entry points: one wrapper that calls Microsoft-ABI on Windows and System V (through cosmo_dltramp) elsewhere
def vkfns_h(s):
    old = '''template <typename R, typename... Args>
struct VkFnImpl<R(VKAPI_PTR*)(Args...)> {
#if DAWN_NO_SANITIZE_VK_FN'''
    new = '''#ifdef __COSMOPOLITAN__  // %s
extern "C" bool DawnCosmoIsWindows();  // defined in VulkanFunctions.cpp, which can include cosmo.h without its IsWindows() macro leaking into Dawn's headers
// Windows' Vulkan loader uses the Microsoft x64 calling convention, Linux and macOS use System V; the OS is only known at run time.
template <typename R, typename... Args>
struct DualAbiFn {
    using SysV = R (*)(Args...);
    using Ms = R(__attribute__((ms_abi)) *)(Args...);
    void* addr = nullptr;
    DualAbiFn() = default;
    DualAbiFn(std::nullptr_t) {}
    explicit DualAbiFn(void* a) : addr(a) {}
    R operator()(Args... args) const {
        return DawnCosmoIsWindows() ? reinterpret_cast<Ms>(addr)(args...) : reinterpret_cast<SysV>(addr)(args...);
    }
    bool operator==(std::nullptr_t) const { return addr == nullptr; }
    bool operator!=(std::nullptr_t) const { return addr != nullptr; }
    explicit operator bool() const { return addr != nullptr; }
};
#endif

template <typename R, typename... Args>
struct VkFnImpl<R(VKAPI_PTR*)(Args...)> {
#if defined(__COSMOPOLITAN__)
    using type = DualAbiFn<R, Args...>;
#elif DAWN_NO_SANITIZE_VK_FN''' % MARK
    assert old in s
    s = s.replace(old, new, 1)
    s = s.replace('    PFN_vkGetInstanceProcAddr GetInstanceProcAddr = nullptr;', '    VkFn<PFN_vkGetInstanceProcAddr> GetInstanceProcAddr = nullptr;', 1)
    return insert_after_last_include(s, '#ifdef __COSMOPOLITAN__\n#include <cstddef>\n#endif')
edit('src/dawn/native/vulkan/VulkanFunctions.h', vkfns_h)

def vkfns_cpp(s):
    old = '#else\n\ntemplate <typename F>\nF AsVkFn(void(VKAPI_PTR* addr)()) {'
    new = '''#elif defined(__COSMOPOLITAN__)  // %s

template <typename F>
VkFn<F> AsVkFn(void(VKAPI_PTR* addr)()) {
    if (addr == nullptr) {
        return VkFn<F>(nullptr);
    }
    // Windows: the raw pointer, called with the Microsoft ABI by DualAbiFn. Elsewhere: a cosmo_dltramp thunk.
    return VkFn<F>(DawnCosmoIsWindows() ? reinterpret_cast<void*>(addr) : cosmo_dltramp(reinterpret_cast<void*>(addr)));
}

#else

template <typename F>
F AsVkFn(void(VKAPI_PTR* addr)()) {''' % MARK
    assert old in s
    s = s.replace(old, new, 1)
    old2 = '''    if (!vulkanLib.GetProc(&GetInstanceProcAddr, "vkGetInstanceProcAddr")) {
        return DAWN_UNRECOVERABLE_ERROR("Couldn't get vkGetInstanceProcAddr");
    }
'''
    new2 = '''#ifdef __COSMOPOLITAN__
    {
        PFN_vkGetInstanceProcAddr raw = nullptr;
        if (!vulkanLib.GetProc(&raw, "vkGetInstanceProcAddr")) {
            return DAWN_UNRECOVERABLE_ERROR("Couldn't get vkGetInstanceProcAddr");
        }
        GetInstanceProcAddr = AsVkFn<PFN_vkGetInstanceProcAddr>(reinterpret_cast<void(VKAPI_PTR*)()>(raw));
    }
#else
    if (!vulkanLib.GetProc(&GetInstanceProcAddr, "vkGetInstanceProcAddr")) {
        return DAWN_UNRECOVERABLE_ERROR("Couldn't get vkGetInstanceProcAddr");
    }
#endif
'''
    assert old2 in s
    s = s.replace(old2, new2, 1)
    return insert_after_last_include(s, '#ifdef __COSMOPOLITAN__\n#include <cosmo.h>\n#include <dlfcn.h>\nextern "C" bool DawnCosmoIsWindows() { return IsWindows(); }\n#undef IsWindows\n#endif')
edit('src/dawn/native/vulkan/VulkanFunctions.cpp', vkfns_cpp)

# 6. Cosmopolitan's own headers #undef __linux__, so code that tests it directly needs the extra clause
edit('include/dawn/native/VulkanBackend.h', lambda s: s.replace('#if defined(__linux__) || defined(__Fuchsia__)\n', '#if defined(__linux__) || defined(__COSMOPOLITAN__) || defined(__Fuchsia__)  // %s\n' % MARK, 1))
edit('third_party/renderdoc/renderdoc/api/app/renderdoc_app.h', lambda s: s.replace('#elif defined(__linux__) ||', '#elif defined(__linux__) || defined(__COSMOPOLITAN__) /* %s */ ||' % MARK, 1))

# 7. Cosmopolitan resolves OS constants (POLLIN, O_*, errno values...) at run time, so they cannot initialise a constexpr
edit('src/dawn/native/WaitAnySystemEvent.cpp', lambda s: s.replace('static constexpr int kAllowedEvents = POLLIN | POLLHUP;', 'const int kAllowedEvents = POLLIN | POLLHUP;  // %s' % MARK, 1))

# 8. call sites that assumed Vulkan entry points are plain function pointers
edit('src/dawn/native/vulkan/VulkanBackend.cpp', lambda s: s.replace('(*backendDevice->fn.GetInstanceProcAddr)(', 'backendDevice->fn.GetInstanceProcAddr(  /* %s */ ' % MARK, 1))
def devicevk(s):
    a = s.index('    if (IsToggleEnabled(Toggle::VulkanSkipDraw)) {')
    b = s.index('    }\n', a) + len('    }\n')
    return s[:a] + '#ifndef __COSMOPOLITAN__  // %s: test-only toggle that stores raw System V function pointers\n' % MARK + s[a:b] + '#endif\n' + s[b:]
edit('src/dawn/native/vulkan/DeviceVk.cpp', devicevk)
