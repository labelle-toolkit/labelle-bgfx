// Browser fullscreen for the wasm build: the JS half of `window.zig`'s wasm
// `setFullscreen` / `isFullscreen` (labelle-bgfx#99).
//
// Fullscreen on the web is the DOM's Fullscreen API, not a window-system call,
// so this targets the whole PAGE (`document.documentElement`), not the
// `<canvas>`: the page's own sizing script keeps fitting the canvas and its
// drawing buffer to the viewport, which is what makes fullscreen actually fill
// the screen at full resolution.
//
// The API is asynchronous. `requestFullscreen()` returns a promise and the
// document only reports `fullscreenElement` once it settles, while the frame
// loop reads `isFullscreen()` straight after issuing the request and hands it
// to the engine's `syncFullscreen`. So an in-flight request is reported as its
// TARGET until it settles; otherwise a settings checkbox would flicker back for
// the frames in between. A rejected request (no user activation, an iframe
// without `allowfullscreen`, a browser without the API) clears the pending
// state, so the real state wins again, and it is logged ONCE rather than
// thrown: failing to go fullscreen must never take the game down.
//
// Older Safari only has the prefixed, promise-less `webkitRequestFullscreen`;
// there the pending state is settled by the one-shot `webkitfullscreenchange` /
// `webkitfullscreenerror` events instead.
//
// Compiled only into the wasm graph, like `video/web_video.c`, and for the same
// linker reason: Zig calls the plain C wrappers at the bottom, never the EM_JS
// functions, because a reference to an EM_JS import alone doesn't pull this
// object out of the static lib and emcc then reports the JS functions as
// undefined symbols.

#include <emscripten/em_js.h>

EM_JS(void, labelle_web_fullscreen_set_js, (int on), {
    if (typeof document === 'undefined') return;
    const d = document;
    const st = globalThis.__labelleFullscreen ||
        (globalThis.__labelleFullscreen = { pending: null, warned: false });
    const want = !!on;
    const current = !!(d.fullscreenElement || d.webkitFullscreenElement);
    if (st.pending === null && current === want) return;

    const warn = (what, err) => {
        if (st.warned) return;
        st.warned = true;
        const msg = err && err.message ? err.message : String(err);
        console.warn('[labelle] fullscreen ' + what + ' failed: ' + msg);
    };
    const what = want ? 'request' : 'exit';
    const settle = () => { st.pending = null; };

    try {
        const el = d.documentElement;
        if (want && el.requestFullscreen) {
            st.pending = true;
            el.requestFullscreen().then(settle, (err) => { settle(); warn(what, err); });
        } else if (!want && d.exitFullscreen && d.fullscreenElement) {
            st.pending = false;
            d.exitFullscreen().then(settle, (err) => { settle(); warn(what, err); });
        } else if (want && el.webkitRequestFullscreen) {
            st.pending = true;
            const done = (ok) => () => {
                d.removeEventListener('webkitfullscreenchange', onChange);
                d.removeEventListener('webkitfullscreenerror', onError);
                settle();
                if (!ok) warn(what, 'webkitfullscreenerror');
            };
            const onChange = done(true), onError = done(false);
            d.addEventListener('webkitfullscreenchange', onChange);
            d.addEventListener('webkitfullscreenerror', onError);
            el.webkitRequestFullscreen();
        } else if (!want && d.webkitExitFullscreen && d.webkitFullscreenElement) {
            d.webkitExitFullscreen();
        } else if (want) {
            warn(what, 'the Fullscreen API is not available');
        }
    } catch (err) {
        settle();
        warn(what, err);
    }
});

EM_JS(int, labelle_web_fullscreen_is_js, (), {
    if (typeof document === 'undefined') return 0;
    const st = globalThis.__labelleFullscreen;
    if (st && st.pending !== null) return st.pending ? 1 : 0;
    return (document.fullscreenElement || document.webkitFullscreenElement) ? 1 : 0;
});

// Can this page go fullscreen at all? False where the browser refuses the API
// for pages (iPhone Safari) or the page sits in an iframe without
// `allowfullscreen`; a settings UI greys its option out instead of offering a
// switch that can only fail.
EM_JS(int, labelle_web_fullscreen_available_js, (), {
    if (typeof document === 'undefined') return 0;
    return (document.fullscreenEnabled || document.webkitFullscreenEnabled) ? 1 : 0;
});

void labelle_web_fullscreen_set(int on) { labelle_web_fullscreen_set_js(on); }
int labelle_web_fullscreen_is(void) { return labelle_web_fullscreen_is_js(); }
int labelle_web_fullscreen_available(void) { return labelle_web_fullscreen_available_js(); }
