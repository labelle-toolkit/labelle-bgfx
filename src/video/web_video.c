// Browser video for the wasm build: the JS half of `video/web.zig`.
//
// There is no decoder we can ship into wasm for H.264/AAC, and the browser
// already has one. So a clip plays in a hidden, MUTED `<video>` element
// (autoplay with sound needs a user gesture; muted autoplay does not), and each
// new frame is drawn into a fixed-size 2D canvas and copied as RGBA into wasm
// memory. `video/player.zig` then uploads it through its CPU RGBA path exactly
// like a native decoder's frame, so pacing, draw and cover/contain fit are the
// same code as on desktop and Android.
//
// The frame size is FIXED (`FRAME_W`×`FRAME_H`, mirrored in `web.zig`) because
// the player sizes its texture when the clip is opened, and a `<video>` only
// learns its dimensions after `loadedmetadata`. The clip is drawn "contain"
// into that buffer (the same geometry as `fit.fitRects(2, …)`), so a 16:9 clip
// fills it exactly and any other aspect gets bars instead of distortion.
//
// Failure is bounded, never a hang: a load/decode `error`, a rejected `play()`,
// no first frame within `FIRST_FRAME_TIMEOUT_MS`, or no progress for
// `STALL_TIMEOUT_MS` mid-clip all report the clip as done, so `eof()` fires and
// a play-once intro hands off like a normal end of clip.
//
// Compiled only into the wasm graph (`buildWasm`), against the emsdk sysroot.
// Zig calls the plain C functions at the bottom, not the EM_JS ones directly:
// an EM_JS function is an import, so a reference to it alone doesn't make the
// linker pull this object out of the static lib, and emcc then reports the
// JS functions as undefined symbols. The wrappers are defined here, so
// referencing them keeps the object (and its EM_JS bodies) in the link.

#include <emscripten/em_js.h>

// UTF8ToString is a JS library function; declare it so emcc links it in.
EM_JS_DEPS(labelle_web_video, "$UTF8ToString");

EM_JS(int, labelle_web_video_open_js, (const char *url_ptr), {
    if (typeof document === 'undefined') return 0;
    const FRAME_W = 1280, FRAME_H = 720;
    const FIRST_FRAME_TIMEOUT_MS = 10000, STALL_TIMEOUT_MS = 5000;
    if (!globalThis.__labelleWebVideo) globalThis.__labelleWebVideo = { next: 1, players: new Map() };
    const reg = globalThis.__labelleWebVideo;

    const video = document.createElement('video');
    video.muted = true;
    video.defaultMuted = true;
    video.setAttribute('muted', '');
    video.playsInline = true;
    video.setAttribute('playsinline', '');
    video.preload = 'auto';

    let canvas;
    if (typeof OffscreenCanvas !== 'undefined') {
        canvas = new OffscreenCanvas(FRAME_W, FRAME_H);
    } else {
        canvas = document.createElement('canvas');
        canvas.width = FRAME_W;
        canvas.height = FRAME_H;
    }
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    if (!ctx) return 0;

    const now = () => performance.now();
    const p = {
        video, ctx, W: FRAME_W, H: FRAME_H,
        FIRST_FRAME_TIMEOUT_MS, STALL_TIMEOUT_MS,
        failed: false, ended: false,
        newFrame: false, mediaTime: 0, copiedTime: -1, gotFirstFrame: false,
        openedAt: now(), lastProgressAt: now(),
        onVisibility: null,
    };

    const fail = (why) => {
        if (!p.failed && !p.ended) console.warn('video: ' + why + ' - ending the clip');
        p.failed = true;
    };
    video.addEventListener('error', () => {
        const e = video.error;
        fail('load/decode error' + (e ? ' (code ' + e.code + ')' : ''));
    });
    video.addEventListener('ended', () => { p.ended = true; });
    video.addEventListener('timeupdate', () => { p.lastProgressAt = now(); });

    // Prefer the per-presented-frame callback: it says exactly when a NEW frame
    // is on the element and its media time. Without it, a changed
    // `currentTime` with decoded data stands in for "new frame".
    if (typeof video.requestVideoFrameCallback === 'function') {
        const onFrame = (_now, meta) => {
            p.newFrame = true;
            p.mediaTime = meta.mediaTime;
            p.lastProgressAt = now();
            if (reg.players.get(p.id) === p) video.requestVideoFrameCallback(onFrame);
        };
        video.requestVideoFrameCallback(onFrame);
        p.hasRvfc = true;
    }

    // A hidden tab pauses rendering (and often the video): don't let the time
    // spent in the background read as a stall when the player comes back.
    p.onVisibility = () => { p.lastProgressAt = now(); if (!p.gotFirstFrame) p.openedAt = now(); };
    document.addEventListener('visibilitychange', p.onVisibility);

    p.id = reg.next++;
    reg.players.set(p.id, p);

    video.src = UTF8ToString(url_ptr);
    const pr = video.play();
    if (pr && typeof pr.catch === 'function') {
        pr.catch((err) => {
            // `close` aborts a pending play(); only a live player counts it.
            if (reg.players.get(p.id) === p) fail('play() rejected: ' + (err && err.name));
        });
    }
    return p.id;
});

