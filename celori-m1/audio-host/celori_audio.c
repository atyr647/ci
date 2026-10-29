// See celori_audio.h. miniaudio is compiled WAV-only with no resource manager (no background threads: every call is made on the host's calling thread; the real-time modes' device thread
// only runs miniaudio's own mixing callback).
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_FLAC
#define MA_NO_MP3
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MINIAUDIO_IMPLEMENTATION
#include "../.deps/miniaudio/miniaudio.h"

#include "celori_audio.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_SOUNDS 64
#define MAX_VOICES 32
#define MAX_SOUND_BYTES (8u << 20)           /* decoded size of one sound */
#define MAX_CAPTURE_FRAMES (48000u * 600u)   /* ten minutes at 48 kHz */
#define CHUNK 512

typedef struct { char key[96]; float* pcm; ma_uint64 frames; ma_uint32 channels; } sound_t;
typedef struct { int in_use; uint64_t id; ma_audio_buffer buffer; ma_sound sound; } voice_t;

struct celori_audio {
    ma_engine engine;
    int mode;
    uint32_t sample_rate;
    sound_t sounds[MAX_SOUNDS];
    uint32_t sound_count;
    voice_t voices[MAX_VOICES];
    uint64_t next_voice, started, stolen;
    int16_t* capture; uint64_t capture_frames; int capture_truncated;
    uint64_t frames_mixed, hash;
    ma_context context; int have_context;
};

static void set_err(char* err, size_t n, const char* msg) { if (err && n) { snprintf(err, n, "%s", msg); } }
static uint64_t fnv(uint64_t h, const void* p, size_t n) { const uint8_t* b = (const uint8_t*)p; for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; } return h; }

celori_audio* celori_audio_create(int mode, uint32_t sample_rate, char* err, size_t err_len) {
    if (mode < 0 || mode > 2 || sample_rate < 8000 || sample_rate > 192000) { set_err(err, err_len, "bad audio mode or sample rate"); return NULL; }
    celori_audio* a = (celori_audio*)calloc(1, sizeof *a);
    if (!a) { set_err(err, err_len, "out of memory"); return NULL; }
    a->mode = mode; a->sample_rate = sample_rate; a->hash = 14695981039346656037ull;
    ma_engine_config cfg = ma_engine_config_init();
    cfg.channels = 2; cfg.sampleRate = sample_rate; cfg.listenerCount = 1;
    if (mode == CELORI_AUDIO_OFFLINE) {
        cfg.noDevice = MA_TRUE;
    } else {
        ma_backend nul[1] = { ma_backend_null };
        ma_result r = ma_context_init(mode == CELORI_AUDIO_NULL ? nul : NULL, mode == CELORI_AUDIO_NULL ? 1 : 0, NULL, &a->context);
        if (r != MA_SUCCESS) { set_err(err, err_len, "no audio backend available"); free(a); return NULL; }
        a->have_context = 1;
        ma_device_config dc = ma_device_config_init(ma_device_type_playback);
        (void)dc;
        cfg.pContext = &a->context;
    }
    ma_result r = ma_engine_init(&cfg, &a->engine);
    if (r != MA_SUCCESS) { set_err(err, err_len, mode == CELORI_AUDIO_OFFLINE ? "audio engine init failed" : "audio device init failed (is there an output device?)"); if (a->have_context) ma_context_uninit(&a->context); free(a); return NULL; }
    if (mode == CELORI_AUDIO_OFFLINE) {
        a->capture = (int16_t*)malloc((size_t)MAX_CAPTURE_FRAMES * 2 * sizeof(int16_t));
        if (!a->capture) { set_err(err, err_len, "out of memory"); ma_engine_uninit(&a->engine); free(a); return NULL; }
    }
    ma_engine_listener_set_world_up(&a->engine, 0, 0, 1, 0);
    return a;
}

static void voice_release(voice_t* v) {
    if (!v->in_use) return;
    ma_sound_uninit(&v->sound);
    ma_audio_buffer_uninit(&v->buffer);
    v->in_use = 0;
}

void celori_audio_destroy(celori_audio* a) {
    if (!a) return;
    for (int i = 0; i < MAX_VOICES; i++) voice_release(&a->voices[i]);
    ma_engine_uninit(&a->engine);
    if (a->have_context) ma_context_uninit(&a->context);
    for (uint32_t i = 0; i < a->sound_count; i++) free(a->sounds[i].pcm);
    free(a->capture);
    free(a);
}

