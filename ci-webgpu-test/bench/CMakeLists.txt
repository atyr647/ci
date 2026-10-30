cmake_minimum_required(VERSION 3.20)
project(dawn_bench CXX)
find_package(Threads REQUIRED)
find_package(Dawn REQUIRED)
add_executable(dawn-bench ../dawn_bench.cpp)
target_compile_features(dawn-bench PRIVATE cxx_std_17)
target_link_libraries(dawn-bench PRIVATE dawn::webgpu_dawn)
# the same program with the per-thread small-block cache of the Cosmopolitan build (alloc-probe/tcache_new.cpp) in front of the platform allocator:
# tells how much of a difference between the two builds is the allocator and nothing else
add_executable(dawn-bench-tcache ../dawn_bench.cpp ../../alloc-probe/tcache_new.cpp)
target_compile_features(dawn-bench-tcache PRIVATE cxx_std_17)
target_link_libraries(dawn-bench-tcache PRIVATE dawn::webgpu_dawn)
