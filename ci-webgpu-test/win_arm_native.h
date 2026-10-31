// Windows on ARM: the x86-64 half of a Cosmopolitan file runs under Windows' x86-64 emulation. If the file carries a native arm64 build of the same program
// (zip entry winarm/<name>.exe, built by a windows-11-arm job against native Dawn/D3D12), it is unpacked once into %TEMP%/celori-native-<key>/ and run instead,
// with the same arguments, environment, output and exit status. WN_NO_NATIVE=1 keeps the emulated path (for comparisons). Same mechanism as wasmtime-nostd/host/host.c.
#pragma once
#include <cosmo.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern char **environ;

static bool WinArmUnderEmulation() {
    if (!IsWindows()) return false;
    void *k = cosmo_dlopen("kernel32.dll", RTLD_NOW); if (!k) return false;
    typedef int (__attribute__((ms_abi)) *w2_t)(void *, unsigned short *, unsigned short *);
    w2_t f = (w2_t)cosmo_dlsym(k, "IsWow64Process2"); if (!f) return false;
    unsigned short proc = 0, native = 0; if (!f((void *)(intptr_t)-1, &proc, &native)) return false;
    return native == 0xAA64;   // the machine is ARM64; this process is the emulated x86-64 half
}

static bool WinArmReadAll(const char *path, std::vector<unsigned char> &out) {
    FILE *f = fopen(path, "rb"); if (!f) return false;
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET); if (len < 0) { fclose(f); return false; }
    out.resize((size_t)len); bool ok = fread(out.data(), 1, out.size(), f) == out.size(); fclose(f); return ok;
}

static bool WinArmPut(const char *path, const std::vector<unsigned char> &d) {   // write unless a file of the same size is already there; temp file + rename so a concurrent start never sees a half file
    struct stat st; if (stat(path, &st) == 0 && (size_t)st.st_size == d.size()) return true;
    char t[900]; snprintf(t, sizeof t, "%s.%d", path, (int)getpid()); FILE *o = fopen(t, "wb");
    if (!o || fwrite(d.data(), 1, d.size(), o) != d.size() || fclose(o) != 0 || rename(t, path) != 0) { remove(t); return false; }
    return true;
}

// Returns the exit status of the native program, or -1 if there is nothing native to run (not on ARM64, not packed, WN_NO_NATIVE set, or it could not be unpacked).
static int WinArmRunNative(const char *name, char **argv) {
    if (!IsWindows() || getenv("WN_NO_NATIVE") || !WinArmUnderEmulation()) return -1;
    char zp[200]; snprintf(zp, sizeof zp, "/zip/winarm/%s.exe", name);
    std::vector<unsigned char> exe; if (!WinArmReadAll(zp, exe)) return -1;
    const char *tmp = getenv("TEMP"); if (!tmp || !*tmp) tmp = getenv("TMP"); if (!tmp || !*tmp) tmp = ".";
    unsigned long long key = 1469598103934665603ull; for (size_t i = 0; i < exe.size(); i += 997) key = (key ^ exe[i]) * 1099511628211ull;
    char dir[700], path[800], dst[800]; snprintf(dir, sizeof dir, "%s/celori-native-%llx", tmp, key); mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/%s.exe", dir, name);
    if (!WinArmPut(path, exe)) { fprintf(stderr, "%s: cannot unpack the native build to %s\n", name, dir); return -1; }
    // native Dawn on Windows loads the FXC shader compiler only from the executable's own directory; the system copy is the arm64 one on an ARM64 machine
    const char *root = getenv("SystemRoot"); if (!root || !*root) root = getenv("WINDIR"); if (!root || !*root) root = "C:/Windows";
    char src[800]; snprintf(src, sizeof src, "%s/System32/d3dcompiler_47.dll", root); snprintf(dst, sizeof dst, "%s/d3dcompiler_47.dll", dir);
    std::vector<unsigned char> dll; if (WinArmReadAll(src, dll)) WinArmPut(dst, dll);
    printf("%s: Windows on ARM: starting the native arm64 build (%s)\n", name, dir); fflush(stdout);
    std::vector<char *> args; args.push_back(path); for (char **a = argv + 1; *a; a++) args.push_back(*a); args.push_back(nullptr);
    pid_t pid; int ws = 0;
    if (posix_spawn(&pid, path, nullptr, nullptr, args.data(), environ)) { fprintf(stderr, "%s: cannot start the native build\n", name); return -1; }
    if (waitpid(pid, &ws, 0) < 0) return -1;
    return WIFEXITED(ws) ? WEXITSTATUS(ws) : 1;
}
