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
           '#include "src/dawn/native/vulkan/DawnCosmoForeign.h"\n#define dlopen DawnCosmoDlopen\n#define dlsym DawnCosmoDlsym\n#define dlclose cosmo_dlclose\n#define dlerror cosmo_dlerror\n#endif\n') % MARK
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
extern "C" bool DawnCosmoIsWindows();
extern "C" bool DawnCosmoDirect();
extern "C" bool DawnCosmoDirectOk();   // arm64 Linux: true when THIS thread keeps asynchronous signals blocked (DawnCosmoGpuThreadEnter), which is what makes a raw call into the driver safe
extern "C" bool DawnCosmoTrace();                                  // DAWN_COSMO_TRACE=1 prints every Vulkan call (name) to stderr
extern "C" void DawnCosmoTraceCall(const char* name, void* addr);  // defined in VulkanFunctions.cpp, which can include cosmo.h without its IsWindows() macro leaking into Dawn's headers
// Windows' Vulkan loader uses the Microsoft x64 calling convention, Linux and macOS use System V; the OS is only known at run time.
template <typename R, typename... Args>
struct DualAbiFn {
    using SysV = R (*)(Args...);
    using Ms = R(__attribute__((ms_abi)) *)(Args...);
    void* addr = nullptr;   // what is called: the cosmo_dltramp thunk (the raw pointer on Windows and x86-64, where there is none)
    void* raw = nullptr;    // the driver's own entry point, called instead of the thunk on threads that block asynchronous signals (arm64 Linux)
    const char* name = "?";   // for DAWN_COSMO_TRACE=1
    DualAbiFn() = default;
    DualAbiFn(std::nullptr_t) {}
    explicit DualAbiFn(void* a, void* r = nullptr) : addr(a), raw(r ? r : a) {}
    // GCC merges "cond ? ms_abi_call(args) : sysv_call(args)" into ONE System V call and drops the Microsoft one (the calling convention is not part of
    // what its tail-merging/cross-jumping compares) - measured: Windows then called vulkan-1.dll with System V registers. The two differently-worded asm
    // statements keep the branches distinct; noinline keeps one out-of-line copy per signature.
    __attribute__((noinline)) R operator()(Args... args) const {
        if (DawnCosmoTrace()) {
            DawnCosmoTraceCall(name, addr);
        }
        if (DawnCosmoIsWindows()) {
            __asm__ volatile("# dawn-cosmo: Microsoft x64 call" ::: "memory");
            return reinterpret_cast<Ms>(addr)(args...);
        }
        __asm__ volatile("# dawn-cosmo: System V call" ::: "memory");
        if (unsigned long tcb = DawnCosmoForeignTcb()) {   // a thread the C library created: the driver runs on a parked thread's thread block (DawnCosmoForeign.h)
            DawnCosmoForeignScope scope(tcb);
            return reinterpret_cast<SysV>(raw)(args...);
        }
        return reinterpret_cast<SysV>(raw != addr && DawnCosmoDirectOk() ? raw : addr)(args...);
    }
    bool operator==(std::nullptr_t) const { return addr == nullptr; }
    bool operator!=(std::nullptr_t) const { return addr != nullptr; }
    explicit operator bool() const { return addr != nullptr; }
};
template <typename R, typename... Args>
DualAbiFn<R, Args...> DawnCosmoNamed(DualAbiFn<R, Args...> f, const char* n) {
    f.name = n;
    return f;
}
#endif  // __COSMOPOLITAN__ (outer)

template <typename R, typename... Args>
struct VkFnImpl<R(VKAPI_PTR*)(Args...)> {
#if defined(__COSMOPOLITAN__)
    using type = DualAbiFn<R, Args...>;
#elif DAWN_NO_SANITIZE_VK_FN''' % MARK
    assert old in s
    s = s.replace(old, new, 1)
    s = s.replace('    PFN_vkGetInstanceProcAddr GetInstanceProcAddr = nullptr;', '    VkFn<PFN_vkGetInstanceProcAddr> GetInstanceProcAddr = nullptr;', 1)
    return insert_after_last_include(s, '#ifdef __COSMOPOLITAN__\n#include <cstddef>\n#include "src/dawn/native/vulkan/DawnCosmoForeign.h"\n#endif')
import shutil
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'DawnCosmoForeign.h'), os.path.join(root, 'src/dawn/native/vulkan/DawnCosmoForeign.h'))   # always refreshed
edit('src/dawn/native/vulkan/VulkanFunctions.h', vkfns_h)

