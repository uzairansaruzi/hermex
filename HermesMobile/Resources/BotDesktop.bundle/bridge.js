import RFB from './novnc/core/rfb.js';
import { initLogging } from './novnc/core/util/logging.js';

// Protocol errors and desktop names must never reach console or native logs.
initLogging('none');

const MAX_RECEIVE_BYTES = 4 * 1024 * 1024;
const MAX_SEND_BYTES = 64 * 1024;
let active = null;

function post(message) {
    window.webkit.messageHandlers.desktop.postMessage(message);
}

function encode(bytes) {
    const parts = [];
    for (let offset = 0; offset < bytes.length; offset += 8192) {
        parts.push(String.fromCharCode(...bytes.subarray(offset, offset + 8192)));
    }
    return btoa(parts.join(''));
}

function dispose() {
    const session = active;
    active = null;
    if (!session) return;
    // Silence native notifications before noVNC closes its transport.
    session.silent = true;
    session.rfb?.disconnect();
    session.channel.readyState = 3;
    session.channel.onmessage = null;
    document.getElementById('screen').replaceChildren();
}

function fail(session) {
    if (active !== session) return;
    dispose();
    post({ type: 'failed', generation: session.generation });
}

function open(generation) {
    if (!Number.isSafeInteger(generation) || generation < 0) return;
    dispose();
    const session = { generation, silent: false, rfb: null, channel: null };
    active = session;
    const channel = {
        readyState: 1,
        binaryType: 'arraybuffer',
        bufferedAmount: 0,
        protocol: '',
        onerror: null,
        onmessage: null,
        onopen: null,
        onclose: null,
        send(data) {
            if (active !== session || channel.readyState !== 1) return;
            const bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
                : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : null;
            if (!bytes || bytes.byteLength > MAX_SEND_BYTES) {
                fail(session);
                return;
            }
            post({ type: 'send', data: encode(bytes), generation });
        },
        close() {
            if (channel.readyState === 3) return;
            channel.readyState = 3;
            if (!session.silent) post({ type: 'close', generation });
            // Match WebSocket's asynchronous close, including during teardown,
            // so noVNC cancels its disconnect timeout and releases listeners.
            queueMicrotask(() => channel.onclose?.({ code: 1000, wasClean: true }));
        }
    };
    session.channel = channel;
    try {
        const rfb = new RFB(document.getElementById('screen'), channel, { shared: true });
        session.rfb = rfb;
        rfb.viewOnly = true;
        rfb.resizeSession = false;
        rfb.scaleViewport = true;
        rfb.focusOnClick = false;
        rfb.qualityLevel = 7;
        rfb.compressionLevel = 2;
        rfb.addEventListener('connect', () => {
            if (active === session) post({ type: 'connected', generation });
        });
        for (const type of ['disconnect', 'securityfailure', 'credentialsrequired', 'serververification']) {
            rfb.addEventListener(type, () => fail(session));
        }
    } catch (_) {
        fail(session);
    }
}

function receive(base64, generation) {
    const session = active;
    if (!session || session.generation !== generation || session.channel.readyState !== 1) return;
    try {
        if (typeof base64 !== 'string' || base64.length > 4 * Math.ceil(MAX_RECEIVE_BYTES / 3)) {
            fail(session);
            return;
        }
        const binary = atob(base64);
        if (binary.length > MAX_RECEIVE_BYTES) {
            fail(session);
            return;
        }
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        session.channel.onmessage?.({ data: bytes.buffer });
    } catch (_) {
        fail(session);
    }
}

// Only native lifecycle and incoming bytes are exposed. No RFB object, input,
// clipboard, credentials, server URL or authentication ticket enters this API.
Object.defineProperty(window, 'HermexDesktop', {
    value: Object.freeze({ open, receive, disconnect: dispose }),
    writable: false,
    configurable: false
});
post({ type: 'ready' });
