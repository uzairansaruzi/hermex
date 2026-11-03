#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const bundle = path.resolve(__dirname, '../../HermesMobile/Resources/BotDesktop.bundle');

function fixture() {
    const messages = [];
    const instances = [];
    const microtasks = [];
    const handlers = new Map(), animationFrames = new Map(), pointerMasks = [];
    let frameID = 0, time = 0;
    let clears = 0;
    class RFB {
        constructor(screen, channel, options) {
            this.channel = channel;
            this.options = options;
            this.events = {};
            this.frames = [];
            this.keys = [];
            this.disconnected = false;
            channel.onmessage = event => this.frames.push(new Uint8Array(event.data));
            channel.onclose = () => this.emit('disconnect');
            instances.push(this);
        }
        addEventListener(type, listener) { this.events[type] = listener; }
        emit(type, detail = { reason: 'secret server text' }) {
            if (type === 'connect') this._rfbConnectionState = 'connected';
            this.events[type]?.({ detail });
        }
        sendKey(...args) { this.keys.push(args); }
        disconnect() { this.disconnected = true; this.channel.close(); }
    }
    RFB.messages = { pointerEvent: (_sock, _x, _y, mask) => pointerMasks.push(mask) };
    const canvas = { width: 200, height: 200, getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 200 }) };
    const window = { webkit: { messageHandlers: { desktop: {
        postMessage: message => messages.push(JSON.parse(JSON.stringify(message)))
    } } } };
    const context = vm.createContext({
        window, RFB, ArrayBuffer, Uint8Array, AbortController,
        performance: { now: () => time },
        requestAnimationFrame: callback => { animationFrames.set(++frameID, callback); return frameID; },
        cancelAnimationFrame: id => animationFrames.delete(id),
        initLogging: level => assert.equal(level, 'none'),
        btoa: value => Buffer.from(value, 'binary').toString('base64'),
        atob: value => {
            if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw Error('bad base64');
            return Buffer.from(value, 'base64').toString('binary');
        },
        queueMicrotask: callback => microtasks.push(callback),
        document: { getElementById: id => {
            assert(['screen', 'input', 'pointer'].includes(id));
            return {
                replaceChildren: () => { clears++; },
                addEventListener: (type, callback) => { if (id === 'input') handlers.set(type, callback); },
                setPointerCapture() {}, querySelector: () => canvas, style: {}, clientWidth: 200, clientHeight: 200
            };
        } }
    });
    const input = fs.readFileSync(path.join(bundle, 'input.js'), 'utf8')
        .replace(/^import .*;\n/gm, '').replace('export function', 'function');
    vm.runInContext(input, context);
    const source = fs.readFileSync(path.join(bundle, 'bridge.js'), 'utf8').replace(/^import .*;\n/gm, '');
    vm.runInContext(source, context);
    return { api: window.HermexDesktop, instances, messages, pointerMasks,
        fire: (type, event = {}) => handlers.get(type)({ type, pointerId: 1, pointerType: 'touch',
            clientX: 50, clientY: 50, preventDefault() {}, ...event }),
        advance: ms => { time += ms; },
        frame: () => { for (const [id, callback] of animationFrames) { animationFrames.delete(id); callback(); } },
        flush: () => {
        while (microtasks.length) microtasks.shift()();
    }, get clears() { return clears; } };
}

test('exposes only a fixed native lifecycle API and view-only settings', () => {
    const f = fixture();
    assert.deepEqual(f.messages, [{ type: 'ready' }]);
    assert.deepEqual(Object.keys(f.api).sort(), ['disconnect', 'input', 'open', 'receive']);
    assert(Object.isFrozen(f.api));
    f.api.open(1);
    const rfb = f.instances[0];
    assert.equal(rfb.viewOnly, true);
    assert.equal(rfb.resizeSession, false);
    assert.equal(rfb.scaleViewport, true);
    assert.equal(rfb.focusOnClick, false);
    assert.equal(rfb.qualityLevel, 7);
    assert.equal(rfb.compressionLevel, 2);
    assert.equal(rfb.options.shared, true);
    assert.equal(rfb.channel.readyState, 1);
    assert.equal(f.messages.length, 1, 'opening transport is not RFB connection success');
    rfb.emit('connect');
    assert.deepEqual(f.messages.at(-1), { type: 'connected', generation: 1 });
});

