const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const { test } = require('node:test');

function bridge(fetch) {
    const timers = new Map();
    let timer = 0;
    const context = vm.createContext({
        fetch, AbortController, Map, Int16Array, Uint8Array,
        console: { warn() {} }, UTF8ToString: value => value,
        HEAPU8: new Uint8Array(64),
        setTimeout(fn, delay) { assert.equal(delay, 30000); timers.set(++timer, fn); return timer; },
        clearTimeout(id) { timers.delete(id); },
        OfflineAudioContext: class {
            constructor(channels, length, rate) { assert.equal(rate, 48000); }
            decodeAudioData(bytes, resolve) {
                const buffer = { length: 2, numberOfChannels: 2,
                    getChannelData: channel => channel ? [0.25, 1] : [-1, 0.5] };
                resolve(buffer);
                return Promise.resolve(buffer);
            }
        },
    });
    const source = readFileSync('src/web_audio.c', 'utf8');
    for (const match of source.matchAll(/EM_JS\((?:int|void), (\w+), \(([^)]*)\), \{([\s\S]*?)\n\}\);/g)) {
        const params = match[2].split(',').map(p => p.trim().split(/\s+/).pop().replace(/^\*/, '')).join(',');
        vm.runInContext(`function ${match[1]}(${params}) {${match[3]}\n}`, context);
    }
    return { context, timers };
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('decodes at 48 kHz and copies stereo PCM', async () => {
    const { context: c, timers } = bridge(async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(1) }));
    const id = c.labelle_web_audio_open_js('assets/music/demo.mp3');
    await settle();
    assert.equal(c.labelle_web_audio_status_js(id), 2);
    assert.equal(c.labelle_web_audio_copy_js(id, 0, 4), 4);
    assert.deepEqual(Array.from(new Int16Array(c.HEAPU8.buffer, 0, 4)), [-32768, 8191, 16383, 32767]);
    assert.equal(timers.size, 0);
    c.labelle_web_audio_close_js(id);
    assert.equal(c.__labelleWebAudio.loads.size, 0);
});

test('HTTP failure settles the load', async () => {
    const { context: c, timers } = bridge(async () => ({ ok: false, status: 404 }));
    const id = c.labelle_web_audio_open_js('missing.mp3');
    await settle();
    assert.equal(c.labelle_web_audio_status_js(id), -1);
    assert.equal(timers.size, 0);
});

for (const close of [false, true]) test(close ? 'close aborts pending fetch' : 'deadline aborts a stalled response body', async () => {
    let signal;
    const { context: c, timers } = bridge(async (url, options) => {
        signal = options.signal;
        return { ok: true, arrayBuffer: () => new Promise((resolve, reject) => {
            signal.addEventListener('abort', () => reject(new Error('aborted')));
        }) };
    });
    const id = c.labelle_web_audio_open_js('pending.mp3');
    await settle();
    if (close) c.labelle_web_audio_close_js(id);
    else [...timers.values()][0]();
    await settle();
    assert.equal(signal.aborted, true);
    assert.equal(c.labelle_web_audio_status_js(id), -1);
    assert.equal(timers.size, 0);
});
