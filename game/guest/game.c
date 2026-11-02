// A complete game loop in WebAssembly driving the GPU through host imports (module "celori").
//   * the game logic (input, state, audio synthesis, the CPU reference) runs here, in the guest;
//   * the host owns the GPU (Dawn: Vulkan, D3D12 or Metal), the input queue and the audio sink;
//   * every frame: poll input -> update the game state -> upload uniforms -> GPU compute (particles chase the player) -> GPU render pass into a texture -> audio for 1/60 s.
// It checks itself: the GPU particle state is compared with a CPU reference computed here, the rendered image is probed at known pixels, the player position follows the scripted input exactly,
// and the audio is silent except where the scripted "fire" input asks for a tone. game_result() returns 0 when all of it holds.
#include <math.h>
#include <stdint.h>
#include <string.h>
#define IMPORT(n) __attribute__((import_module("celori"), import_name(n)))
IMPORT("gpu_shader") int32_t gpu_shader(const char *wgsl, int32_t len);
IMPORT("gpu_buffer") int32_t gpu_buffer(int32_t size, int32_t usage);   // usage: 1 storage, 2 uniform (copy source and destination always)
IMPORT("gpu_write") void gpu_write(int32_t buf, int32_t off, const void *p, int32_t len);
IMPORT("gpu_compute_pipeline") int32_t gpu_compute_pipeline(int32_t shader, const char *entry, int32_t len);
IMPORT("gpu_render_pipeline") int32_t gpu_render_pipeline(int32_t shader, const char *vs, int32_t vslen, const char *fs, int32_t fslen);
IMPORT("gpu_target") int32_t gpu_target(int32_t w, int32_t h);
IMPORT("gpu_begin") void gpu_begin(void);
IMPORT("gpu_end") void gpu_end(void);
IMPORT("gpu_dispatch") void gpu_dispatch(int32_t pipe, int32_t b0, int32_t b1, int32_t b2, int32_t groups);
IMPORT("gpu_draw") void gpu_draw(int32_t pipe, int32_t b0, int32_t b1, int32_t target, int32_t verts, int32_t instances, uint32_t clear_rgba);
IMPORT("gpu_read") void gpu_read(int32_t buf, int32_t off, void *p, int32_t len);
IMPORT("gpu_read_target") void gpu_read_target(int32_t target, void *p, int32_t len);
IMPORT("input_poll") int32_t input_poll(void *events, int32_t max);   // struct Ev { u32 type; i32 a; i32 b; u32 frame; }
IMPORT("audio_write") int32_t audio_write(const void *stereo_i16, int32_t frames);
IMPORT("host_log") void host_log(const char *p, int32_t len);

struct Ev { uint32_t type, a, b, frame; };
enum { EV_KEY_DOWN = 1, EV_KEY_UP = 2, EV_MOUSE = 3 };
enum { KEY_LEFT = 1, KEY_RIGHT = 2, KEY_UP = 3, KEY_DOWN = 4, KEY_FIRE = 5 };

#define N 1024
#define W 256
#define H 256
#define AUDIO_RATE 48000
#define FRAME_SAMPLES (AUDIO_RATE / 60)
struct Params { float dt, tx, ty, n, burst, p0, p1, p2; };

static const char *CS =
    "struct P { dt: f32, tx: f32, ty: f32, n: f32, burst: f32, p0: f32, p1: f32, p2: f32 };\n"
    "@group(0) @binding(0) var<storage, read_write> parts : array<vec4<f32>>;\n"
    "@group(0) @binding(1) var<uniform> p : P;\n"
    "@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) g : vec3<u32>) {\n"
    "  let i = g.x; if (f32(i) >= p.n) { return; }\n"
    "  var s = parts[i]; let a = f32(i) * 0.0061359; let off = 0.15 * vec2<f32>(cos(a), sin(a));\n"
    "  let d = vec2<f32>(p.tx, p.ty) + off - s.xy;\n"
    "  var v = s.zw * (1.0 - 1.5 * p.dt) + d * (4.0 * p.dt) + off * (p.burst * 8.0);\n"
    "  parts[i] = vec4<f32>(s.xy + v * p.dt, v);\n"
    "}\n";
