// Browser music loading for the wasm build: the JS half of the web branch of
// `loadMusicAssetAsync` in `audio.zig`.
//
// The web bundle has no file system: assets are served next to the page, like
// the intro clip (`video/web_video.c`). So a music asset is fetched from
// `assets/<name>` and decoded by the browser's own decoder
// (`decodeAudioData`, so MP3, AAC, Ogg Vorbis and WAV, whatever the browser
// supports), the same way Android hands the decode to its platform decoder.
// Decoding through a 48 kHz `OfflineAudioContext` resamples to the mixer's
// rate; mono is spread to both channels. The result is kept on the JS side as
// interleaved stereo i16 until Zig copies it into memory it owns.
//
// Zig polls (`labelle_web_audio_status`) instead of being called back: the
// same shape as the web video bridge, and no wasm exports to keep alive.
// Failure is bounded: a failed fetch or decode reports -1, never a hang.
//
// Compiled only into the wasm graph (`buildWasm`). Zig calls the plain C
// wrappers at the bottom, not the EM_JS imports directly, so referencing them
// keeps this object (and its EM_JS bodies) in the link (see web_video.c).

#include <emscripten/em_js.h>

EM_JS_DEPS(labelle_web_audio, "$UTF8ToString");

// Start fetching and decoding `url`. Returns a load id (> 0), or 0 when the
// page can't decode audio at all.
EM_JS(int, labelle_web_audio_open_js, (const char *url_ptr), {
    const Offline = globalThis.OfflineAudioContext || globalThis.webkitOfflineAudioContext;
    if (typeof fetch === 'undefined' || !Offline) return 0;
    if (!globalThis.__labelleWebAudio) globalThis.__labelleWebAudio = { next: 1, loads: new Map() };
    const reg = globalThis.__labelleWebAudio;
    const url = UTF8ToString(url_ptr);
    const load = { state: 0, pcm: null, frames: 0 };
    const id = reg.next++;
    reg.loads.set(id, load);
    const fail = (why) => {
        console.warn('audio: ' + url + ': ' + why);
        load.state = -1;
    };
    fetch(url)
        .then((res) => {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            return res.arrayBuffer();
        })
        .then((bytes) => new Promise((resolve, reject) => {
            const ctx = new Offline(2, 1, 48000);
            // The callback form: older Safari has no promise-returning decode.
            const p = ctx.decodeAudioData(bytes, resolve, reject);
            if (p && typeof p.catch === 'function') p.catch(reject);
        }))
        .then((buf) => {
            if (reg.loads.get(id) !== load) return;
            const n = buf.length;
            const left = buf.getChannelData(0);
            const right = buf.numberOfChannels > 1 ? buf.getChannelData(1) : left;
            const pcm = new Int16Array(n * 2);
            for (let i = 0; i < n; i++) {
                const l = Math.max(-1, Math.min(1, left[i]));
                const r = Math.max(-1, Math.min(1, right[i]));
                pcm[2 * i] = l < 0 ? l * 0x8000 : l * 0x7fff;
                pcm[2 * i + 1] = r < 0 ? r * 0x8000 : r * 0x7fff;
            }
            load.pcm = pcm;
            load.frames = n;
            load.state = 1;
        })
        .catch((err) => fail(err && err.message ? err.message : String(err)));
    return id;
});

// 0 while loading, -1 if it failed, else the decoded length in frames.
EM_JS(int, labelle_web_audio_status_js, (int id), {
    const reg = globalThis.__labelleWebAudio;
    const load = reg && reg.loads.get(id);
    if (!load) return -1;
    if (load.state === 1) return load.frames > 0 ? load.frames : -1;
    return load.state;
});

// Copy the decoded interleaved stereo i16 into `ptr` (room for `len` samples).
// Returns the number of samples written.
EM_JS(int, labelle_web_audio_copy_js, (int id, short *ptr, int len), {
    const reg = globalThis.__labelleWebAudio;
    const load = reg && reg.loads.get(id);
    if (!load || !load.pcm) return 0;
    const n = Math.min(len, load.pcm.length);
    // Bytes through HEAPU8, the heap view web_video.c already relies on.
    HEAPU8.set(new Uint8Array(load.pcm.buffer, 0, n * 2), ptr);
    return n;
});

// Drop the load and its decoded samples. A load still in flight finishes in
// the background and is discarded.
EM_JS(void, labelle_web_audio_close_js, (int id), {
    const reg = globalThis.__labelleWebAudio;
    if (reg) reg.loads.delete(id);
});

// ── C entry points called from `audio.zig` ───────────────────────────────────
int labelle_web_audio_open(const char *url) { return labelle_web_audio_open_js(url); }
int labelle_web_audio_status(int id) { return labelle_web_audio_status_js(id); }
int labelle_web_audio_copy(int id, short *ptr, int len) { return labelle_web_audio_copy_js(id, ptr, len); }
void labelle_web_audio_close(int id) { labelle_web_audio_close_js(id); }
