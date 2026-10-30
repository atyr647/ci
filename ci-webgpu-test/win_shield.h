/* Windows only, Cosmopolitan. Two problems with how the runtime treats Windows exceptions, both fatal for code that calls into ordinary Windows DLLs:
 *  1. every SEH exception it does not know becomes a SIGSEGV that kills the process - including the harmless DBG_PRINTEXCEPTION_C (0x40010006) that OutputDebugString
 *     raises (Dawn, the Vulkan loader, D3D12's debug layer and many other DLLs do that), and the thread-name exception 0x406D1388;
 *  2. its crash handler is a first-in-line vectored exception handler that redirects the faulting thread, so the C++ exceptions (0xE06D7363) that Microsoft's own
 *     DLLs throw and catch internally (DXGI/D3D12 do this while enumerating adapters) never reach those DLLs' catch blocks: the process dies at the throw.
 * win_shield_install() puts a wrapper in front: it ignores the debugger-message exceptions, lets C++/CLR exceptions go on to the frame-based handlers
 * (EXCEPTION_CONTINUE_SEARCH, so the DLL's own try/catch runs) and forwards everything else to the runtime's handler. The runtime's handler is taken out of the
 * vectored-handler list (found by looking for the entries whose code lies inside this executable) and called from the wrapper. Include after <cosmo.h>; call once. */
#ifndef WIN_SHIELD_H
#define WIN_SHIELD_H
#include <stdint.h>
#include <stdio.h>
#include <dlfcn.h>
typedef struct { uint32_t ExceptionCode; } WinShieldRec;
typedef struct { WinShieldRec *rec; void *ctx; } WinShieldPtrs;
typedef long (__attribute__((ms_abi)) *win_shield_veh_t)(WinShieldPtrs *);
typedef void *(__attribute__((ms_abi)) *win_shield_add_t)(unsigned long, void *);
typedef unsigned long (__attribute__((ms_abi)) *win_shield_remove_t)(void *);
typedef void *(__attribute__((ms_abi)) *win_shield_ptr_t)(void *);
static win_shield_veh_t win_shield_runtime_veh;   /* the Cosmopolitan crash handler, once extracted */
static __attribute__((ms_abi)) long win_shield_dummy(WinShieldPtrs *ep) { (void)ep; return 0; }
static __attribute__((ms_abi)) long win_shield_handler(WinShieldPtrs *ep) {
  uint32_t c = ep->rec->ExceptionCode;
  if (c == 0x40010006u || c == 0x4001000Au || c == 0x406D1388u) return -1;       /* EXCEPTION_CONTINUE_EXECUTION: OutputDebugString A/W, SetThreadName */
  if (c == 0xE06D7363u || c == 0xE0434352u || c == 0xE0434F4Du) return 0;        /* MSVC C++ / CLR exception: EXCEPTION_CONTINUE_SEARCH so the DLL's own catch handles it */
  return win_shield_runtime_veh ? win_shield_runtime_veh(ep) : 0;
}
static int win_shield_install(void) {
  if (!IsWindows()) return 0;
  void *k32 = cosmo_dlopen("kernel32.dll", RTLD_NOW);
  if (!k32) return 0;
  win_shield_add_t add = (win_shield_add_t)cosmo_dlsym(k32, "AddVectoredExceptionHandler");
  win_shield_remove_t rem = (win_shield_remove_t)cosmo_dlsym(k32, "RemoveVectoredExceptionHandler");
  win_shield_ptr_t decode = (win_shield_ptr_t)cosmo_dlsym(k32, "DecodePointer");
  typedef void *(__attribute__((ms_abi)) *getmod_t)(const char *);
  getmod_t getmod = (getmod_t)cosmo_dlsym(k32, "GetModuleHandleA");
  if (!add || !rem || !decode || !getmod) return 0;
  /* the image of this executable: base + SizeOfImage from the PE header */
  uintptr_t base = (uintptr_t)getmod(0), lo = base, hi = base;
  if (base) { uint32_t pe = *(uint32_t *)(base + 0x3c); hi = base + *(uint32_t *)(base + pe + 24 + 56); }
  /* a throw-away handler at the head of the list shows where the list continues: its first word is the link to the next entry */
  void *probe = add(1, (void *)win_shield_dummy);
  if (probe && hi > lo) {
    uintptr_t *d = (uintptr_t *)probe;
    uintptr_t *e = (uintptr_t *)d[0];
    uintptr_t *found[8]; int nfound = 0;
    for (int hops = 0; hops < 6 && e && e != d && nfound < 8; hops++) {
      uintptr_t *next = (uintptr_t *)e[0];
      for (int k = 2; k < 8; k++) {
        uintptr_t dec = (uintptr_t)decode((void *)e[k]);
        if (dec >= lo && dec < hi) { if (!win_shield_runtime_veh) win_shield_runtime_veh = (win_shield_veh_t)dec; found[nfound++] = e; break; }
      }
      e = next;
    }
    for (int i = 0; i < nfound; i++) rem(found[i]);   /* ours replaces all of the runtime's handlers (it forwards to the first of them) */
    rem(probe);
  } else if (probe) rem(probe);
  return add(1, (void *)win_shield_handler) ? 1 : 0;
}
#endif
