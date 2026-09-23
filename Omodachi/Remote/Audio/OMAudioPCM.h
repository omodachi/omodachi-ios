#ifndef OMAudioPCM_h
#define OMAudioPCM_h
#include <stdint.h>
#include <stddef.h>
#include <math.h>
/// Gain is restricted to attenuation, and invalid external values fail muted.
static inline void OMAudioApplyGain(int16_t *samples, size_t count, float gain) {
    if (!isfinite(gain) || gain < 0) gain = 0;
    if (gain >= 1) return;
    for (size_t i = 0; i < count; i++) samples[i] = (int16_t)lrintf(samples[i] * gain);
}
/// Shared exact microphone PCM contract; no capture or transport side effects.
static inline int OMAudioValidPCMFrame(size_t bytes, uint64_t generation, uint64_t currentGeneration, int active) {
    return active && generation != 0 && generation == currentGeneration && bytes == 1920;
}
#endif
