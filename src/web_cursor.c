// Canvas-only styling: never hide the pointer over the surrounding page.
// C wrappers force emcc to extract the EM_JS object from the static archive.
#include <emscripten/em_js.h>

EM_JS(int, labelle_web_cursor_visible_js, (int visible), {
    const canvas = typeof Module !== 'undefined' && Module.canvas;
    if (!canvas || !canvas.style) return 0;
    const key = '__labelleCursorStyle';
    if (visible) {
        if (canvas[key]) canvas[key].restore();
    } else {
        if (!canvas[key]) {
            const saved = canvas[key] = {
                value: canvas.style.getPropertyValue('cursor'),
                priority: canvas.style.getPropertyPriority('cursor')
            };
            saved.restore = () => {
                if (saved.value) canvas.style.setProperty('cursor', saved.value, saved.priority);
                else canvas.style.removeProperty('cursor');
                canvas.removeEventListener('pointerleave', saved.restore);
                canvas.removeEventListener('pointercancel', saved.restore);
                if (typeof window !== 'undefined') window.removeEventListener('blur', saved.restore);
                delete canvas[key];
            };
            // Restore even if requestAnimationFrame stops on focus loss. The
            // next active draw frame can hide it again alongside its overlay.
            canvas.addEventListener('pointerleave', saved.restore);
            canvas.addEventListener('pointercancel', saved.restore);
            if (typeof window !== 'undefined') window.addEventListener('blur', saved.restore);
        }
        canvas.style.setProperty('cursor', 'none', 'important');
    }
    return 1;
});

EM_JS(int, labelle_web_cursor_over_js, (), {
    const canvas = typeof Module !== 'undefined' && Module.canvas;
    if (!canvas || typeof document === 'undefined') return 0;
    // Install once, on first query (normally the first draw frame). Pointer
    // events distinguish a real mouse/pen from touch's sticky hover state.
    if (!canvas.__labelleCursorTracking) {
        const st = canvas.__labelleCursorTracking = { over: false };
        const update = e => { st.over = e.pointerType !== 'touch'; };
        canvas.addEventListener('pointerenter', update);
        canvas.addEventListener('pointermove', update);
        canvas.addEventListener('pointerleave', () => { st.over = false; });
        canvas.addEventListener('pointercancel', () => { st.over = false; });
    }
    return canvas.__labelleCursorTracking.over && document.hasFocus() && canvas.matches(':hover') ? 1 : 0;
});

int labelle_web_cursor_visible(int visible) { return labelle_web_cursor_visible_js(visible); }
int labelle_web_cursor_over(void) { return labelle_web_cursor_over_js(); }
