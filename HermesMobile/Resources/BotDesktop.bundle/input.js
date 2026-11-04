import RFB from './novnc/core/rfb.js';

const clamp = (value, low, high) => Math.max(low, Math.min(value, high));

// The overlay owns all touch input, so viewing, pinching and panning never hit noVNC's canvas.
export function desktopInput(rfb) {
    const screen = document.getElementById('screen');
    const overlay = document.getElementById('input');
    const indicator = document.getElementById('pointer');
    const abort = new AbortController();
    const pointers = new Map();
    const modifiers = new Set();
    let trackpad = false, zoom = 1, tx = 0, ty = 0, gesture = null, cursor = null, mask = 0;
    let lastTap = null, lastTrackpadTap = null;
    let lastMouseRight = null;
    let pairFrame = 0;
    const mouseButtons = bits => (bits & 1) | ((bits & 2) << 1) | ((bits & 4) >> 1);
    const buttonBit = button => [1, 2, 4][button] ?? 0;

    function point(x, y) {
        const canvas = screen.querySelector('canvas');
        const rect = canvas?.getBoundingClientRect();
        if (!rect?.width || !rect.height) return null;
        return [clamp(Math.round((x - rect.left) * canvas.width / rect.width), 0, canvas.width - 1),
                clamp(Math.round((y - rect.top) * canvas.height / rect.height), 0, canvas.height - 1)];
    }

    function showCursor() {
        indicator.hidden = rfb.viewOnly || !trackpad || !cursor;
        const canvas = screen.querySelector('canvas');
        const rect = canvas?.getBoundingClientRect();
        if (indicator.hidden || !rect?.width || !rect.height) return;
        indicator.style.transform = `translate(${rect.left + cursor[0] * rect.width / canvas.width}px, ${rect.top + cursor[1] * rect.height / canvas.height}px)`;
    }

    function pointer(position, buttons) {
        if (!position || rfb.viewOnly || rfb._rfbConnectionState !== 'connected') return;
        cursor = position;
        mask = buttons;
        RFB.messages.pointerEvent(rfb._sock, ...cursor, mask);
        showCursor();
    }

    function click(position, button) {
        pointer(position, button);
        pointer(position, 0);
    }

    function release() {
        if (mask) pointer(cursor, 0);
        modifiers.clear();
        mask = 0;
    }

    function transform(nextZoom, x, y) {
        zoom = clamp(nextZoom, 1, 5);
        tx = clamp(x, -(zoom - 1) * overlay.clientWidth, 0);
        ty = clamp(y, -(zoom - 1) * overlay.clientHeight, 0);
        screen.style.transform = `translate(${tx}px, ${ty}px) scale(${zoom})`;
        showCursor();
    }

    function center() {
        cursor = point(overlay.clientWidth / 2, overlay.clientHeight / 2);
        if (cursor) pointer(cursor, 0);
        showCursor();
    }

    function wheel(position, dx, dy) {
        const x = clamp(Math.trunc(dx / 16), -8, 8), y = clamp(Math.trunc(dy / 16), -8, 8);
        for (let i = 0; i < Math.abs(x); i++) click(position, x > 0 ? 64 : 32);
        for (let i = 0; i < Math.abs(y); i++) click(position, y > 0 ? 16 : 8);
        return { x: dx % 16, y: dy % 16 };
    }

    function pair() {
        const [a, b] = pointers.values();
        return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, distance: Math.hypot(a.x - b.x, a.y - b.y) };
    }

    function updatePair() {
        pairFrame = 0;
        if (pointers.size !== 2 || !gesture?.pair) return;
        const current = pair(), initial = gesture.pair;
        if (!gesture.mode && Math.abs(current.distance - initial.distance) > 8) gesture.mode = 'zoom';
        if (!gesture.mode && Math.hypot(current.x - initial.x, current.y - initial.y) > 12) {
            gesture.mode = rfb.viewOnly ? 'pan' : 'scroll';
        }
        if (gesture.mode === 'scroll') {
            const dx = initial.x - current.x, dy = initial.y - current.y;
            const remainder = wheel(trackpad ? cursor : point(current.x, current.y), dx - gesture.scrollX, dy - gesture.scrollY);
            gesture.scrollX = dx - remainder.x;
            gesture.scrollY = dy - remainder.y;
        } else if (gesture.mode) {
            const scale = gesture.mode === 'zoom' ? clamp(gesture.zoom * current.distance / Math.max(initial.distance, 1), 1, 5) : gesture.zoom;
            transform(scale, current.x - (initial.x - gesture.tx) * scale / gesture.zoom,
                      current.y - (initial.y - gesture.ty) * scale / gesture.zoom);
        }
    }

    function flushPair() {
        if (!pairFrame) return;
        cancelAnimationFrame(pairFrame);
        updatePair();
    }

    function rememberMouseRight(event) {
        lastMouseRight = { x: event.clientX, y: event.clientY, time: performance.now() };
    }

    function on(type, callback) { overlay.addEventListener(type, callback, { signal: abort.signal }); }
    on('pointerdown', event => {
        // WebKit can refuse capture while a touch is changing targets. Still track the tap.
        try { overlay.setPointerCapture(event.pointerId); } catch (_) {}
        pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
        if (pointers.size === 1) {
            gesture = { x: event.clientX, y: event.clientY, start: performance.now(), moved: false, mouse: event.pointerType === 'mouse' };
            gesture.trackDrag = trackpad && lastTrackpadTap && gesture.start - lastTrackpadTap.time < 300 &&
                Math.hypot(gesture.x - lastTrackpadTap.x, gesture.y - lastTrackpadTap.y) < 24;
            if (gesture.mouse) {
                lastMouseRight = null;
                const buttons = mouseButtons(event.buttons) | buttonBit(event.button);
                gesture.right = (buttons & 4) !== 0;
                pointer(point(gesture.x, gesture.y), buttons);
            }
        } else if (pointers.size === 2) {
            if (mask) pointer(cursor, 0);
            gesture = { pair: pair(), zoom, tx, ty, start: gesture?.start ?? performance.now(), scrollX: 0, scrollY: 0 };
        } else {
            gesture = null;
        }
    });
    on('pointermove', event => {
        const next = { x: event.clientX, y: event.clientY };
        const old = pointers.get(event.pointerId);
        if (!old) {
            if (event.pointerType === 'mouse') pointer(point(next.x, next.y), mouseButtons(event.buttons));
            return;
        }
        pointers.set(event.pointerId, next);
        if (!gesture) return;
        if (pointers.size === 2 && gesture.pair) {
            // WebKit sends a move for each finger. Classify them together so a
            // parallel swipe does not look like a pinch halfway through the pair.
            if (!pairFrame) pairFrame = requestAnimationFrame(updatePair);
        } else if (pointers.size === 1 && !gesture.pair) {
            gesture.moved ||= Math.hypot(next.x - gesture.x, next.y - gesture.y) > 5;
            if (gesture.mouse) {
                const buttons = mouseButtons(event.buttons);
                pointer(point(next.x, next.y), gesture.rightCompleted ? buttons & ~4 : buttons);
            }
            else if (gesture.moved && rfb.viewOnly) transform(zoom, tx + next.x - old.x, ty + next.y - old.y);
            else if (gesture.moved && trackpad) {
                const canvas = screen.querySelector('canvas'), rect = canvas?.getBoundingClientRect();
                if (rect?.width && rect.height) {
                    const [x, y] = cursor ?? [canvas.width / 2, canvas.height / 2];
                    const dx = (next.x - old.x) * canvas.width / rect.width;
                    const dy = (next.y - old.y) * canvas.height / rect.height;
                    pointer([clamp(x + dx, 0, canvas.width - 1), clamp(y + dy, 0, canvas.height - 1)], gesture.trackDrag ? 1 : 0);
                }
            } else if (gesture.moved) {
                if (!mask) pointer(point(gesture.x, gesture.y), 1);
                pointer(point(next.x, next.y), 1);
            }
        }
    });
    function finish(event) {
        flushPair();
        if (!pointers.delete(event.pointerId)) return;
        if (gesture?.pair) {
            if (event.type === 'pointercancel') { gesture = null; return; }
            if (pointers.size > 0) return;
            if (!gesture.mode && performance.now() - gesture.start < 300) {
                click(trackpad ? cursor : point(gesture.pair.x, gesture.pair.y), 4);
            }
        } else if (gesture) {
            const position = trackpad && !gesture.mouse ? cursor : point(event.clientX, event.clientY);
            if (mask) pointer(position ?? cursor, 0);
            else if (event.type === 'pointerup' && !gesture.mouse && !gesture.moved) {
                const now = performance.now();
                if (rfb.viewOnly && now - gesture.start < 500) {
                    const x = event.clientX, y = event.clientY;
                    if (lastTap && now - lastTap.time < 300 && Math.hypot(x - lastTap.x, y - lastTap.y) < 24) {
                        if (zoom > 1) transform(1, 0, 0); else transform(2, -x, -y);
                        lastTap = null;
                    } else lastTap = { x, y, time: now };
                } else {
                    click(position, now - gesture.start >= 500 ? 4 : 1);
                    if (trackpad && now - gesture.start < 500) {
                        lastTrackpadTap = { x: event.clientX, y: event.clientY, time: now };
                    }
                }
            }
            if (gesture.mouse && gesture.right) rememberMouseRight(event);
        }
        gesture = null;
    }
    on('pointerup', finish);
    on('pointercancel', finish);
    on('contextmenu', event => {
        event.preventDefault();
        // Touch long-press is handled on pointerup. Some WebKit mouse paths
        // send only contextmenu; others send it alongside pointerdown/up.
        if (event.pointerType === 'touch' || event.pointerType === 'pen' ||
            (event.button !== 2 && event.pointerType !== 'mouse')) return;
        if (gesture?.mouse && gesture.right) {
            if (mask & 4) {
                pointer(point(event.clientX, event.clientY), mask & ~4);
                gesture.rightCompleted = true;
            }
            return;
        }
        if (lastMouseRight && performance.now() - lastMouseRight.time < 300 &&
            Math.hypot(event.clientX - lastMouseRight.x, event.clientY - lastMouseRight.y) < 8) {
            lastMouseRight = null;
            return;
        }
        click(point(event.clientX, event.clientY), 4);
    });
    on('wheel', event => { event.preventDefault(); wheel(point(event.clientX, event.clientY), event.deltaX, event.deltaY); });

    function press(key) {
        for (const modifier of modifiers) rfb.sendKey(modifier, null, true);
        rfb.sendKey(key);
        for (const modifier of [...modifiers].reverse()) rfb.sendKey(modifier, null, false);
        modifiers.clear();
    }

    function type(text) {
        for (const character of text) {
            const code = character.codePointAt(0);
            if (code === 13) continue;
            press(code === 10 ? 0xff0d : code === 9 ? 0xff09 : code < 256 ? code : (0x01000000 | code));
        }
    }

    return {
        command(name, args) {
            if (name === 'control') {
                if (!args.enabled) release();
                cancelAnimationFrame(pairFrame);
                pairFrame = 0;
                pointers.clear();
                gesture = null;
                rfb.viewOnly = !args.enabled;
                rfb._keyboard?.ungrab();
                showCursor();
                return;
            }
            if (name === 'fit') { transform(1, 0, 0); return; }
            if (rfb.viewOnly || rfb._rfbConnectionState !== 'connected') return;
            switch (name) {
                case 'trackpad': trackpad = args.enabled; if (trackpad) center(); else showCursor(); break;
                case 'center': center(); break;
                case 'key': if (Number.isInteger(args.key)) press(args.key); break;
                case 'combo':
                    if (!Array.isArray(args.keys) || args.keys.length > 4 || !args.keys.every(Number.isInteger)) break;
                    release();
                    for (const key of args.keys) rfb.sendKey(key, null, true);
                    for (const key of [...args.keys].reverse()) rfb.sendKey(key, null, false);
                    break;
                case 'modifier':
                    if (!Number.isInteger(args.key)) break;
                    if (!modifiers.delete(args.key)) modifiers.add(args.key);
                    break;
                case 'release': release(); break;
                case 'type': if (typeof args.text === 'string') type(args.text.slice(0, 1000)); break;
                case 'paste': {
                    if (typeof args.text !== 'string') break;
                    const text = args.text.slice(0, 10000);
                    if (/[^\u0000-\u00ff]/.test(text)) type(text.slice(0, 1000));
                    else {
                        rfb.clipboardPasteFrom(text);
                        rfb.sendKey(0xffe3, null, true);
                        rfb.sendKey(0x76);
                        rfb.sendKey(0xffe3, null, false);
                        release();
                    }
                    break;
                }
            }
        },
        dispose() {
            release();
            cancelAnimationFrame(pairFrame);
            abort.abort();
            transform(1, 0, 0);
            indicator.hidden = true;
        }
    };
}
