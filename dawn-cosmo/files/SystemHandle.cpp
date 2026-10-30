// Copyright 2026 The Dawn & Tint Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Replacement for src/dawn/common/SystemHandle.cpp in the Cosmopolitan build (derived from Dawn; changes: one implementation for a binary that runs on Windows
// AND on POSIX systems, choosing at run time; both spellings of the constructor and the full 64-bit value for Windows handles).
//
// Dawn's Windows-flavoured translation units (the D3D12 backend, compiled as if for Windows) and its POSIX-flavoured ones (everything else) live in the same
// binary and exchange SystemHandle objects (through SystemEventReceiver and friends). The header therefore gives the class one layout for both: 8 bytes, 8-aligned,
// a Windows HANDLE or a POSIX fd (sign-extended) in the low bits.
#include "src/dawn/common/SystemHandle.h"

#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <utility>

#include "src/utils/assert.h"
#include "src/utils/log.h"

extern "C" {
bool DawnCosmoIsWindows();  // VulkanFunctions.cpp
// Cosmopolitan's own Windows API bindings (System V calling convention on every host; they only work when running on Windows)
int CloseHandle(int64_t hObject);
int DuplicateHandle(int64_t hSourceProcess, int64_t hSource, int64_t hTargetProcess, int64_t* lpTarget, uint32_t access, int inherit, uint32_t options);
}

namespace dawn {

namespace {

inline bool OnWindows() {
    return DawnCosmoIsWindows();
}
inline int64_t Invalid() {
    return OnWindows() ? 0 : -1;
}
inline bool Valid(int64_t v) {
    return OnWindows() ? v != 0 : static_cast<int32_t>(v) >= 0;
}
inline int64_t Load(const SystemHandle* h) {
    int64_t v;
    std::memcpy(&v, static_cast<const void*>(h), sizeof v);
    return v;
}
inline void Store(SystemHandle* h, int64_t v) {
    std::memcpy(static_cast<void*>(h), &v, sizeof v);
}

}  // anonymous namespace

SystemHandle::SystemHandle() {
    Store(this, Invalid());
}
SystemHandle::SystemHandle(Handle handle) {
    Store(this, static_cast<int64_t>(handle));
}
SystemHandle::SystemHandle(void* windowsHandle) {
    Store(this, reinterpret_cast<int64_t>(windowsHandle));
}

SystemHandle::SystemHandle(ErrorTag tag) : SystemHandle() {
    dawn::ErrorLog() << "SystemHandle constructed from incorrect handle type.";
    DAWN_UNREACHABLE();
}

bool SystemHandle::IsValid() const {
    return Valid(Load(this));
}

SystemHandle::SystemHandle(SystemHandle&& rhs) {
    Store(this, Load(&rhs));
    Store(&rhs, Invalid());
}

SystemHandle& SystemHandle::operator=(SystemHandle&& rhs) {
    if (this != &rhs) {
        if (IsValid()) {
            Close();
        }
        Store(this, Load(&rhs));
        Store(&rhs, Invalid());
    }
    return *this;
}

SystemHandle::Handle SystemHandle::Get() const {
    return static_cast<Handle>(Load(this));
}

SystemHandle::Handle* SystemHandle::GetMut() {
    if (IsValid()) {
        Close();
    }
    return &mHandle;
}

SystemHandle::Handle SystemHandle::Detach() {
    Handle handle = static_cast<Handle>(Load(this));
    Store(this, Invalid());
    return handle;
}

SystemHandle SystemHandle::Duplicate() const {
    DAWN_CHECK(IsValid());
    const int64_t v = Load(this);
    SystemHandle out;
    if (OnWindows()) {
        int64_t dup = 0;
        const int64_t kCurrentProcess = -1;  // GetCurrentProcess()
        const uint32_t kDuplicateSameAccess = 2;
        DAWN_CHECK(DuplicateHandle(kCurrentProcess, v, kCurrentProcess, &dup, 0, 0, kDuplicateSameAccess) != 0);
        Store(&out, dup);
    } else {
        int fd = dup(static_cast<int>(v));
        DAWN_CHECK(fd >= 0);
        Store(&out, fd);
    }
    return out;
}

void SystemHandle::Close() {
    DAWN_ASSERT(IsValid());
    const int64_t v = Load(this);
    if (OnWindows()) {
        DAWN_CHECK(CloseHandle(v) != 0);
    } else {
        DAWN_CHECK(close(static_cast<int>(v)) >= 0);
    }
    Store(this, Invalid());
}

SystemHandle::~SystemHandle() {
    if (IsValid()) {
        Close();
    }
}

int64_t SystemHandle::GetRawCosmo() const {
    return Load(this);
}

SystemHandle SystemHandle::AcquireRawCosmo(int64_t raw) {
    SystemHandle h;
    Store(&h, raw);
    return h;
}

}  // namespace dawn
