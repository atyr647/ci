# CMake toolchain: single-arch (x86-64) Cosmopolitan compilers
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(COSMO $ENV{HOME}/cosmo/bin)
set(CMAKE_C_COMPILER   ${COSMO}/x86_64-unknown-cosmo-cc)
set(CMAKE_CXX_COMPILER ${COSMO}/x86_64-unknown-cosmo-c++)
set(CMAKE_AR           ${COSMO}/x86_64-linux-cosmo-ar)
set(CMAKE_RANLIB       ${COSMO}/x86_64-linux-cosmo-ranlib)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