test('secondary mouse clicks work with or without a contextmenu companion event', () => {
    const f = fixture();
    f.api.open(1);
    f.instances[0].emit('connect');
    const mouse = { pointerType: 'mouse', button: 2 };
    f.fire('contextmenu', mouse);
    assert.deepEqual(f.pointerMasks, [], 'a watcher cannot right click');
    f.api.input('control', { enabled: true }, 1);

    f.fire('contextmenu', mouse);
    assert.deepEqual(f.pointerMasks.splice(0), [4, 0], 'WebKit can send only contextmenu');
    f.fire('pointerdown', { ...mouse, buttons: 0 });
    f.fire('pointerup', mouse);
    f.fire('contextmenu', mouse);
    assert.deepEqual(f.pointerMasks.splice(0), [4, 0], 'button identifies secondary even with an empty buttons mask');
    f.fire('pointerdown', { ...mouse, buttons: 2 });
    f.fire('contextmenu', mouse);
    f.fire('pointerup', mouse);
    assert.deepEqual(f.pointerMasks, [4, 0], 'a contextmenu before release does not duplicate the click');
});

test('a long press or a two-finger tap right-clicks the desktop once', () => {
    const f = fixture();
    f.api.open(1);
    f.instances[0].emit('connect');
    f.api.input('control', { enabled: true }, 1);
    f.fire('pointerdown');
    f.advance(550);
    f.fire('contextmenu');
    f.fire('pointerup');
    assert.deepEqual(f.pointerMasks.splice(0), [4, 0]);
    f.fire('pointerdown');
    f.fire('pointerdown', { pointerId: 2, clientX: 110 });
    f.fire('pointerup');
    f.fire('pointerup', { pointerId: 2 });
    assert.deepEqual(f.pointerMasks, [4, 0]);
});

test('two fingers moving together scroll the remote desktop even when zoomed', () => {
    const f = fixture();
    f.api.open(1);
    f.instances[0].emit('connect');
    f.api.input('control', { enabled: true }, 1);
    f.fire('pointerdown');
    f.fire('pointerdown', { pointerId: 2, clientX: 110 });
    f.fire('pointermove', { clientX: 30 });
    f.fire('pointermove', { pointerId: 2, clientX: 130 });
    f.frame();
    f.fire('pointerup');
    f.fire('pointerup', { pointerId: 2 });
    assert.deepEqual(f.pointerMasks, [], 'pinching only zooms locally');

    f.fire('pointerdown');
    f.fire('pointerdown', { pointerId: 2, clientX: 110 });
    f.fire('pointermove', { clientX: 18 });
    f.fire('pointermove', { pointerId: 2, clientX: 78 });
    f.frame();
    f.fire('pointerup');
    f.fire('pointerup', { pointerId: 2 });
    assert.deepEqual(f.pointerMasks, [64, 0, 64, 0]);
});

test('remote input and clipboard are gated by current generation and control', () => {
    const f = fixture();
    f.api.open(7);
    const rfb = f.instances[0];
    rfb.emit('connect');
    f.api.input('key', { key: 0xff0d }, 7);
    f.api.input('control', { enabled: true }, 6);
    rfb.emit('clipboard', { text: 'private' });
    assert.equal(rfb.keys.length, 0);
    assert.equal(f.messages.at(-1).type, 'connected');

    f.api.input('control', { enabled: true }, 7);
    f.api.input('modifier', { key: 0xffe3 }, 7);
    f.api.input('key', { key: 0x61 }, 7);
    assert.deepEqual(rfb.keys, [[0xffe3, null, true], [0x61], [0xffe3, null, false]]);
    rfb.emit('clipboard', { text: 'allowed' });
    assert.deepEqual(f.messages.at(-1), { type: 'clipboard', generation: 7, text: 'allowed' });

    f.api.input('control', { enabled: false }, 7);
    f.api.input('type', { text: 'blocked' }, 7);
    rfb.emit('clipboard', { text: 'blocked' });
    assert.equal(rfb.keys.length, 3);
    assert.equal(f.messages.at(-1).text, 'allowed');
});

