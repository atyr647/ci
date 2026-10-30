#pragma once
/* Same approach as the SDK header: ask VerifyVersionInfoW whether the running Windows is at least major.minor.sp (also what the real implementation of this shim must do). */
#include <windows.h>
#ifndef _WIN32_WINNT_WIN10
#define _WIN32_WINNT_WIN10 0x0A00
#endif
static inline BOOL IsWindowsVersionOrGreater(WORD major, WORD minor, WORD sp) {
  OSVERSIONINFOEXW vi = {sizeof(vi), major, minor, 0, 0, {0}, sp, 0, 0, 0, 0};
  DWORDLONG mask = 0;
  mask = VerSetConditionMask(mask, VER_MAJORVERSION, VER_GREATER_EQUAL);
  mask = VerSetConditionMask(mask, VER_MINORVERSION, VER_GREATER_EQUAL);
  mask = VerSetConditionMask(mask, VER_SERVICEPACKMAJOR, VER_GREATER_EQUAL);
  return VerifyVersionInfoW(&vi, VER_MAJORVERSION | VER_MINORVERSION | VER_SERVICEPACKMAJOR, mask) != FALSE;
}
static inline BOOL IsWindows10OrGreater(void) { return IsWindowsVersionOrGreater(10, 0, 0); }
static inline BOOL IsWindows8OrGreater(void) { return IsWindowsVersionOrGreater(6, 2, 0); }
static inline BOOL IsWindows7OrGreater(void) { return IsWindowsVersionOrGreater(6, 1, 0); }