def vkfns_cpp(s):
    old = '#else\n\ntemplate <typename F>\nF AsVkFn(void(VKAPI_PTR* addr)()) {'
    new = '''#elif defined(__COSMOPOLITAN__)  // %s

template <typename F>
VkFn<F> AsVkFn(void(VKAPI_PTR* addr)()) {
    if (addr == nullptr) {
        return VkFn<F>(nullptr);
    }
    // Windows: the raw pointer, called with the Microsoft ABI by DualAbiFn. Elsewhere: a cosmo_dltramp thunk (none on x86-64; on arm64 each call through it blocks and unblocks ALL signals with two
    // rt_sigprocmask system calls, 450 ns). Driver code may use x28 (Cosmopolitan's thread register on arm64) as an ordinary register, so a signal handler of ours that ran inside it would read
    // thread-local storage through garbage (measured: SIGSEGV). Threads that called DawnCosmoGpuThreadEnter keep asynchronous signals blocked for good and DualAbiFn then calls the raw pointer;
    // every other thread keeps using the thunk. Synchronous faults stay unblocked, as before (a fault inside the driver ends the process either way).
    DawnCosmoForeignInit();   // once, on the thread that loads the Vulkan functions (the main thread): parked threads whose thread blocks other threads borrow for driver calls
    void* raw = reinterpret_cast<void*>(addr);
    return VkFn<F>(DawnCosmoIsWindows() ? raw : cosmo_dltramp(raw), raw);
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
    s = s.replace('name = AsVkFn<PFN_vk##name>(GetInstanceProcAddr(nullptr, "vk" #name));', 'name = DawnCosmoNamed(AsVkFn<PFN_vk##name>(GetInstanceProcAddr(nullptr, "vk" #name)), "vk" #name);', 1)
    s = s.replace('name = AsVkFn<PFN_vk##name>(GetInstanceProcAddr(instance, "vk" #procName))', 'name = DawnCosmoNamed(AsVkFn<PFN_vk##name>(GetInstanceProcAddr(instance, "vk" #procName)), "vk" #procName)', 1)
    s = s.replace('name = AsVkFn<PFN_vk##name>(GetDeviceProcAddr(device, "vk" #name));', 'name = DawnCosmoNamed(AsVkFn<PFN_vk##name>(GetDeviceProcAddr(device, "vk" #name)), "vk" #name);', 1)
    return insert_after_last_include(s, '#ifdef __COSMOPOLITAN__\n#define DAWN_COSMO_FOREIGN_IMPL\n#include <cosmo.h>\n#include "src/dawn/native/vulkan/DawnCosmoForeign.h"\n#include <dlfcn.h>\n#include <cstdio>\n#include <cstdlib>\nextern "C" bool DawnCosmoIsWindows() { return IsWindows(); }\nextern "C" bool DawnCosmoIsXnu() { return IsXnu(); }\n#if defined(__aarch64__)\n#include <signal.h>\n#include <pthread.h>\nextern "C" bool DawnCosmoDirect() { static const bool on = IsLinux() && !(getenv("DAWN_COSMO_DIRECT") && getenv("DAWN_COSMO_DIRECT")[0] == 48); return on; }\nstatic thread_local bool gDawnCosmoAsyncBlocked;\nstatic thread_local sigset_t gDawnCosmoSavedMask;\nextern "C" bool DawnCosmoDirectOk() { return gDawnCosmoAsyncBlocked; }\nextern "C" void DawnCosmoGpuThreadEnter() { if (gDawnCosmoAsyncBlocked || !DawnCosmoDirect()) return; sigset_t m; sigfillset(&m); sigdelset(&m, SIGSEGV); sigdelset(&m, SIGBUS); sigdelset(&m, SIGFPE); sigdelset(&m, SIGILL); sigdelset(&m, SIGTRAP); pthread_sigmask(SIG_BLOCK, &m, &gDawnCosmoSavedMask); gDawnCosmoAsyncBlocked = true; }\nextern "C" void DawnCosmoGpuThreadLeave() { if (!gDawnCosmoAsyncBlocked) return; pthread_sigmask(SIG_SETMASK, &gDawnCosmoSavedMask, nullptr); gDawnCosmoAsyncBlocked = false; }\n#else\nextern "C" bool DawnCosmoDirect() { return false; }\nextern "C" bool DawnCosmoDirectOk() { return false; }\nextern "C" void DawnCosmoGpuThreadEnter() {}\nextern "C" void DawnCosmoGpuThreadLeave() {}\n#endif\nextern "C" bool DawnCosmoInlineWorkers() { static const int on = getenv("DAWN_COSMO_INLINE_WORKERS") ? atoi(getenv("DAWN_COSMO_INLINE_WORKERS")) : 0; return on != 0; }\nextern "C" bool DawnCosmoTrace() { static const bool on = getenv("DAWN_COSMO_TRACE") != nullptr; return on; }\nextern "C" void DawnCosmoTraceCall(const char* name, void* addr) { (void)addr; fprintf(stderr, "[vk] %s\\n", name); fflush(stderr); }\n#undef IsWindows\n#endif')
edit('src/dawn/native/vulkan/VulkanFunctions.cpp', vkfns_cpp)

# 8b. Dawn's worker threads (async pipeline creation, called into the driver from a thread the C library created): on x86-64 Linux the foreign C library's thread-local
#     storage does not exist on such threads (measured: SIGSEGV in libc.so.6 reading a ctype table), so tasks posted to the worker pool run on the posting thread there.
def workerthread(s):
    old = '    Ref<AsyncTaskHandleImpl> handle = AcquireRef(new AsyncTaskHandleImpl(callback, userdata));\n    Ref<AsyncJobHandleImpl> job;'
    new = '    Ref<AsyncTaskHandleImpl> handle = AcquireRef(new AsyncTaskHandleImpl(callback, userdata));\n#ifdef __COSMOPOLITAN__  // %s\n    if (DawnCosmoInlineWorkers()) {\n        handle->Complete();\n        return std::make_unique<AsyncWaitableEvent>(handle);\n    }\n#endif\n    Ref<AsyncJobHandleImpl> job;' % MARK
    assert old in s
    s = s.replace(old, new, 1)
    return insert_after_last_include(s, '#ifdef __COSMOPOLITAN__\nextern "C" bool DawnCosmoInlineWorkers();\n#endif')
edit('src/dawn/platform/WorkerThread.cpp', workerthread)


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

# 9. Foreign code (the Vulkan loader) must not call back into Cosmopolitan code: on Windows the loader would use the Microsoft ABI, on aarch64
#    the thread register (x28) is clobbered. So no debug-utils messengers are registered; driver messages simply are not forwarded to Dawn's log.
p = os.path.join(root, 'src/dawn/native/vulkan/BackendVk.cpp')
s = open(p).read()
if 'COSMO-PATCH-NOCALLBACKS' not in s:
    a = 'if (usedGlobalKnobs.HasExt(InstanceExt::DebugUtils)) {\n        // Workaround'
    b = 'if (usedKnobs.HasExt(InstanceExt::DebugUtils)) {\n        utilsMessengerCreateInfo.flags = 0;'
    assert a in s and b in s
    s = s.replace(a, 'if (false /* COSMO-PATCH-NOCALLBACKS */ && usedGlobalKnobs.HasExt(InstanceExt::DebugUtils)) {\n        // Workaround', 1)
    s = s.replace(b, 'if (false && usedKnobs.HasExt(InstanceExt::DebugUtils)) {\n        utilsMessengerCreateInfo.flags = 0;', 1)
    open(p, 'w').write(s); print('patched: no debug messengers')

# 10. macOS: MoltenVK is a "portability" driver. The loader only lists it when the instance enables VK_KHR_portability_enumeration and sets the
#     matching create flag, otherwise vkCreateInstance returns VK_ERROR_INCOMPATIBLE_DRIVER (measured on macOS arm64, native Dawn and Cosmopolitan Dawn alike).
p = os.path.join(root, 'src/dawn/native/vulkan/BackendVk.cpp')
s = open(p).read()
if 'COSMO-PATCH-PORTABILITY' not in s:
    a = '    VkApplicationInfo appInfo;\n    appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;'
    assert a in s
    s = s.replace(a, '''    // COSMO-PATCH-PORTABILITY
    bool enumeratePortability = false;