void celori_audio_info_get(const celori_audio* a, celori_audio_info* out) {
    memset(out, 0, sizeof *out);
    out->sample_rate = a->sample_rate; out->channels = 2; out->realtime = a->mode != CELORI_AUDIO_OFFLINE;
    snprintf(out->backend, sizeof out->backend, "%s", a->mode == CELORI_AUDIO_OFFLINE ? "offline" : a->mode == CELORI_AUDIO_NULL ? "null" : ma_get_backend_name(a->context.backend));
}

int celori_audio_find(const celori_audio* a, const char* key, uint32_t* id) {
    for (uint32_t i = 0; i < a->sound_count; i++) if (strcmp(a->sounds[i].key, key) == 0) { *id = i; return 1; }
    return 0;
}

int celori_audio_load(celori_audio* a, const char* key, const uint8_t* wav, size_t size, uint32_t* id, char* err, size_t err_len) {
    if (celori_audio_find(a, key, id)) return 0;
    if (a->sound_count >= MAX_SOUNDS) { set_err(err, err_len, "too many sounds loaded"); return -1; }
    if (strlen(key) >= sizeof a->sounds[0].key) { set_err(err, err_len, "sound path too long"); return -1; }
    ma_decoder_config dc = ma_decoder_config_init(ma_format_f32, 0, a->sample_rate);
    ma_decoder dec;
    if (ma_decoder_init_memory(wav, size, &dc, &dec) != MA_SUCCESS) { set_err(err, err_len, "not a decodable WAV file"); return -1; }
    ma_format fmt; ma_uint32 ch, rate;
    ma_decoder_get_data_format(&dec, &fmt, &ch, &rate, NULL, 0);
    ma_uint64 frames = 0;
    ma_decoder_get_length_in_pcm_frames(&dec, &frames);
    if (ch < 1 || ch > 2 || frames == 0 || frames * ch * sizeof(float) > MAX_SOUND_BYTES) { ma_decoder_uninit(&dec); set_err(err, err_len, "sound is empty, has more than 2 channels, or is too large"); return -1; }
    float* pcm = (float*)malloc((size_t)(frames * ch * sizeof(float)));
    if (!pcm) { ma_decoder_uninit(&dec); set_err(err, err_len, "out of memory"); return -1; }
    ma_uint64 got = 0;
    ma_decoder_read_pcm_frames(&dec, pcm, frames, &got);
    ma_decoder_uninit(&dec);
    sound_t* s = &a->sounds[a->sound_count];
    snprintf(s->key, sizeof s->key, "%s", key); s->pcm = pcm; s->frames = got; s->channels = ch;
    *id = a->sound_count++;
    return 0;
}

int celori_audio_play(celori_audio* a, uint32_t id, float volume, float pitch, float pan, int spatial, float x, float y, float z, uint64_t* voice, char* err, size_t err_len) {
    if (id >= a->sound_count) { set_err(err, err_len, "unknown sound id"); return -1; }
    if (!(volume >= 0.0f && volume <= 4.0f) || !(pitch >= 0.25f && pitch <= 4.0f) || !(pan >= -1.0f && pan <= 1.0f) || !isfinite(x) || !isfinite(y) || !isfinite(z)) { set_err(err, err_len, "play parameter out of range"); return -1; }
    voice_t* slot = NULL;
    for (int i = 0; i < MAX_VOICES; i++) {                       /* a free slot, or one whose sound has finished */
        voice_t* v = &a->voices[i];
        if (v->in_use && ma_sound_at_end(&v->sound)) voice_release(v);
        if (!v->in_use && !slot) slot = v;
    }
    if (!slot) {                                                 /* all busy: steal the oldest */
        for (int i = 0; i < MAX_VOICES; i++) if (!slot || a->voices[i].id < slot->id) slot = &a->voices[i];
        voice_release(slot);
        a->stolen++;
    }
    const sound_t* s = &a->sounds[id];
    ma_audio_buffer_config bc = ma_audio_buffer_config_init(ma_format_f32, s->channels, s->frames, s->pcm, NULL);
    if (ma_audio_buffer_init(&bc, &slot->buffer) != MA_SUCCESS) { set_err(err, err_len, "voice init failed"); return -1; }
    if (ma_sound_init_from_data_source(&a->engine, &slot->buffer, 0, NULL, &slot->sound) != MA_SUCCESS) { ma_audio_buffer_uninit(&slot->buffer); set_err(err, err_len, "voice init failed"); return -1; }
    slot->in_use = 1; slot->id = a->next_voice++;
    ma_sound_set_volume(&slot->sound, volume);
    ma_sound_set_pitch(&slot->sound, pitch);
    ma_sound_set_doppler_factor(&slot->sound, 0.0f);
    if (spatial) {
        ma_sound_set_spatialization_enabled(&slot->sound, MA_TRUE);
        ma_sound_set_position(&slot->sound, x, y, z);
        ma_sound_set_attenuation_model(&slot->sound, ma_attenuation_model_inverse);
        ma_sound_set_min_distance(&slot->sound, 1.0f); ma_sound_set_max_distance(&slot->sound, 50.0f); ma_sound_set_rolloff(&slot->sound, 1.0f);
    } else {
        ma_sound_set_spatialization_enabled(&slot->sound, MA_FALSE);
        ma_sound_set_pan(&slot->sound, pan);
    }
    ma_sound_start(&slot->sound);
    a->started++;
    *voice = slot->id;
    return 0;
}