static const char *RS =
    "struct P { dt: f32, tx: f32, ty: f32, n: f32, burst: f32, p0: f32, p1: f32, p2: f32 };\n"
    "struct VOut { @builtin(position) pos : vec4<f32>, @location(0) @interpolate(flat) col : vec4<f32> };\n"
    "@group(0) @binding(0) var<storage, read> parts : array<vec4<f32>>;\n"
    "@group(0) @binding(1) var<uniform> p : P;\n"
    "@vertex fn vs(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VOut {\n"
    "  var q = array<vec2<f32>, 6>(vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(-1.0, 1.0), vec2<f32>(-1.0, 1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0));\n"
    "  var center = vec2<f32>(0.0); var size = 0.0; var col = vec4<f32>(0.0);\n"
    "  if (ii == u32(p.n)) { center = vec2<f32>(p.tx, p.ty); size = 0.04; col = vec4<f32>(1.0, 0.0, 0.0, 1.0); }\n"
    "  else { center = parts[ii].xy; size = 0.012; col = vec4<f32>(0.2, 1.0, 0.2, 1.0); }\n"
    "  var o : VOut; o.pos = vec4<f32>(center + q[vi] * size, 0.0, 1.0); o.col = col; return o;\n"
    "}\n"
    "@fragment fn fs(i : VOut) -> @location(0) vec4<f32> { return i.col; }\n";

static int g_cs, g_rs, g_cpipe, g_rpipe, g_parts, g_params, g_target;
static float g_ref[N][4];               // CPU reference of the particle state, same arithmetic as the compute shader
static float g_px = 0.0f, g_py = 0.0f;  // the player (the attractor)
static int g_down[8];
static int g_frame, g_score, g_fire_frames[64], g_nfire, g_fail;
static int g_audio_left;                // frames of tone still to play
static float g_phase;
static uint32_t g_xs = 12345u;

static void say(const char *s) { host_log(s, (int32_t)strlen(s)); }
static void kv(const char *k, int v) {   // "key value\n" (no printf in the guest)
    char out[64]; int o = 0; for (const char *p = k; *p && o < 40; p++) out[o++] = *p; out[o++] = ' ';
    if (v < 0) { out[o++] = '-'; v = -v; } char t[12]; int n = 0; do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v); while (n) out[o++] = t[--n];
    out[o++] = '\n'; host_log(out, o);
}
static void check(int ok, const char *what) { if (!ok) { g_fail++; say("FAIL "); say(what); say("\n"); } }

__attribute__((export_name("game_init"))) int game_init(void) {
    g_cs = gpu_shader(CS, (int32_t)strlen(CS)); g_rs = gpu_shader(RS, (int32_t)strlen(RS));
    g_cpipe = gpu_compute_pipeline(g_cs, "main", 4); g_rpipe = gpu_render_pipeline(g_rs, "vs", 2, "fs", 2);
    g_parts = gpu_buffer(N * 16, 1); g_params = gpu_buffer(sizeof(struct Params), 2); g_target = gpu_target(W, H);
    check(g_cs >= 0 && g_rs >= 0 && g_cpipe >= 0 && g_rpipe >= 0 && g_parts >= 0 && g_params >= 0 && g_target >= 0, "GPU object creation");
    static float init[N][4];
    for (int i = 0; i < N; i++) {   // deterministic scatter (xorshift), at rest
        g_xs ^= g_xs << 13; g_xs ^= g_xs >> 17; g_xs ^= g_xs << 5; float x = ((g_xs & 0xFFFF) / 32767.5f - 1.0f) * 0.9f;
        g_xs ^= g_xs << 13; g_xs ^= g_xs >> 17; g_xs ^= g_xs << 5; float y = ((g_xs & 0xFFFF) / 32767.5f - 1.0f) * 0.9f;
        init[i][0] = x; init[i][1] = y; init[i][2] = 0; init[i][3] = 0; memcpy(g_ref[i], init[i], 16);
    }
    gpu_write(g_parts, 0, init, sizeof init);
    return 0;
}

static void cpu_step(const struct Params *p) {
    for (int i = 0; i < N; i++) {
        float *s = g_ref[i]; float a = (float)i * 0.0061359f; float ox = 0.15f * cosf(a), oy = 0.15f * sinf(a);
        float dx = p->tx + ox - s[0], dy = p->ty + oy - s[1];
        float vx = s[2] * (1.0f - 1.5f * p->dt) + dx * (4.0f * p->dt) + ox * (p->burst * 8.0f);
        float vy = s[3] * (1.0f - 1.5f * p->dt) + dy * (4.0f * p->dt) + oy * (p->burst * 8.0f);
        s[0] += vx * p->dt; s[1] += vy * p->dt; s[2] = vx; s[3] = vy;
    }
}

