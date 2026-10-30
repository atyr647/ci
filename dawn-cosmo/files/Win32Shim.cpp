// Win32 functions the Windows-flavoured Dawn translation units (D3D12 backend) call, provided for a Cosmopolitan binary.
//
// Those translation units are compiled against Wine's headers, so they call Win32 functions with the Microsoft x64 calling convention. Cosmopolitan has its own
// bindings for many of the same functions under the same names, but those use the System V convention (and a few functions are missing altogether). To keep the two
// apart, win32_rename.h (force-included in the Windows-flavoured units) renames every Win32 function they use to dawn_w32_<Name>; this file defines those names.
// Each one looks the real function up in the real DLL the first time it is called and then jumps to it - nothing here runs unless the program is on Windows.
#include <cstddef>
#include <cstdint>

extern "C" {
// Cosmopolitan's bindings, System V convention, Windows only
int64_t LoadLibraryA(const char* name);
void* GetProcAddress(int64_t module, const char* name);
}

namespace {
void* Resolve(const char* dll, const char* name) {
    const int64_t module = LoadLibraryA(dll);
    return module ? GetProcAddress(module, name) : nullptr;
}
}  // namespace

#define MS __attribute__((ms_abi))
// Defines  RET dawn_w32_NAME PARAMS  forwarding to NAME in DLL. A missing export returns zero (the callers treat that as failure).
#define W32(RET, NAME, DLL, PARAMS, ARGS)                                         \
    extern "C" MS RET dawn_w32_##NAME PARAMS {                                    \
        using F = RET(MS*) PARAMS;                                                \
        static F f = reinterpret_cast<F>(Resolve(DLL, #NAME));                    \
        return f ? f ARGS : RET();                                                \
    }

W32(int32_t, CompareObjectHandles, "kernel32.dll", (void* a, void* b), (a, b))
W32(void*, CreateEventA, "kernel32.dll", (void* sa, int32_t manual, int32_t initial, const char* name), (sa, manual, initial, name))
W32(void, GetSystemTime, "kernel32.dll", (void* st), (st))
W32(void, GetSystemTimeAsFileTime, "kernel32.dll", (void* ft), (ft))
W32(int32_t, MultiByteToWideChar, "kernel32.dll", (uint32_t cp, uint32_t flags, const char* s, int32_t n, uint16_t* out, int32_t outn), (cp, flags, s, n, out, outn))
W32(int32_t, QueryPerformanceFrequency, "kernel32.dll", (int64_t * f), (f))
W32(int32_t, RegCloseKey, "advapi32.dll", (void* key), (key))
W32(int32_t, RegOpenKeyExW, "advapi32.dll", (void* key, const uint16_t* sub, uint32_t opts, uint32_t sam, void** out), (key, sub, opts, sam, out))
W32(int32_t, RegQueryValueExA, "advapi32.dll", (void* key, const char* name, uint32_t* reserved, uint32_t* type, uint8_t* data, uint32_t* cb), (key, name, reserved, type, data, cb))
W32(int32_t, ResetEvent, "kernel32.dll", (void* e), (e))
W32(uint64_t, VerSetConditionMask, "kernel32.dll", (uint64_t mask, uint32_t type, uint8_t cond), (mask, type, cond))
W32(int32_t, VerifyVersionInfoW, "kernel32.dll", (void* info, uint32_t mask, uint64_t cond), (info, mask, cond))

// Windows' wchar_t is 16 bits; the Windows-flavoured units are compiled with -fshort-wchar and -Dwcslen=dawn_wcslen16 so that this function, not the C library's
// 32-bit wchar_t one, measures their strings.
extern "C" size_t dawn_wcslen16(const uint16_t* s) {
    size_t n = 0;
    while (s[n]) {
        ++n;
    }
    return n;
}

// GUID constant normally linked from dxguid.lib
extern "C" {
extern const struct DawnGuid {
    uint32_t a;
    uint16_t b, c;
    uint8_t d[8];
} WKPDID_D3DDebugObjectName;
const struct DawnGuid WKPDID_D3DDebugObjectName = {0x429b8c22, 0x9188, 0x4b0c, {0x87, 0x42, 0xac, 0xb0, 0xbf, 0x85, 0xc2, 0x00}};
}
