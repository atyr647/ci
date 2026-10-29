/* celori-launcher: ONE file (Cosmopolitan APE) that installs, updates and runs the native host + game. No browser involved.
 *   1. get a signed manifest (network, or embedded in this very file for offline use)
 *   2. verify the Ed25519 signature BEFORE trusting any field
 *   3. download only the files whose SHA-512 differs from what is installed (host for this OS/arch + game files), verify each, then swap them in
 *   4. exec the host with the game files
 * usage: launcher [--server URL] [--offline] [--dir DIR] [--update-only] [-- host-args...] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#ifdef __COSMOPOLITAN__
#include <sys/utsname.h>
#include <cosmo.h>
#else                                  /* plain native build (fallback when a single APE is not wanted): same logic, per-OS file */
#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#include <process.h>
#define mkdir(p, m) _mkdir(p)
#define chmod(p, m) 0
#define IsLinux() 0
#define IsWindows() 1
#define IsXnu() 0
struct utsname { char machine[32]; };
static int uname(struct utsname *u) { const char *a = getenv("PROCESSOR_ARCHITECTURE"); snprintf(u->machine, 32, "%s", a && !strcmp(a, "ARM64") ? "arm64" : "x86_64"); return 0; }
#else
#include <sys/utsname.h>
#ifdef __APPLE__
#define IsLinux() 0
#define IsXnu() 1
#else
#define IsLinux() 1
#define IsXnu() 0
#endif
#define IsWindows() 0
#endif
#endif
#include "monocypher.h"
#include "monocypher-ed25519.h"
#ifndef PUBKEY_HEX
#error "build with -DPUBKEY_HEX=\"<64 hex chars of the Ed25519 public key>\""
#endif
static int hexval(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
static int unhex(const char *h, unsigned char *out, int n) { for (int i = 0; i < n; i++) { int a = hexval(h[2 * i]), b = hexval(h[2 * i + 1]); if (a < 0 || b < 0) return -1; out[i] = a * 16 + b; } return 0; }
static void tohex(const unsigned char *b, int n, char *o) { for (int i = 0; i < n; i++) sprintf(o + 2 * i, "%02x", b[i]); o[2 * n] = 0; }
static int sha512_file(const char *p, char hex[129]) { FILE *f = fopen(p, "rb"); if (!f) return -1; crypto_sha512_ctx c; crypto_sha512_init(&c); static unsigned char b[1 << 16]; size_t n; while ((n = fread(b, 1, sizeof b, f)) > 0) crypto_sha512_update(&c, b, n); fclose(f); unsigned char h[64]; crypto_sha512_final(&c, h); tohex(h, 64, hex); return 0; }
static void mkdirs(const char *path) { char t[1024]; snprintf(t, sizeof t, "%s", path); for (char *p = t + 1; *p; p++) if (*p == '/' || *p == '\\') { char c = *p; *p = 0; mkdir(t, 0755); *p = c; } mkdir(t, 0755); }
static char *slurp(const char *p, long *len) { FILE *f = fopen(p, "rb"); if (!f) return 0; fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET); char *b = malloc(n + 1); if (fread(b, 1, n, f) != (size_t)n) { fclose(f); free(b); return 0; } b[n] = 0; fclose(f); if (len) *len = n; return b; }
static int copyfile(const char *src, const char *dst) { FILE *i = fopen(src, "rb"), *o = fopen(dst, "wb"); if (!i || !o) { if (i) fclose(i); if (o) fclose(o); return -1; } static char b[1 << 16]; size_t n; while ((n = fread(b, 1, sizeof b, i)) > 0) fwrite(b, 1, n, o); fclose(i); fclose(o); return 0; }
static char server[512], dir[900], fromdir[900]; static int offline;
static int fetch(const char *urlpath, const char *dst) {              /* network via curl (ships with Windows 10+, macOS and most Linux), or from inside this file */
  if (offline) { char s[1600]; if (fromdir[0]) snprintf(s, sizeof s, "%s%s", fromdir, urlpath); else snprintf(s, sizeof s, "/zip%s", urlpath); return copyfile(s, dst); }
  /* Windows: the Cosmopolitan runtime does not find "curl" on PATH (only curl.exe by absolute path), and hands us /C/... style paths */
  const char *curl = "curl"; char wdst[1024]; snprintf(wdst, sizeof wdst, "%s", dst);
  if (IsWindows()) { if (access("C:\\Windows\\System32\\curl.exe", 0) == 0) curl = "C:\\Windows\\System32\\curl.exe";
    if (dst[0] == '/' && dst[1] && dst[2] == '/') snprintf(wdst, sizeof wdst, "%c:%s", dst[1], dst + 2); }
  char cmd[2048]; snprintf(cmd, sizeof cmd, "\"%s\" -fsSL --retry 2 -o \"%s\" \"%s%s\"", curl, wdst, server, urlpath); return system(cmd); }
