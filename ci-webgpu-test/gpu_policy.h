/* Which GPU should the game use? One pure function, so it can be unit-tested against laptops we do not have.
 * Rules, in order: (1) real GPUs before CPU/software adapters (a software adapter is chosen only when nothing else exists);
 * (2) discrete before integrated; (3) among equals, more device-local memory; (4) Metal/D3D12 before Vulkan on the same GPU;
 * (5) otherwise keep the order the OS gave us. An explicit user choice (index) always wins. */
#ifndef GPU_POLICY_H
#define GPU_POLICY_H
#include <stdint.h>
enum { GPU_TYPE_DISCRETE = 0, GPU_TYPE_INTEGRATED = 1, GPU_TYPE_CPU = 2, GPU_TYPE_UNKNOWN = 3 };
enum { GPU_BACKEND_METAL = 0, GPU_BACKEND_D3D12 = 0, GPU_BACKEND_VULKAN = 1, GPU_BACKEND_OTHER = 2 };   /* lower = preferred */
typedef struct { int type; int backend; uint64_t device_local_bytes; const char *name; } gpu_candidate;

static int gpu_type_rank(int t) { return t == GPU_TYPE_DISCRETE ? 0 : t == GPU_TYPE_INTEGRATED ? 1 : t == GPU_TYPE_UNKNOWN ? 3 : 2; }

/* returns the index of the best candidate, or -1 when the list is empty. user_index >= 0 forces that entry. */
static int gpu_pick(const gpu_candidate *c, int n, int user_index) {
  if (n <= 0) return -1;
  if (user_index >= 0 && user_index < n) return user_index;
  int best = 0;
  for (int i = 1; i < n; i++) {
    int ra = gpu_type_rank(c[i].type), rb = gpu_type_rank(c[best].type);
    int better = 0;
    if (ra != rb) better = ra < rb;
    else if (c[i].device_local_bytes != c[best].device_local_bytes) better = c[i].device_local_bytes > c[best].device_local_bytes;
    else if (c[i].backend != c[best].backend) better = c[i].backend < c[best].backend;
    if (better) best = i;
  }
  return best;
}
#endif