test('binary transport preserves arbitrary bytes and typed-array slice boundaries', () => {
    const f = fixture();
    f.api.open(1);
    const rfb = f.instances[0];
    const bytes = Uint8Array.from([99, 0, 128, 255, 13, 42]);
    rfb.channel.send(bytes.subarray(1, 5));
    assert.deepEqual(f.messages.at(-1), { type: 'send', data: 'AID/DQ==', generation: 1 });
    rfb.channel.send(bytes.buffer);
    assert.deepEqual(Buffer.from(f.messages.at(-1).data, 'base64'), Buffer.from(bytes));
    f.api.receive('AID/DQ==', 1);
    assert.deepEqual(Array.from(rfb.frames[0]), [0, 128, 255, 13]);
});

test('reopen tears down prior session and stale callbacks never affect the current session', () => {
    const f = fixture();
    f.api.open(1);
    const old = f.instances[0];
    f.api.open(1);
    const current = f.instances[1];
    assert(old.disconnected);
    old.emit('connect');
    old.emit('securityfailure');
    old.channel.send(new Uint8Array([1]));
    f.flush();
    assert.deepEqual(f.messages, [{ type: 'ready' }]);
    f.api.receive('AQ==', 1);
    assert.equal(current.frames.length, 1);
    assert.equal(old.frames.length, 0);
    f.api.disconnect();
    f.api.disconnect();
    f.flush();
    f.api.receive('AQ==', 1);
    assert.equal(current.frames.length, 1);
    assert.equal(current.channel.readyState, 3);
    assert.deepEqual(f.messages, [{ type: 'ready' }]);
});

test('security/authentication/remote-close failures are generic, terminal and emitted once', () => {
    for (const event of ['disconnect', 'securityfailure', 'credentialsrequired', 'serververification']) {
        const f = fixture();
        f.api.open(1);
        const rfb = f.instances[0];
        rfb.emit(event);
        rfb.emit(event);
        f.flush();
        assert(rfb.disconnected);
        assert.deepEqual(f.messages, [{ type: 'ready' }, { type: 'failed', generation: 1 }]);
    }
});

test('malformed or oversized bridge data closes rather than allocating unbounded buffers', () => {
    for (const data of ['?', null, 'A'.repeat(4 * Math.ceil(4 * 1024 * 1024 / 3) + 4)]) {
        const f = fixture();
        f.api.open(1);
        f.api.receive(data, 1);
        f.flush();
        assert.equal(f.instances[0].frames.length, 0);
        assert.deepEqual(f.messages.at(-1), { type: 'failed', generation: 1 });
    }
    const f = fixture();
    f.api.open(1);
    f.instances[0].channel.send(new Uint8Array(64 * 1024 + 1));
    f.flush();
    assert.deepEqual(f.messages, [{ type: 'ready' }, { type: 'failed', generation: 1 }]);
});

test('transport close notifies native once and completes noVNC teardown asynchronously', () => {
    const f = fixture();
    f.api.open(1);
    const channel = f.instances[0].channel;
    channel.close();
    channel.close();
    assert.deepEqual(f.messages.at(-1), { type: 'close', generation: 1 });
    f.flush();
    assert.deepEqual(f.messages, [{ type: 'ready' }, { type: 'close', generation: 1 }, { type: 'failed', generation: 1 }]);
});

