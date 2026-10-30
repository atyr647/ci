/* A small Cosmopolitan program that reads a file out of its own embedded zip (/zip/asset.txt) and prints which OS/architecture slice is running.
 * Used to prove that, after code signing, the embedded zip still resolves and the file still runs. */
#define _COSMO_SOURCE 1
#include <stdio.h>
#include <cosmo.h>
int main(void) {
    printf("app: %s %s\n", IsWindows() ? "Windows" : IsXnu() ? "macOS" : IsLinux() ? "Linux" : "other", IsAarch64() ? "arm64" : "x86-64");
    FILE *f = fopen("/zip/asset.txt", "r");
    if (!f) { puts("zip asset: MISSING"); return 3; }
    char b[256]; size_t n = fread(b, 1, sizeof b - 1, f); b[n] = 0; fclose(f);
    printf("zip asset: %s", b);
    return 0;
}
