const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

function bridge(value = '', priority = '') {
    const properties = new Map(value ? [['cursor', [value, priority]]] : []);
    const events = {};
    const canvas = {
        style: {
            getPropertyValue: k => properties.get(k)?.[0] || '',
            getPropertyPriority: k => properties.get(k)?.[1] || '',
            setProperty: (k, v, p) => properties.set(k, [v, p]),
            removeProperty: k => properties.delete(k),
        },
        hover: true,
        matches() { return this.hover; },
        addEventListener(name, fn) { (events[name] ||= []).push(fn); },
        removeEventListener(name, fn) { events[name] = (events[name] || []).filter(f => f !== fn); },
    };
    const document = { focused: true, hasFocus() { return this.focused; } };
    const c = vm.createContext({ Module: { canvas }, document, window: canvas });
    const source = readFileSync('src/web_cursor.c', 'utf8');
    for (const m of source.matchAll(/EM_JS\(int, (\w+), \(([^)]*)\), \{([\s\S]*?)\n\}\);/g)) {
        const params = m[2].trim() ? m[2].trim().split(/\s+/).pop() : '';
        vm.runInContext(`function ${m[1]}(${params}) {${m[3]}\n}`, c);
    }
    return { c, canvas, document, emit: (name, pointerType = 'mouse') => events[name]?.forEach(fn => fn({ pointerType })) };
}

for (const value of ['', 'crosshair']) test(`hide repeatedly then restore '${value}' and its priority`, () => {
    const { c, canvas } = bridge(value, 'important');
    assert.equal(c.labelle_web_cursor_visible_js(1), 1);
    assert.equal(c.labelle_web_cursor_visible_js(0), 1);
    assert.equal(c.labelle_web_cursor_visible_js(0), 1);
    assert.equal(canvas.style.getPropertyValue('cursor'), 'none');
    c.labelle_web_cursor_visible_js(1);
    assert.equal(canvas.style.getPropertyValue('cursor'), value);
    assert.equal(canvas.style.getPropertyPriority('cursor'), value ? 'important' : '');
});

test('mouse enter/leave, focus loss, CSS hover and touch control overlay eligibility', () => {
    const { c, canvas, document, emit } = bridge();
    assert.equal(c.labelle_web_cursor_over_js(), 0);
    emit('pointerenter');
    assert.equal(c.labelle_web_cursor_over_js(), 1);
    document.focused = false;
    assert.equal(c.labelle_web_cursor_over_js(), 0);
    document.focused = true;
    assert.equal(c.labelle_web_cursor_over_js(), 1);
    canvas.hover = false;
    assert.equal(c.labelle_web_cursor_over_js(), 0);
    canvas.hover = true;
    emit('pointerleave');
    assert.equal(c.labelle_web_cursor_over_js(), 0);
    emit('pointerenter', 'touch');
    assert.equal(c.labelle_web_cursor_over_js(), 0);
    emit('pointermove', 'mouse');
    assert.equal(c.labelle_web_cursor_over_js(), 1);
    emit('pointercancel');
    assert.equal(c.labelle_web_cursor_over_js(), 0);
});

test('missing canvas is a safe unsupported operation', () => {
    const { c } = bridge();
    c.Module.canvas = null;
    assert.equal(c.labelle_web_cursor_visible_js(0), 0);
    assert.equal(c.labelle_web_cursor_over_js(), 0);
    delete c.Module;
    assert.equal(c.labelle_web_cursor_visible_js(1), 0);
});

for (const event of ['blur', 'pointerleave', 'pointercancel']) test(`${event} restores style without waiting for another draw frame`, () => {
    const { c, canvas, emit } = bridge('crosshair');
    c.labelle_web_cursor_visible_js(0);
    emit(event);
    assert.equal(canvas.style.getPropertyValue('cursor'), 'crosshair');
    // Can hide again after focus/entry returns, and restore still works.
    c.labelle_web_cursor_visible_js(0);
    c.labelle_web_cursor_visible_js(1);
    assert.equal(canvas.style.getPropertyValue('cursor'), 'crosshair');
});