int main(int argc, char **argv) {
  const char *plat_os = IsLinux() ? "linux" : IsWindows() ? "windows" : IsXnu() ? "macos" : "other"; struct utsname u; uname(&u);
  const char *arch = (!strcmp(u.machine, "x86_64") || !strcmp(u.machine, "AMD64")) ? "x86_64" : (!strcmp(u.machine, "aarch64") || !strcmp(u.machine, "arm64")) ? "aarch64" : u.machine;
  char plat[64]; snprintf(plat, sizeof plat, "%s-%s", plat_os, arch);
  const char *env = getenv("CELORI_SERVER"); snprintf(server, sizeof server, "%s", env ? env : ""); dir[0] = 0; int update_only = 0, pass = argc;
  for (int i = 1; i < argc; i++) { if (!strcmp(argv[i], "--server") && i + 1 < argc) snprintf(server, sizeof server, "%s", argv[++i]); else if (!strcmp(argv[i], "--dir") && i + 1 < argc) snprintf(dir, sizeof dir, "%s", argv[++i]); else if (!strcmp(argv[i], "--offline")) offline = 1; else if (!strcmp(argv[i], "--from") && i + 1 < argc) { snprintf(fromdir, sizeof fromdir, "%s", argv[++i]); offline = 1; } else if (!strcmp(argv[i], "--update-only")) update_only = 1; else if (!strcmp(argv[i], "--")) { pass = i + 1; break; } else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; } }
  if (!dir[0]) { const char *h = getenv(IsWindows() ? "LOCALAPPDATA" : "HOME"); if (!h) h = "."; snprintf(dir, sizeof dir, IsWindows() ? "%s/Celori" : IsXnu() ? "%s/Library/Application Support/Celori" : "%s/.local/share/celori", h); }
  printf("celori-launcher: %s, install dir %s\n", plat, dir); mkdirs(dir);
  char mp[1000], sp[1000]; snprintf(mp, sizeof mp, "%s/manifest.txt", dir); snprintf(sp, sizeof sp, "%s/manifest.sig", dir);
  if (!offline && !server[0]) { fprintf(stderr, "no update server: pass --server URL, set CELORI_SERVER, or use --offline with an embedded manifest\n"); return 2; }
  if (fetch(offline ? "/manifest.txt" : "/manifest.txt", mp) || fetch("/manifest.sig", sp)) { fprintf(stderr, "could not get the manifest\n"); return 6; }
  long ml; char *man = slurp(mp, &ml), *sig = slurp(sp, 0); unsigned char pk[32], sg[64];
  if (!man || !sig || strlen(sig) < 128 || unhex(PUBKEY_HEX, pk, 32) || unhex(sig, sg, 64) || crypto_ed25519_check(sg, pk, (unsigned char *)man, ml)) { fprintf(stderr, "REFUSING: manifest signature is invalid. Nothing was installed or changed.\n"); return 3; }
  printf("manifest signature OK\n");
  char host[1000] = "", game[16][1000]; int ng = 0, changed = 0, found_host = 0, listed_any_plat = 0; char version[64] = "?";
  for (char *line = strtok(man, "\n"); line; line = strtok(0, "\n")) {
    char kind[16], p[64], name[128], hash[130], url[512]; long size;
    if (sscanf(line, "game %63s", version) == 1) continue;
    if (sscanf(line, "%15s %63s %127s %129s %ld %511s", kind, p, name, hash, &size, url) != 6 || strcmp(kind, "file")) continue;
    if (strcmp(p, "any") && strncmp(p, "linux", 5) && strncmp(p, "windows", 7) && strncmp(p, "macos", 5)) continue;
    if (strcmp(p, "any") && strcmp(p, plat)) { listed_any_plat = 1; continue; }
    if (strstr(name, "..") || strchr(name, '/') || strchr(name, '\\') || strlen(hash) != 128) { fprintf(stderr, "REFUSING: unsafe manifest entry\n"); return 3; }
    char dst[1000], have[129] = ""; snprintf(dst, sizeof dst, "%s/%s", dir, name);
    if (sha512_file(dst, have) == 0 && !strcmp(have, hash)) printf("  %-18s up to date\n", name);
    else { char part[1010]; snprintf(part, sizeof part, "%s.part", dst); printf("  %-18s downloading %ld bytes...\n", name, size);
      if (fetch(url, part)) { fprintf(stderr, "download failed for %s\n", name); remove(part); return 6; }
      char got[129]; if (sha512_file(part, got) || strcmp(got, hash)) { fprintf(stderr, "REFUSING: %s does not match its signed hash. Not installed.\n", name); remove(part); return 4; }
      remove(dst); if (rename(part, dst)) { fprintf(stderr, "could not install %s\n", name); return 6; } changed++; printf("  %-18s verified and installed\n", name); }
    if (!strcmp(p, plat)) { snprintf(host, sizeof host, "%s", dst); chmod(dst, 0755); found_host = 1; } else if (ng < 16) snprintf(game[ng++], 1000, "%s", dst);
  }
  if (!found_host) { fprintf(stderr, "no host for %s in this manifest%s\n", plat, listed_any_plat ? " (other platforms are listed)" : ""); return 5; }
  printf("game %s ready (%d file(s) changed)\n", version, changed); if (update_only) return 0;
  char *av[64]; int n = 0; av[n++] = host; for (int i = 0; i < ng && n < 40; i++) av[n++] = game[i]; for (int i = pass; i < argc && n < 62; i++) av[n++] = argv[i]; av[n] = 0;
  printf("starting host...\n"); fflush(stdout); execv(host, av); perror("exec host"); return 7; }