#ifdef __COSMOPOLITAN__
    if (IsXnu()) {
        uint32_t extCount = 0;
        mFunctions.EnumerateInstanceExtensionProperties(nullptr, &extCount, nullptr);
        std::vector<VkExtensionProperties> extProps(extCount);
        mFunctions.EnumerateInstanceExtensionProperties(nullptr, &extCount, extProps.data());
        for (const VkExtensionProperties& e : extProps) {
            if (std::string(e.extensionName) == "VK_KHR_portability_enumeration") {
                enumeratePortability = true;
            }
        }
        if (enumeratePortability) {
            extensionNames.push_back("VK_KHR_portability_enumeration");
        }
    }
#endif

''' + a, 1)
    b = '    createInfo.flags = 0;\n    createInfo.pApplicationInfo = &appInfo;'
    assert b in s
    s = s.replace(b, '    createInfo.flags = enumeratePortability ? 0x00000001 : 0;  // VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR\n    createInfo.pApplicationInfo = &appInfo;', 1)
    open(p, 'w').write(s); print('patched: portability enumeration')

# ----------------------------------------------------------------------------------------------------------------------------------------------------------------
# 11. Platform flavours. One Cosmopolitan binary contains translation units that pretend to be Windows (the D3D12 backend, DAWN_COSMO_AS_WINDOWS) and ones that pretend
#     to be Apple (the Metal backend, DAWN_COSMO_AS_APPLE) next to the POSIX/Linux-flavoured rest. Dawn's platform detection honours both macros.
def platform_flavours(s):
    s = s.replace('#if defined(_WIN32) || defined(_WIN64)\n', '#if defined(_WIN32) || defined(_WIN64) || defined(DAWN_COSMO_AS_WINDOWS)  // COSMO-PATCH-FLAVOURS\n', 1)
    s = s.replace('#elif defined(__linux__) || defined(__COSMOPOLITAN__)  // COSMO-PATCH\n', '#elif (defined(__linux__) || defined(__COSMOPOLITAN__)) && !defined(DAWN_COSMO_AS_APPLE)  // COSMO-PATCH\n', 1)
    return s
p = os.path.join(root, 'src/utils/platform.h')
s = open(p).read()
if 'COSMO-PATCH-FLAVOURS' not in s:
    t = platform_flavours(s); assert t != s and 'COSMO-PATCH-FLAVOURS' in t; open(p, 'w').write(t); print('patched: platform flavours')

# 12. The D3D12 backend inside the Cosmopolitan binary (only when DAWN_COSMO_D3D12=1: Windows runs x86-64 code only, so the aarch64 build does not need it).
#     The pieces of Dawn that the Windows-flavoured units share with the rest (SystemHandle, SystemEvent, WaitAnySystemEvent, DynamicLib) must have ONE layout and
#     ONE implementation that chooses Windows or POSIX behaviour when the program runs.
if os.environ.get('DAWN_COSMO_D3D12') == '1':
    import shutil
    files = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'files')
    def edit2(rel, mark, fn):
        p = os.path.join(root, rel); s = open(p).read()
        if mark in s: print('already patched:', rel, mark); return
        t = fn(s); assert t != s, 'no change for ' + rel
        open(p, 'w').write(t); print('patched:', rel, mark)

    # whole-file replacements (derived from Dawn's, licence kept)
    for rel, name in (('src/dawn/common/SystemHandle.cpp', 'SystemHandle.cpp'), ('src/dawn/native/SystemEvent.cpp', 'SystemEvent.cpp'), ('src/dawn/native/WaitAnySystemEvent.cpp', 'WaitAnySystemEvent.cpp')):
        shutil.copyfile(os.path.join(files, name), os.path.join(root, rel)); print('replaced:', rel)

    def syshandle_h(s):
        s = s.replace('class SystemHandle : public NonCopyable {', 'class alignas(8) SystemHandle : public NonCopyable {  // COSMO-PATCH-D3D12: 8 bytes in both platform flavours', 1)
        s = s.replace('    void Close();\n', '''    void Close();

    // COSMO-PATCH-D3D12: the Windows-flavoured and the POSIX-flavoured translation units of one binary share this class. Its constructor from the other
    // spelling of a handle (a Windows HANDLE is a void*, a POSIX fd an int), and the full 64-bit value, are implemented once, in SystemHandle.cpp.
