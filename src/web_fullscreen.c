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
// to the engine's `syncFullscreen`. So while a transition is in flight,
// `isFullscreen()` reports the LATEST request; otherwise a settings checkbox
// would flicker back for the frames in between. A request made during a
// flight (on, then off before the browser finished) is kept and reconciled
// when the flight settles, so the last choice always wins. A rejected request
// (no user activation, an iframe without `allowfullscreen`, a browser without
// the API) is dropped, so the real state wins again, and it is logged ONCE
// rather than thrown: failing to go fullscreen must never take the game down.
//
// The PAGE must size the canvas to the viewport. Going fullscreen enlarges the
// document, not the canvas; a page that fits the canvas and its drawing buffer
// to the viewport (as Flying Platform's does) then fills the screen. The default
// emcc shell does not, so a game on it gets a fullscreen page around an
// unchanged canvas (labelle-bgfx#130).
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
    // `desired` is the LATEST request, `pending` the transition in flight.
    // They are separate so a request made while another is in flight (a quick
    // on-then-off) is not lost: it is reconciled when the flight settles.
    const st = globalThis.__labelleFullscreen ||
        (globalThis.__labelleFullscreen = { pending: null, desired: null, warned: false });
    st.desired = !!on;
    if (st.pending !== null) return; // reconciled by `settle` below

    const warn = (what, err) => {
        if (st.warned) return;
        st.warned = true;
        const msg = err && err.message ? err.message : String(err);
        console.warn('[labelle] fullscreen ' + what + ' failed: ' + msg);
    };
    const isOn = () => !!(d.fullscreenElement || d.webkitFullscreenElement);

    // Start whatever transition moves the page toward `st.desired`. Called
    // again after each flight settles, so the last request always wins.
    const drive = () => {
        const want = st.desired;
        if (want === null || isOn() === want) { st.desired = null; return; }
        const what = want ? 'request' : 'exit';
        // A rejection drops the request instead of retrying: the reason (no
        // user activation, no `allowfullscreen`) would only fail again.
        const settle = (ok, err) => {
            st.pending = null;
            if (!ok) { st.desired = null; warn(what, err); return; }
            drive();
        };
        // Older Safari: the prefixed API is promise-less but just as
        // asynchronous, so its one-shot change / error events settle the
        // flight — for the exit as much as the request, or a toggle made
        // before the exit lands would read the stale element and be dropped.
        const viaWebkitEvents = (target, start) => {
            st.pending = target;
            const done = (ok) => () => {
                d.removeEventListener('webkitfullscreenchange', onChange);
                d.removeEventListener('webkitfullscreenerror', onError);
                settle(ok, 'webkitfullscreenerror');
            };
            const onChange = done(true), onError = done(false);
            d.addEventListener('webkitfullscreenchange', onChange);
            d.addEventListener('webkitfullscreenerror', onError);
            start();
        };
        try {
            const el = d.documentElement;
            if (want && el.requestFullscreen) {
                st.pending = true;
                el.requestFullscreen().then(() => settle(true), (err) => settle(false, err));
            } else if (!want && d.exitFullscreen && d.fullscreenElement) {
                st.pending = false;
                d.exitFullscreen().then(() => settle(true), (err) => settle(false, err));
            } else if (want && el.webkitRequestFullscreen) {
                viaWebkitEvents(true, () => el.webkitRequestFullscreen());
            } else if (!want && d.webkitExitFullscreen && d.webkitFullscreenElement) {
                viaWebkitEvents(false, () => d.webkitExitFullscreen());
            } else {
                st.desired = null;
                if (want) warn(what, 'the Fullscreen API is not available');
            }
        } catch (err) {
            st.pending = null;
            st.desired = null;
            warn(what, err);
        }
    };
    drive();
});

EM_JS(int, labelle_web_fullscreen_is_js, (), {
    if (typeof document === 'undefined') return 0;
    // While a transition is in flight, report the latest request (it wins
    // once the flight settles), so the frame loop's read-back doesn't flicker
    // the settings checkbox back for the frames in between.
    const st = globalThis.__labelleFullscreen;
    if (st && st.pending !== null) return (st.desired !== null ? st.desired : st.pending) ? 1 : 0;
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
