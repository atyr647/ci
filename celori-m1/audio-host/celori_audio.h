// Thin C layer over miniaudio for the Celori hosts (proof-host and dawn-host share it). The engine mixes here, never in the guest.
#ifndef CELORI_AUDIO_H
#define CELORI_AUDIO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct celori_audio celori_audio;

enum { CELORI_AUDIO_OFFLINE = 0, CELORI_AUDIO_NULL = 1, CELORI_AUDIO_DEVICE = 2 };

typedef struct { uint32_t sample_rate, channels; int realtime; char backend[32]; } celori_audio_info;
typedef struct { uint32_t sounds_loaded; uint64_t voices_started, voices_stolen; uint32_t voices_active; uint64_t frames_mixed, mix_hash; int capture_truncated; } celori_audio_stats;

/* NULL on failure (message in err). */
celori_audio* celori_audio_create(int mode, uint32_t sample_rate, char* err, size_t err_len);
void celori_audio_destroy(celori_audio* a);
void celori_audio_info_get(const celori_audio* a, celori_audio_info* out);
/* returns 0 on success; id receives the sound id */
int celori_audio_load(celori_audio* a, const char* key, const uint8_t* wav, size_t size, uint32_t* id, char* err, size_t err_len);
int celori_audio_find(const celori_audio* a, const char* key, uint32_t* id);
int celori_audio_play(celori_audio* a, uint32_t id, float volume, float pitch, float pan, int spatial, float x, float y, float z, uint64_t* voice, char* err, size_t err_len);
void celori_audio_set_listener(celori_audio* a, const float pos[3], const float fwd[3], const float up[3]);
void celori_audio_set_master(celori_audio* a, float v);
void celori_audio_advance(celori_audio* a, uint32_t frames);
void celori_audio_stats_get(celori_audio* a, celori_audio_stats* out);
/* the captured mix (offline mode) as a 16-bit stereo WAV; returns 0 on success */
int celori_audio_write_wav(const celori_audio* a, const char* path);

#ifdef __cplusplus
}
#endif
#endif