#if !DAWN_PLATFORM_IS(WINDOWS)
    explicit SystemHandle(void* windowsHandle);
#endif
    int64_t GetRawCosmo() const;
    static SystemHandle AcquireRawCosmo(int64_t raw);
''', 1)
        s = s.replace('    Handle mHandle;\n};', '''    Handle mHandle;
#if !DAWN_PLATFORM_IS(WINDOWS)
    int mHandleHigh = 0;  // COSMO-PATCH-D3D12: upper half of the 64-bit value a Windows HANDLE occupies
#endif
};''', 1)
        return s
    edit2('src/dawn/common/SystemHandle.h', 'COSMO-PATCH-D3D12', syshandle_h)

    def dynlib_h(s):
        old = '''#if DAWN_PLATFORM_IS(WINDOWS) && !DAWN_PLATFORM_IS(WINUWP)
    bool OpenSystemLibrary(std::wstring_view filename, std::string* error = nullptr);
#endif'''
        new = '''#if DAWN_PLATFORM_IS(WINDOWS) && !DAWN_PLATFORM_IS(WINUWP)
    // COSMO-PATCH-D3D12: inline, because only the Windows-flavoured units (16-bit wchar_t) ever call it; system library names are ASCII. Open() is the one
    // implementation (cosmo_dlopen, which loads DLLs when the program runs on Windows).
    bool OpenSystemLibrary(std::wstring_view filename, std::string* error = nullptr) {
        std::string narrow;
        for (auto c : filename) {
            narrow.push_back(static_cast<char>(c));
        }
        return Open(narrow, error);
    }
#endif'''
        assert old in s
        return s.replace(old, new, 1)
    edit2('src/dawn/common/DynamicLib.h', 'COSMO-PATCH-D3D12', dynlib_h)

    def instance_cpp(s):
        s = s.replace('#if defined(DAWN_ENABLE_BACKEND_D3D11) || defined(DAWN_ENABLE_BACKEND_D3D12)\n#include "dawn/native/D3DBackend.h"\n#include "src/dawn/native/d3d/BackendD3D.h"\n#include "src/dawn/native/d3d/D3DError.h"\n#endif  // defined(DAWN_ENABLE_BACKEND_D3D11) || defined(DAWN_ENABLE_BACKEND_D3D12)\n',
                      '// COSMO-PATCH-D3D12: the D3D headers need the Windows-flavoured parse; this file only needs the Connect() declaration below\n', 1)
        s = s.replace('            Register(d3d12::Connect(this), wgpu::BackendType::D3D12);\n', '''            if (DawnCosmoIsWindows()) {
                BackendConnection* d3d12Connection = d3d12::Connect(this);
                if (getenv("DAWN_COSMO_TRACE")) {
                    fprintf(stderr, "[dawn-cosmo] d3d12::Connect -> %p\\n", static_cast<void*>(d3d12Connection));
                }
                Register(d3d12Connection, wgpu::BackendType::D3D12);
            } else if (getenv("DAWN_COSMO_TRACE")) {
                fprintf(stderr, "[dawn-cosmo] D3D12 skipped: not running on Windows\\n");
            }
''', 1)
        # Windows uses D3D12 only: the Vulkan backend is not started there (decided 2026-10-30; the Vulkan-on-Windows run crashed after "map readback" and is not worth fixing)
        s = s.replace('            Register(vulkan::Connect(this), wgpu::BackendType::Vulkan);\n', '            if (!DawnCosmoIsWindows()) {\n                Register(vulkan::Connect(this), wgpu::BackendType::Vulkan);\n            }\n', 1)
        s = s.replace('namespace dawn::native {\n', '#include <cstdio>\n#include <cstdlib>\nextern "C" bool DawnCosmoIsWindows();  // COSMO-PATCH-D3D12 (defined in vulkan/VulkanFunctions.cpp)\n\nnamespace dawn::native {\n', 1)
        return s
    edit2('src/dawn/native/Instance.cpp', 'COSMO-PATCH-D3D12', instance_cpp)

    # the Windows-flavoured translation units and the shim that backs them
    def native_cmake(s):
        return s + '''
# COSMO-PATCH-D3D12: the D3D and D3D12 sources are compiled as if for Windows (Wine headers, see dawn-cosmo/d3d12.md); everything else stays POSIX-flavoured.
if (DAWN_COSMO_D3D12 AND DAWN_ENABLE_D3D12)
    file(GLOB _cosmo_win_srcs RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" "d3d/*.cpp" "d3d12/*.cpp")
    list(APPEND _cosmo_win_srcs "WindowsUtilsCosmo.cpp")   # Dawn's WindowsUtils.cpp (UTF-8 <-> UTF-16), only built for WIN32 upstream
    set_source_files_properties(${_cosmo_win_srcs} PROPERTIES COMPILE_OPTIONS "${DAWN_COSMO_D3D12_FLAGS}")
    target_sources(dawn_native_objects PRIVATE "WindowsUtilsCosmo.cpp" "${DAWN_COSMO_FILES_DIR}/Win32Shim.cpp")
endif()
'''
    edit2('src/dawn/native/CMakeLists.txt', 'COSMO-PATCH-D3D12', native_cmake)
    shutil.copyfile(os.path.join(root, 'src/dawn/common/WindowsUtils.cpp'), os.path.join(root, 'src/dawn/native/WindowsUtilsCosmo.cpp'))   # built as a Windows-flavoured unit

    # step-by-step trace of adapter discovery (DAWN_COSMO_TRACE=1), to see where a silent failure happens
    def backend_d3d_trace(s):
        s = s.replace('namespace dawn::native::d3d {\n', '#define DAWN_COSMO_T(...) do { if (getenv("DAWN_COSMO_TRACE")) { fprintf(stderr, "[d3d] " __VA_ARGS__); fprintf(stderr, "\\n"); fflush(stderr); } } while (0)\n\nnamespace dawn::native::d3d {\n', 1)
        s = s.replace('    if (options->forceFallbackAdapter) {\n        return {};\n    }\n', '    DAWN_COSMO_T("DiscoverPhysicalDevices begin, forceFallback=%d", int(options->forceFallbackAdapter));\n    if (options->forceFallbackAdapter) {\n        return {};\n    }\n', 1)
        s = s.replace('    HRESULT hr = GetFactory()->QueryInterface(IID_PPV_ARGS(&factory6));\n', '    DAWN_COSMO_T("factory %p, asking for IDXGIFactory6", (void*)GetFactory());\n    HRESULT hr = GetFactory()->QueryInterface(IID_PPV_ARGS(&factory6));\n    DAWN_COSMO_T("IDXGIFactory6 hr=0x%08x", unsigned(hr));\n', 1)
        s = s.replace('        if (enumAdapters(adapterIndex, dxgiAdapter) == DXGI_ERROR_NOT_FOUND) {\n', '        DAWN_COSMO_T("enumerating adapter %u", adapterIndex);\n        HRESULT enumHr = enumAdapters(adapterIndex, dxgiAdapter);\n        DAWN_COSMO_T("enumerate -> hr=0x%08x adapter=%p", unsigned(enumHr), (void*)dxgiAdapter.Get());\n        if (enumHr == DXGI_ERROR_NOT_FOUND) {\n', 1)
        s = s.replace('        Ref<PhysicalDeviceBase> physicalDevice;\n        if (GetInstance()->ConsumedErrorAndWarnOnce(\n                GetOrCreatePhysicalDeviceFromIDXGIAdapter(', '        DAWN_COSMO_T("creating the physical device");\n        Ref<PhysicalDeviceBase> physicalDevice;\n        if (GetInstance()->ConsumedErrorAndWarnOnce(\n                GetOrCreatePhysicalDeviceFromIDXGIAdapter(', 1)
        return s
    edit2('src/dawn/native/d3d/BackendD3D.cpp', 'DAWN_COSMO_T', backend_d3d_trace)

    T_MACRO = '#define DAWN_COSMO_T(...) do { if (getenv("DAWN_COSMO_TRACE")) { fprintf(stderr, "[d3d12] " __VA_ARGS__); fprintf(stderr, "\\n"); fflush(stderr); } } while (0)\n\n'
    def backend_d3d12_trace(s):
        s = s.replace('namespace dawn::native::d3d12 {\n', T_MACRO + 'namespace dawn::native::d3d12 {\n', 1)
        old = '    DAWN_TRY(CheckHRESULT(\n        GetFunctions()->CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)),\n        "D3D12CreateDevice"));\n'
        new = '    DAWN_COSMO_T("D3D12CreateDevice(adapter=%p)", (void*)adapter);\n    HRESULT cosmoHr = GetFunctions()->CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device));\n    DAWN_COSMO_T("D3D12CreateDevice -> 0x%08x device=%p", unsigned(cosmoHr), (void*)device.Get());\n    DAWN_TRY(CheckHRESULT(cosmoHr, "D3D12CreateDevice"));\n'
        assert old in s
        s = s.replace(old, new, 1)
        s = s.replace('    ComPtr<IDXGIAdapter3> dxgiAdapter3;\n    DAWN_TRY(CheckHRESULT(dxgiAdapter.As(&dxgiAdapter3), "DXGIAdapter retrieval"));\n', '    DAWN_COSMO_T("CreatePhysicalDeviceFromIDXGIAdapter: asking for IDXGIAdapter3");\n    ComPtr<IDXGIAdapter3> dxgiAdapter3;\n    DAWN_TRY(CheckHRESULT(dxgiAdapter.As(&dxgiAdapter3), "DXGIAdapter retrieval"));\n    DAWN_COSMO_T("have IDXGIAdapter3, initializing the physical device");\n', 1)
        return s
    edit2('src/dawn/native/d3d12/BackendD3D12.cpp', 'DAWN_COSMO_T', backend_d3d12_trace)
    def physdev_trace(s):
        s = s.replace('namespace dawn::native::d3d12 {\n', T_MACRO + 'namespace dawn::native::d3d12 {\n', 1)
        old = '    DAWN_TRY(Base::InitializeImpl());\n    // D3D12 cannot check for feature support without a device.'
        new = '    DAWN_COSMO_T("PhysicalDevice::InitializeImpl begin");\n    DAWN_TRY(Base::InitializeImpl());\n    DAWN_COSMO_T("base initialized");\n    // D3D12 cannot check for feature support without a device.'
        assert old in s
        s = s.replace(old, new, 1)
        s = s.replace('    DAWN_TRY(CheckD3D12Blocklist());\n', '    DAWN_COSMO_T("device created, checking the blocklist");\n    DAWN_TRY(CheckD3D12Blocklist());\n    DAWN_COSMO_T("blocklist ok, debug layer filters");\n', 1)
        s = s.replace('    DAWN_TRY_ASSIGN(mDeviceInfo, GatherDeviceInfo(*this));\n', '    DAWN_COSMO_T("gathering device info");\n    DAWN_TRY_ASSIGN(mDeviceInfo, GatherDeviceInfo(*this));\n    DAWN_COSMO_T("device info gathered");\n', 1)
        return s
    edit2('src/dawn/native/d3d12/PhysicalDeviceD3D12.cpp', 'DAWN_COSMO_T', physdev_trace)
    def info_trace(s):
        s = s.replace('namespace dawn::native::d3d12 {\n', T_MACRO + 'namespace dawn::native::d3d12 {\n', 1)
        s = s.replace('    D3D12DeviceInfo info = {};\n\n    ComPtr<ID3D12Device> d3d12Device = physicalDevice.GetDevice();\n', '    D3D12DeviceInfo info = {};\n\n    ComPtr<ID3D12Device> d3d12Device = physicalDevice.GetDevice();\n    DAWN_COSMO_T("GatherDeviceInfo: device %p", (void*)d3d12Device.Get());\n', 1)
        s = s.replace('    info.isUMA = arch.UMA;\n', '    DAWN_COSMO_T("architecture query ok");\n    info.isUMA = arch.UMA;\n', 1)
        return s
    edit2('src/dawn/native/d3d12/D3D12Info.cpp', 'DAWN_COSMO_T', info_trace)

