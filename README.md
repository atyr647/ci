# ci
Throwaway runners for Sample experiments: real Windows / macOS / Linux / arm64 test machines.
- `ci-launcher-test/` single-file Cosmopolitan launcher (install, verify, update, exec host)
- `ci-webgpu-test/` one `webgpu.h` C source vs Dawn, wgpu-native, and a Cosmopolitan APE that dlopens the native lib
