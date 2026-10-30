// Added to Dawn's Metal backend for the Cosmopolitan build.
//
// Dawn asks Metal to call back into Dawn (command buffer "scheduled" and "completed" handlers). Metal runs those blocks on its own threads, which have none of
// Cosmopolitan's per-thread state (on arm64 the runtime keeps it in register x28, which Apple's code uses freely), so Dawn's C++ code (mutexes, allocation, errno)
// must not run there. Instead of registering handlers, each committed command buffer is handed to a thread created by Cosmopolitan, which waits for the buffer
// with waitUntilScheduled / waitUntilCompleted and then runs the very same handler bodies.
#import <Metal/Metal.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>

namespace {

struct Job {
    id<MTLCommandBuffer> commandBuffer;
    std::function<void(id<MTLCommandBuffer>)> scheduled;
    std::function<void(id<MTLCommandBuffer>)> completed;
};

std::mutex gMutex;
std::condition_variable gWake;
std::deque<Job> gJobs;
bool gWorkerStarted = false;

void Worker() {
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(gMutex);
            gWake.wait(lock, [] { return !gJobs.empty(); });
            job = std::move(gJobs.front());
            gJobs.pop_front();
        }
        @autoreleasepool {
            [job.commandBuffer waitUntilScheduled];
            job.scheduled(job.commandBuffer);
            [job.commandBuffer waitUntilCompleted];
            job.completed(job.commandBuffer);
        }
        [job.commandBuffer release];
    }
}

}  // namespace

// Called right after [commandBuffer commit].
void DawnCosmoMetalWatch(id<MTLCommandBuffer> commandBuffer,
                         std::function<void(id<MTLCommandBuffer>)> scheduled,
                         std::function<void(id<MTLCommandBuffer>)> completed) {
    [commandBuffer retain];
    std::lock_guard<std::mutex> lock(gMutex);
    gJobs.push_back(Job{commandBuffer, std::move(scheduled), std::move(completed)});
    if (!gWorkerStarted) {
        gWorkerStarted = true;
        std::thread(Worker).detach();
    }
    gWake.notify_one();
}
