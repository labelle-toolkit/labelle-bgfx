// miniaudio implementation translation unit.
//
// Single-header public-domain audio library (mackron/miniaudio). The
// header is API-only by default; defining MINIAUDIO_IMPLEMENTATION here
// pulls in the implementation so the bgfx backend's audio module can
// link an `ma_device` playback device against it.
//
// We only need the playback device + the platform's native backend
// (CoreAudio on macOS, WASAPI on Windows, ALSA/PulseAudio on Linux),
// so trim everything the bgfx PCM mixer doesn't use: miniaudio's own
// decoders, encoders, resource manager, node graph, and generators.
// This keeps the translation unit small and avoids dragging in extra
// system libraries (e.g. we never touch miniaudio's WAV decoder — the
// bgfx backend decodes WAV itself).
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
