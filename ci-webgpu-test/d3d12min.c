/* Smallest possible test of "can a Cosmopolitan program create a D3D12 device": no Dawn, no headers from Windows, COM calls through the vtables by hand.
 * Steps are printed (and flushed) before they run, so the last line tells where a silent death happened. NO_SHIELD=1 skips the exception-handler wrapper. */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <cosmo.h>
#include <dlfcn.h>
#include <pthread.h>
#include "win_shield.h"
#define MS __attribute__((ms_abi))
#define STEP(...) do { fprintf(stderr, "step: " __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } while (0)
typedef struct { uint32_t a; uint16_t b, c; uint8_t d[8]; } GUID_;
static const GUID_ IID_IDXGIFactory1 = {0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
static const GUID_ IID_ID3D12Device = {0x189819f1, 0x1db6, 0x4b57, {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7}};
typedef long (MS *create_factory_t)(const GUID_ *, void **);
typedef long (MS *create_factory2_t)(unsigned, const GUID_ *, void **);
typedef long (MS *create_device_t)(void *, int, const GUID_ *, void **);
typedef long (MS *enum_adapters1_t)(void *self, unsigned i, void **adapter);
typedef unsigned long (MS *release_t)(void *);
static void **vt(void *o) { return *(void ***)o; }
int main(int argc, char **argv) {
  ShowCrashReports();
  if (!getenv("NO_SHIELD")) { STEP("installing the exception wrapper: %d", win_shield_install()); }
#if defined(__x86_64__)
  {   /* Windows validates the stack pointer against the thread block (TEB) whenever it dispatches an exception: outside StackLimit..StackBase it gives up */
    uintptr_t base, limit, dealloc, rsp; __asm__ volatile("mov %%gs:8, %0" : "=r"(base)); __asm__ volatile("mov %%gs:16, %0" : "=r"(limit)); __asm__ volatile("mov %%gs:0x1478, %0" : "=r"(dealloc)); __asm__ volatile("mov %%rsp, %0" : "=r"(rsp));
    void *saddr = 0; size_t ssize = 0; pthread_attr_t at; if (!pthread_getattr_np(pthread_self(), &at)) { pthread_attr_getstack(&at, &saddr, &ssize); }
    STEP("rsp=%#lx  TEB StackBase=%#lx StackLimit=%#lx DeallocationStack=%#lx  cosmo stack=%p+%#zx  rsp inside TEB range: %s", (unsigned long)rsp, (unsigned long)base, (unsigned long)limit, (unsigned long)dealloc, saddr, ssize, (rsp >= limit && rsp < base) ? "yes" : "NO");
    if (getenv("FIX_TEB_AGAIN") && saddr) {
      uintptr_t lo = (uintptr_t)saddr, hi = lo + ssize;
      __asm__ volatile("mov %0, %%gs:8" :: "r"(hi)); __asm__ volatile("mov %0, %%gs:16" :: "r"(lo)); __asm__ volatile("mov %0, %%gs:0x1478" :: "r"(lo));
      STEP("TEB stack fields set to %#lx..%#lx", (unsigned long)lo, (unsigned long)hi);
    }
  }
#endif
  void *dxgi = cosmo_dlopen("dxgi.dll", RTLD_NOW), *d3d12 = cosmo_dlopen("d3d12.dll", RTLD_NOW);
  STEP("dxgi=%p d3d12=%p", dxgi, d3d12); if (!dxgi || !d3d12) return 2;
  create_factory_t cf = (create_factory_t)cosmo_dlsym(dxgi, "CreateDXGIFactory1");
  create_device_t cd = (create_device_t)cosmo_dlsym(d3d12, "D3D12CreateDevice");
  void *factory = 0; STEP("CreateDXGIFactory1"); long hr = cf(&IID_IDXGIFactory1, &factory); STEP("-> 0x%08lx factory=%p", hr, factory); if (hr || !factory) return 3;
  int nad = 0; void *adapters[8] = {0};
  for (unsigned i = 0; i < 8; i++) { void *a = 0; STEP("EnumAdapters1(%u)", i); hr = ((enum_adapters1_t)vt(factory)[12])(factory, i, &a); STEP("-> 0x%08lx adapter=%p", hr, a); if (hr || !a) break; adapters[nad++] = a; }
  STEP("%d adapter(s)", nad);
  for (int i = 0; i < nad; i++) {
    void *dev = 0; STEP("D3D12CreateDevice(adapter %d, feature level 11_0)", i);
    hr = cd(adapters[i], 0xb000, &IID_ID3D12Device, &dev); STEP("-> 0x%08lx device=%p", hr, dev);
    if (dev) ((release_t)vt(dev)[2])(dev);
  }
  STEP("D3D12CreateDevice(NULL adapter = default)"); void *dev = 0; hr = cd(0, 0xb000, &IID_ID3D12Device, &dev); STEP("-> 0x%08lx device=%p", hr, dev);
  puts("RESULT PASS"); return 0;
}