test('local document blocks networking and vendored protocol suppresses clipboard and local cursor negotiation', () => {
    const html = fs.readFileSync(path.join(bundle, 'viewer.html'), 'utf8');
    assert.match(html, /connect-src 'none'/);
    assert.match(html, /default-src 'none'/);
    assert.match(html, /script-src 'self'/);
    assert.doesNotMatch(html, /https?:\/\//);
    const rfb = fs.readFileSync(path.join(bundle, 'novnc/core/rfb.js'), 'utf8');
    assert.doesNotMatch(rfb, /encs\.push\(encodings\.pseudoEncoding(?:Cursor|VMwareCursor|ExtendedClipboard)\)/);
    const handler = rfb.slice(rfb.indexOf('    _handleServerCutText() {'));
    assert(handler.indexOf('this._sock.rQskipBytes(Math.abs(length))') < handler.indexOf('this.dispatchEvent'));
});

 test('stale native generations cannot deliver bytes to a replacement connection', () => {
    const f = fixture();
    f.api.open(7);
    f.api.open(8);
    f.api.receive('AQ==', 7);
    f.api.receive('AQ==');
    assert.equal(f.instances[1].frames.length, 0);
    f.api.receive('Ag==', 8);
    assert.deepEqual(Array.from(f.instances[1].frames[0]), [2]);
    f.instances[1].emit('connect');
    assert.deepEqual(f.messages.at(-1), { type: 'connected', generation: 8 });
    f.api.open('invalid');
    assert.equal(f.instances.length, 2);
});

test('built viewer performs real RFB handshake and paints pixels without network or input', {
    skip: !process.env.BOT_DESKTOP_PLAYWRIGHT_MODULE
}, async () => {
    const { chromium } = require(process.env.BOT_DESKTOP_PLAYWRIGHT_MODULE);
    const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium', headless: true, args: ['--no-sandbox'] });
    try {
        const page = await browser.newPage();
        const errors = [];
        const requests = [];
        page.on('pageerror', error => errors.push(error.message));
        page.on('request', request => { if (!request.url().startsWith('file:')) requests.push(request.url()); });
        await page.addInitScript(() => {
            window.messages = [];
            window.webkit = { messageHandlers: { desktop: { postMessage: message => window.messages.push(message) } } };
        });
        await page.goto(require('node:url').pathToFileURL(path.join(bundle, 'viewer.html')).href);
        await page.waitForFunction(() => window.messages.some(message => message.type === 'ready'));
        await page.evaluate(() => window.HermexDesktop.open(19));
        const receive = async bytes => page.evaluate(base64 => window.HermexDesktop.receive(base64, 19), Buffer.from(bytes).toString('base64'));
        await receive(Buffer.from('RFB 003.008\n'));
        await receive([1, 1]); // One security type: None; TLS/auth live in native proxy.
        await receive([0, 0, 0, 0]); // SecurityResult: OK.
        await receive([0, 2, 0, 2, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0]);
        await page.waitForFunction(() => window.messages.some(message => message.type === 'connected'));
        // One raw 2x2 rectangle in little-endian BGRX format.
        await receive([0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0,
            0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]);
        const pixels = await page.evaluate(() => Array.from(document.querySelector('canvas').getContext('2d').getImageData(0, 0, 2, 2).data));
        assert.deepEqual(pixels, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]);
        const before = await page.evaluate(() => window.messages.length);
        await page.keyboard.press('a');
        await page.mouse.click(30, 30);
        // Standard clipboard is consumed, never emitted to native or answered.
        await receive([3, 0, 0, 0, 0, 0, 0, 3, 97, 98, 99]);
        assert.equal(await page.evaluate(() => window.messages.length), before);
        await page.evaluate(() => window.HermexDesktop.disconnect());
        await page.waitForFunction(() => document.querySelector('canvas') === null);
        assert.equal(await page.evaluate(() => window.messages.length), before);
        assert.deepEqual(requests, []);
        assert.deepEqual(errors, []);
    } finally {
        await browser.close();
    }
});
