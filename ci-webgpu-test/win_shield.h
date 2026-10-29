/* Windows only, Cosmopolitan: turn every unknown SEH exception into a fatal SIGSEGV is what the runtime does, including the harmless DBG_PRINTEXCEPTION_C that
 * OutputDebugString raises (Dawn, the Vulkan loader, D3D12's debug layer and many other DLLs call it). A first-in-line vectored exception handler that
 * swallows the three debugger-message exceptions keeps those DLLs from killing the process. Include after <cosmo.h>; call win_shield_install() once. */
#ifndef WIN_SHIELD_H
#define WIN_SHIELD_H
#include <stdint.h>
#include <dlfcn.h>
typedef struct { uint32_t ExceptionCode; } WinShieldRec;
typedef struct { WinShieldRec *rec; void *ctx; } WinShieldPtrs;
static __attribute__((ms_abi)) long win_shield_handler(WinShieldPtrs *ep) {
  uint32_t c = ep->rec->ExceptionCode;
  if (c == 0x40010006u || c == 0x4001000Au || c == 0x406D1388u) return -1;   /* EXCEPTION_CONTINUE_EXECUTION: OutputDebugString A/W, SetThreadName */
  return 0;                                                                   /* EXCEPTION_CONTINUE_SEARCH */
}
static int win_shield_install(void) {
  if (!IsWindows()) return 0;
  void *k32 = cosmo_dlopen("kernel32.dll", RTLD_NOW);
  void *(__attribute__((ms_abi)) *add)(unsigned long, void *) = k32 ? cosmo_dlsym(k32, "AddVectoredExceptionHandler") : 0;
  return add && add(1, (void *)win_shield_handler) ? 1 : 0;
}
#endif