# 11. Metal backend, linked in from objects built on macOS (dawn-cosmo/metal/): Dawn's own Instance.cpp reaches it through a weak symbol, so the x86-64 half
#     (which has no Metal objects) and every non-macOS host simply find no Metal backend. DAWN_ENABLE_BACKEND_METAL stays undefined in the Cosmopolitan build.
if os.environ.get('DAWN_COSMO_METAL') == '1':
    p = os.path.join(root, 'src/dawn/native/Instance.cpp'); s = open(p).read()
    if 'COSMO-PATCH-METAL' in s:
        print('already patched: Instance.cpp COSMO-PATCH-METAL')
    else:
        old = '#if defined(DAWN_ENABLE_BACKEND_VULKAN)\n        case wgpu::BackendType::Vulkan:\n'
        new = '''#if !defined(DAWN_ENABLE_BACKEND_METAL)   // COSMO-PATCH-METAL
        case wgpu::BackendType::Metal:
            if (DawnCosmoMetalConnect != nullptr) {
                Register(DawnCosmoMetalConnect(this), wgpu::BackendType::Metal);
            } else if (getenv("DAWN_COSMO_TRACE")) {
                fprintf(stderr, "[dawn-cosmo] Metal skipped: not linked into this half of the file\\n");
            }
            break;
#endif

''' + old
        assert old in s
        s = s.replace(old, new, 1)
        # macOS uses Metal only (no MoltenVK); the Vulkan backend can still be asked for with DAWN_COSMO_ALLOW_VULKAN=1 (used for comparisons)
        vk = '            Register(vulkan::Connect(this), wgpu::BackendType::Vulkan);\n'
        assert vk in s
        s = s.replace(vk, '            if (!DawnCosmoIsXnu() || getenv("DAWN_COSMO_ALLOW_VULKAN")) {\n                Register(vulkan::Connect(this), wgpu::BackendType::Vulkan);\n            }\n', 1)
        fn = 'BackendConnection* InstanceBase::GetBackendConnection(wgpu::BackendType backendType) {\n'
        assert fn in s
        s = s.replace(fn, '// COSMO-PATCH-METAL: defined by the Metal objects (dawn-cosmo/metal/MetalCosmo.mm) in the arm64 half only; null elsewhere\nextern "C" BackendConnection* DawnCosmoMetalConnect(InstanceBase* instance) __attribute__((weak));\nextern "C" bool DawnCosmoIsXnu();   // defined in vulkan/VulkanFunctions.cpp\n\n' + fn, 1)
        # the last #include of Instance.cpp sits inside a conditional (perfetto), so the C library headers go before the namespace instead
        s = s.replace('namespace dawn::native {\n', '#include <cstdio>\n#include <cstdlib>\n\nnamespace dawn::native {\n', 1)
        open(p, 'w').write(s); print('patched: Instance.cpp COSMO-PATCH-METAL')
