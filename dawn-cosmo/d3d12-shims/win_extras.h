#pragma once
/* Declarations the Windows SDK has and Wine's headers (or DirectX-Headers) lack. Names and values are Microsoft's. */
#include <windows.h>
extern "C" BOOL WINAPI CompareObjectHandles(HANDLE hFirstObjectHandle, HANDLE hSecondObjectHandle);
#ifndef D3D12_ERROR_ADAPTER_NOT_FOUND
#define D3D12_ERROR_ADAPTER_NOT_FOUND _HRESULT_TYPEDEF_(0x887E0001L)
#define D3D12_ERROR_DRIVER_VERSION_MISMATCH _HRESULT_TYPEDEF_(0x887E0002L)
#endif
