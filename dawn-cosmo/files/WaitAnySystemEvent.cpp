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

#include "src/dawn/native/WaitAnySystemEvent.h"

#include <sys/poll.h>
#include <unistd.h>

extern "C" {
bool DawnCosmoIsWindows();  // VulkanFunctions.cpp
// Cosmopolitan's own Windows API bindings (System V calling convention on every host; they only work when running on Windows)
uint32_t WaitForMultipleObjects(uint32_t nCount, const int64_t* lpHandles, int bWaitAll, uint32_t dwMilliseconds);
}

#include "absl/container/inlined_vector.h"
#include "src/dawn/common/Enumerator.h"
#include "src/utils/log.h"

// [COSMO-PATCH] Derived from Dawn: Windows (WaitForMultipleObjects) or POSIX (poll), chosen when the program runs.
namespace dawn::native {

bool WaitAnySystemEvent(Span<std::pair<const SystemEventReceiver&, bool*>> events,
                        Nanoseconds timeout) {
    if (events.empty()) {
        return false;
    }
    if (DawnCosmoIsWindows()) {
        constexpr uint32_t kInfinite = 0xFFFFFFFFu, kWaitTimeout = 258, kMaximumWaitObjects = 64;
        absl::InlinedVector<int64_t, 4 /* avoid heap allocation for small waits */> handles;
        handles.reserve(events.size());
        for (const auto& [systemEvent, _] : events) {
            handles.push_back(systemEvent.mPrimitive.GetRawCosmo());
        }
        DAWN_ASSERT(handles.size() <= kMaximumWaitObjects);
        uint32_t status = WaitForMultipleObjects(uint32_t(handles.size()), handles.data(),
                                                 /*bWaitAll=*/0, ToMillisecondsGeneric<uint32_t, kInfinite>(timeout));
        if (status == kWaitTimeout) {
            return false;
        }
        DAWN_CHECK(status < events.size());  // WAIT_OBJECT_0 == 0
        const size_t completedIndex = checked_cast<size_t>(sign_cast(status));

        *events[completedIndex].second = true;
        return true;
    }
    absl::InlinedVector<pollfd, 4 /* avoid heap allocation for small waits */> pollfds;
    pollfds.reserve(events.size());
    for (auto [systemEvent, _] : events) {
        pollfds.push_back(pollfd{static_cast<int>(systemEvent.mPrimitive.Get()), static_cast<short>(POLLIN), 0});
    }
    int status = 0;
    bool retry = false;
    do {
        retry = false;
        status =
            poll(pollfds.data(), checked_cast<nfds_t>(pollfds.size()), ToMilliseconds(timeout));
        if (status < 0) {
            int lErrno = errno;
            if (EAGAIN == lErrno || EINTR == lErrno) {
                retry = true;
            } else {
                dawn::ErrorLog() << "poll errno=" << lErrno;
            }
        }
    } while (retry);

    DAWN_CHECK(status >= 0);
    if (status == 0) {
        return false;
    }

    for (auto [i, event] : Enumerate(events)) {
        int revents = pollfds[i].revents;
        const int kAllowedEvents = POLLIN | POLLHUP;  // Cosmopolitan resolves POLLIN at run time
        DAWN_CHECK((revents & kAllowedEvents) == revents);

        bool ready = (pollfds[i].revents & POLLIN) != 0;
        *event.second = ready;
    }

    return true;
}

}  // namespace dawn::native
