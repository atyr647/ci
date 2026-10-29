/* Windows: which DLLs can this process load, and with which error? (Dawn reported Windows error 87 for all of them) */
#include <windows.h>
#include <stdio.h>
static void t(const char *n, DWORD fl) {
  HMODULE h = LoadLibraryExA(n, NULL, fl);
  printf("  %-22s flags=0x%04lx -> %s (err %lu)\n", n, fl, h ? "OK" : "FAIL", h ? 0 : GetLastError());
  if (h) FreeLibrary(h);
}
int main(void) {
  const char *libs[] = {"d3dcompiler_47.dll", "dxcompiler.dll", "dxil.dll", "vulkan-1.dll", "d3d12.dll", "dxgi.dll"};
  DWORD flags[] = {0, 0x800 /*SEARCH_SYSTEM32*/, 0x1000 /*SEARCH_DEFAULT_DIRS*/};
  for (int i = 0; i < 6; i++) for (int j = 0; j < 3; j++) t(libs[i], flags[j]);
  return 0;
}