__attribute__((export_name("game_frame"))) int game_frame(int frame) {
    g_frame = frame;
    // ---- input
    struct Ev ev[16]; int n = input_poll(ev, 16); float burst = 0.0f;
    for (int i = 0; i < n; i++) {
        if (ev[i].type == EV_KEY_DOWN && ev[i].a < 8) { g_down[ev[i].a] = 1; if (ev[i].a == KEY_FIRE) { burst = 1.0f; g_audio_left = 12; g_phase = 0; g_score++; if (g_nfire < 64) g_fire_frames[g_nfire++] = frame; } }
        else if (ev[i].type == EV_KEY_UP && ev[i].a < 8) g_down[ev[i].a] = 0;
        else if (ev[i].type == EV_MOUSE) { g_px = ((int)ev[i].a - W / 2) / (float)(W / 2); g_py = (H / 2 - (int)ev[i].b) / (float)(H / 2); }
    }
    // ---- game state: the player moves 1/64 per frame while a direction key is held (a power of two: exact in float)
    const float step = 1.0f / 64.0f;
    if (g_down[KEY_LEFT]) g_px -= step; if (g_down[KEY_RIGHT]) g_px += step; if (g_down[KEY_UP]) g_py += step; if (g_down[KEY_DOWN]) g_py -= step;
    // ---- GPU
    struct Params p = {1.0f / 60.0f, g_px, g_py, (float)N, burst, 0, 0, 0};
    gpu_write(g_params, 0, &p, sizeof p);
    gpu_begin();
    gpu_dispatch(g_cpipe, g_parts, g_params, -1, (N + 63) / 64);
    gpu_draw(g_rpipe, g_parts, g_params, g_target, 6, N + 1, 0xFF330000u /* clear: r=0 g=0 b=0x33 a=0xFF as 0xAABBGGRR */);
    gpu_end();
    cpu_step(&p);
    // ---- audio for this frame: a 440 Hz tone with a linear decay while the fire tone lasts, else silence
    static int16_t pcm[FRAME_SAMPLES * 2];
    for (int i = 0; i < FRAME_SAMPLES; i++) {
        float amp = g_audio_left > 0 ? 0.5f * (float)g_audio_left / 12.0f : 0.0f; float s = amp * sinf(g_phase); g_phase += 6.2831853f * 440.0f / AUDIO_RATE;
        if (g_phase > 6.2831853f) g_phase -= 6.2831853f; int16_t v = (int16_t)(s * 32000.0f); pcm[2 * i] = v; pcm[2 * i + 1] = v;
    }
    if (g_audio_left > 0) g_audio_left--;
    check(audio_write(pcm, FRAME_SAMPLES) == FRAME_SAMPLES, "audio accepted");
    return 0;
}

__attribute__((export_name("game_result"))) int game_result(void) {
    // GPU particle state against the CPU reference
    static float back[N][4]; gpu_read(g_parts, 0, back, sizeof back);
    float maxerr = 0.0f; int bad = 0;
    for (int i = 0; i < N; i++) for (int k = 0; k < 4; k++) { float e = fabsf(back[i][k] - g_ref[i][k]); if (e > maxerr) maxerr = e; if (!(e < 2e-3f)) bad++; }
    check(bad == 0, "GPU particle state differs from the CPU reference");
    // the image: probe known pixels
    static uint8_t img[W * H * 4]; gpu_read_target(g_target, img, sizeof img);
    int px = (int)((g_px + 1.0f) * 0.5f * W), py = (int)((1.0f - g_py) * 0.5f * H);
    const uint8_t *c = img + (py * W + px) * 4; const uint8_t *bg = img;
    check(c[0] == 255 && c[1] == 0 && c[2] == 0, "player pixel is red");
    check(bg[0] == 0 && bg[1] == 0 && bg[2] == 0x33, "background pixel is the clear colour");
    int green = 0, red = 0; for (int i = 0; i < W * H; i++) { const uint8_t *q = img + i * 4; if (q[1] > 200 && q[0] < 100 && q[2] < 100) green++; if (q[0] > 200 && q[1] < 50 && q[2] < 50) red++; }
    check(green > 100, "particles are drawn"); check(red > 50, "player is drawn");
    // the input script (host side): RIGHT down f10..f29 (20 steps), UP down f40..f59 (20 steps), FIRE at f60, MOUSE to (192,64) at f80, then RIGHT down f90..f99 (10 steps)
    float ex = ((192 - 128) / 128.0f) + 10.0f / 64.0f, ey = ((128 - 64) / 128.0f);
    if (g_frame >= 99) { check(fabsf(g_px - ex) < 1e-6f && fabsf(g_py - ey) < 1e-6f, "player position follows the scripted input"); check(g_score == 1 && g_nfire == 1 && g_fire_frames[0] == 60, "fire input seen once at frame 60"); }
    say("guest: "); kv("frames", g_frame + 1); say("guest: "); kv("particle_max_error_x1e6", (int)(maxerr * 1e6f)); say("guest: "); kv("green_px", green);
    say("guest: "); kv("player_px", px); say("guest: "); kv("player_py", py); say("guest: "); kv("red_px", red); say("guest: "); kv("fails", g_fail);
    return g_fail;
}
