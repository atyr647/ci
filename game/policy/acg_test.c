// Windows: arbitrary code guard (ProcessDynamicCodePolicy, "prohibit dynamic code"). Two modes:
//   acg_test probe                    : VirtualAlloc read+write, write a ret, VirtualProtect to execute; prints the result
//   acg_test run <exe> [args...]      : starts <exe> with the policy ON from its first instruction (PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY), waits, prints its output and exit code
//   acg_test probe-acg                : starts itself in `probe` mode under the policy
#include <stdio.h>
#include <string.h>
#include <windows.h>
#ifndef PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY
#define PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY 0x00020007
#endif
#define ACG_ALWAYS_ON (0x00000001ULL << 36)
static int probe(void) {
    unsigned char *p = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE); if (!p) { printf("probe: VirtualAlloc failed %lu\n", GetLastError()); return 1; }
    p[0] = 0xC3; DWORD old; BOOL ok = VirtualProtect(p, 4096, PAGE_EXECUTE_READ, &old);
    if (!ok) { printf("probe: write then VirtualProtect(execute): DENIED, error %lu (1655 = ERROR_DYNAMIC_CODE_BLOCKED)\n", GetLastError()); return 0; }
    ((void (*)(void))p)(); printf("probe: write then VirtualProtect(execute): allowed and ran\n");
    unsigned char *q = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE); printf("probe: VirtualAlloc(execute+write): %s\n", q ? "allowed" : "DENIED"); return 0;
}
static int launch(char *cmdline) {
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE}; HANDLE rd, wr; CreatePipe(&rd, &wr, &sa, 0); SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    SIZE_T sz = 0; InitializeProcThreadAttributeList(NULL, 1, 0, &sz); LPPROC_THREAD_ATTRIBUTE_LIST al = HeapAlloc(GetProcessHeap(), 0, sz); InitializeProcThreadAttributeList(al, 1, 0, &sz);
    DWORD64 pol = ACG_ALWAYS_ON; if (!UpdateProcThreadAttribute(al, 0, PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY, &pol, sizeof pol, NULL, NULL)) { printf("UpdateProcThreadAttribute failed %lu\n", GetLastError()); return 2; }
    STARTUPINFOEXA si; memset(&si, 0, sizeof si); si.StartupInfo.cb = sizeof si; si.StartupInfo.dwFlags = STARTF_USESTDHANDLES; si.StartupInfo.hStdOutput = wr; si.StartupInfo.hStdError = wr; si.StartupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE); si.lpAttributeList = al;
    PROCESS_INFORMATION pi; if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi)) { printf("CreateProcess failed %lu\n", GetLastError()); return 3; }
    CloseHandle(wr); char buf[4096]; DWORD n; while (ReadFile(rd, buf, sizeof buf - 1, &n, NULL) && n) { buf[n] = 0; fputs(buf, stdout); }
    WaitForSingleObject(pi.hProcess, 300000); DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code); printf("\n[exit code %lu]\n", code); return 0;
}
int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "probe")) return probe();
    if (argc >= 2 && !strcmp(argv[1], "probe-acg")) { char me[MAX_PATH], cmd[MAX_PATH + 16]; GetModuleFileNameA(NULL, me, sizeof me); snprintf(cmd, sizeof cmd, "\"%s\" probe", me); return launch(cmd); }
    if (argc >= 3 && !strcmp(argv[1], "run")) { char cmd[4096] = ""; for (int i = 2; i < argc; i++) { strcat(cmd, "\""); strcat(cmd, argv[i]); strcat(cmd, "\" "); } return launch(cmd); }
    puts("usage: acg_test probe | probe-acg | run <exe> [args]"); return 1;
}