void celori_audio_set_listener(celori_audio* a, const float pos[3], const float fwd[3], const float up[3]) {
    ma_engine_listener_set_position(&a->engine, 0, pos[0], pos[1], pos[2]);
    ma_engine_listener_set_direction(&a->engine, 0, fwd[0], fwd[1], fwd[2]);
    ma_engine_listener_set_world_up(&a->engine, 0, up[0], up[1], up[2]);
}

void celori_audio_set_master(celori_audio* a, float v) { if (v >= 0.0f && v <= 4.0f) ma_engine_set_volume(&a->engine, v); }

void celori_audio_advance(celori_audio* a, uint32_t frames) {
    if (a->mode != CELORI_AUDIO_OFFLINE || frames > (1u << 20)) return;
    float buf[CHUNK * 2];
    while (frames > 0) {
        const ma_uint32 n = frames < CHUNK ? frames : CHUNK;
        ma_uint64 got = 0;
        ma_engine_read_pcm_frames(&a->engine, buf, n, &got);
        /* miniaudio reports 0 frames read while nothing is playing (and fewer than asked when the last voice ends mid-block); the rest of the block is silence and still counts as time.
           The engine zero-fills the unread part of the buffer. */
        got = n;
        for (ma_uint64 i = 0; i < got * 2; i++) {
            float f = buf[i]; if (!(f == f)) f = 0.0f; if (f > 1.0f) f = 1.0f; if (f < -1.0f) f = -1.0f;
            const int16_t q = (int16_t)lrintf(f * 32767.0f);
            a->hash = fnv(a->hash, &q, sizeof q);
            if (a->capture_frames * 2 + i < (uint64_t)MAX_CAPTURE_FRAMES * 2) a->capture[a->capture_frames * 2 + i] = q; else a->capture_truncated = 1;
        }
        if (a->capture_frames + got <= MAX_CAPTURE_FRAMES) a->capture_frames += got; else a->capture_frames = MAX_CAPTURE_FRAMES;
        a->frames_mixed += got;
        frames -= n;
    }
}

void celori_audio_stats_get(celori_audio* a, celori_audio_stats* out) {
    memset(out, 0, sizeof *out);
    out->sounds_loaded = a->sound_count; out->voices_started = a->started; out->voices_stolen = a->stolen; out->frames_mixed = a->frames_mixed; out->mix_hash = a->hash; out->capture_truncated = a->capture_truncated;
    for (int i = 0; i < MAX_VOICES; i++) if (a->voices[i].in_use && !ma_sound_at_end(&a->voices[i].sound)) out->voices_active++;
}

static void put32(FILE* f, uint32_t v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); fputc((v >> 16) & 255, f); fputc((v >> 24) & 255, f); }
static void put16(FILE* f, uint16_t v) { fputc(v & 255, f); fputc((v >> 8) & 255, f); }

int celori_audio_write_wav(const celori_audio* a, const char* path) {
    if (!a->capture) return -1;
    FILE* f = fopen(path, "wb");
    if (!f) return -1;
    const uint32_t data = (uint32_t)(a->capture_frames * 2 * sizeof(int16_t));
    fwrite("RIFF", 1, 4, f); put32(f, 36 + data); fwrite("WAVEfmt ", 1, 8, f); put32(f, 16); put16(f, 1); put16(f, 2); put32(f, a->sample_rate); put32(f, a->sample_rate * 4); put16(f, 4); put16(f, 16);
    fwrite("data", 1, 4, f); put32(f, data);
    for (uint64_t i = 0; i < a->capture_frames * 2; i++) put16(f, (uint16_t)a->capture[i]);     /* little endian regardless of the host */
    return fclose(f) == 0 ? 0 : -1;
}