// Copy the element's current frame into `ptr` (`len` = W*H*4 RGBA bytes) if a
// frame newer than the last copy is available. Returns its media time in
// seconds, or -1 when there is nothing new to copy.
EM_JS(double, labelle_web_video_frame_js, (int id, unsigned char *ptr, int len), {
    const reg = globalThis.__labelleWebVideo;
    const p = reg && reg.players.get(id);
    if (!p || len !== p.W * p.H * 4) return -1;
    const v = p.video;
    if (v.readyState < 2 || v.videoWidth === 0 || v.videoHeight === 0) return -1; // < HAVE_CURRENT_DATA

    let t;
    if (p.hasRvfc) {
        if (!p.newFrame) return -1;
        p.newFrame = false;
        t = p.mediaTime;
    } else {
        t = v.currentTime;
        if (t === p.copiedTime) return -1;
    }

    // "contain" into the fixed buffer - same geometry as fit.fitRects(2, ...).
    const scale = Math.min(p.W / v.videoWidth, p.H / v.videoHeight);
    const dw = v.videoWidth * scale, dh = v.videoHeight * scale;
    const dx = (p.W - dw) / 2, dy = (p.H - dh) / 2;
    if (dw < p.W || dh < p.H) {
        p.ctx.fillStyle = '#000';
        p.ctx.fillRect(0, 0, p.W, p.H);
    }
    try {
        p.ctx.drawImage(v, dx, dy, dw, dh);
        const img = p.ctx.getImageData(0, 0, p.W, p.H);
        HEAPU8.set(img.data, ptr);
    } catch (err) {
        // A tainted canvas (cross-origin clip) or a lost element: this clip can
        // never be copied, so end it rather than show a frozen black frame.
        p.failed = true;
        console.warn('video: frame copy failed (' + (err && err.name) + ') - ending the clip');
        return -1;
    }
    p.copiedTime = t;
    p.gotFirstFrame = true;
    p.lastProgressAt = performance.now();
    return t;
});

// The element's playback position in seconds - the player's master clock.
EM_JS(double, labelle_web_video_time_js, (int id), {
    const reg = globalThis.__labelleWebVideo;
    const p = reg && reg.players.get(id);
    return p ? p.video.currentTime : 0;
});

// 1 once the clip is over for any reason: played to the end, failed to load or
// decode, autoplay refused, or stalled past the timeouts. 0 while playing.
EM_JS(int, labelle_web_video_done_js, (int id), {
    const reg = globalThis.__labelleWebVideo;
    const p = reg && reg.players.get(id);
    if (!p) return 1;
    if (p.ended || p.failed) return 1;
    const t = performance.now();
    if (!p.gotFirstFrame && t - p.openedAt > p.FIRST_FRAME_TIMEOUT_MS) {
        console.warn('video: no frame within ' + p.FIRST_FRAME_TIMEOUT_MS + ' ms - ending the clip');
        p.failed = true;
        return 1;
    }
    if (p.gotFirstFrame && !p.video.paused && t - p.lastProgressAt > p.STALL_TIMEOUT_MS) {
        console.warn('video: stalled for ' + p.STALL_TIMEOUT_MS + ' ms - ending the clip');
        p.failed = true;
        return 1;
    }
    return 0;
});

// Restart from the beginning (engine-driven loop). A failed clip stays failed.
EM_JS(void, labelle_web_video_restart_js, (int id), {
    const reg = globalThis.__labelleWebVideo;
    const p = reg && reg.players.get(id);
    if (!p || p.failed) return;
    p.ended = false;
    p.copiedTime = -1;
    p.lastProgressAt = performance.now();
    p.video.currentTime = 0;
    const pr = p.video.play();
    if (pr && typeof pr.catch === 'function') pr.catch(() => {});
});

// Release the element and its network/decoder resources.
EM_JS(void, labelle_web_video_close_js, (int id), {
    const reg = globalThis.__labelleWebVideo;
    const p = reg && reg.players.get(id);
    if (!p) return;
    reg.players.delete(id);
    document.removeEventListener('visibilitychange', p.onVisibility);
    try {
        p.video.pause();
        p.video.removeAttribute('src');
        p.video.load();
    } catch (_) {}
});

// ── C entry points called from `web.zig` ─────────────────────────────────────

int labelle_web_video_open(const char *url) { return labelle_web_video_open_js(url); }
double labelle_web_video_frame(int id, unsigned char *ptr, int len) { return labelle_web_video_frame_js(id, ptr, len); }
double labelle_web_video_time(int id) { return labelle_web_video_time_js(id); }
int labelle_web_video_done(int id) { return labelle_web_video_done_js(id); }
void labelle_web_video_restart(int id) { labelle_web_video_restart_js(id); }
void labelle_web_video_close(int id) { labelle_web_video_close_js(id); }
