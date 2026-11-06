#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname,
    '../../HermesMobile/Resources/BotDesktop.bundle/novnc/core/decoders/jpeg.js'), 'utf8');
const JPEGDecoder = vm.runInNewContext(source.replace('export default class', 'class') + '\nJPEGDecoder;', { Uint8Array });

// Matches Websock's unread queue and rQwait rollback across receive chunks.
class Socket {
    constructor() { this.bytes = Buffer.alloc(0); this.offset = 0; }
    receive(bytes) { this.bytes = Buffer.concat([this.bytes.subarray(this.offset), Buffer.from(bytes)]); this.offset = 0; }
    rQlen() { return this.bytes.length - this.offset; }
    rQwait(_label, size, rollback = 0) {
        if (this.rQlen() >= size) return false;
        this.offset -= rollback;
        return true;
    }
    rQshift8() { return this.bytes[this.offset++]; }
    rQshift16() { return (this.rQshift8() << 8) | this.rQshift8(); }
    rQpeekBytes(size) { return this.bytes.subarray(this.offset, this.offset + size); }
    rQshiftBytes(size) { const bytes = this.rQpeekBytes(size); this.offset += size; return bytes; }
}

const marker = type => Buffer.from([0xff, type]);
const segment = (type, body = Buffer.alloc(0)) => Buffer.concat([
    Buffer.from([0xff, type, (body.length + 2) >> 8, (body.length + 2) & 255]), body
]);
function fixture() {
    const decoder = new JPEGDecoder(), sock = new Socket(), images = [];
    const display = { imageRect: (...args) => images.push(Buffer.from(args.at(-1))) };
    return { decoder, images, receive(bytes) {
        sock.receive(bytes);
        return decoder.decodeRect(0, 0, 2, 2, sock, display, 24);
    } };
}

test('fragmented JPEGs decode and reuse tables without leaking the prior image budget', () => {
    const f = fixture();
    const tables = [segment(0xc4, Buffer.from([1, 2])), segment(0xdb, Buffer.from([3, 4]))];
    const header = Buffer.concat([marker(0xd8), segment(0xc0), ...tables]);
    const scan = Buffer.concat([segment(0xda), Buffer.from([1, 0xff, 0, 2, 0xff, 0xd0, 3]), marker(0xd9)]);
    const image = Buffer.concat([header, scan]);
    for (let i = 0; i < image.length; i++) assert.equal(f.receive(image.subarray(i, i + 1)), i === image.length - 1);
    assert.deepEqual(f.images, [image]);
    assert.equal(f.receive(Buffer.concat([marker(0xd8), segment(0xc0), scan])), true);
    assert.deepEqual(f.images, [image, image]);
});

test('a repeated start marker is rejected across receives after a valid frame', () => {
    const f = fixture();
    assert.equal(f.receive(Buffer.concat([marker(0xd8), segment(0xc0), marker(0xd9)])), true);
    assert.equal(f.receive(marker(0xd8)), false);
    assert.equal(f.receive([0xff]), false);
    assert.throws(() => f.receive([0xd8]), /repeated JPEG start marker/);
    assert.equal(f.images.length, 1);
});

test('many individually small JPEG segments cannot accumulate without a bound', () => {
    const f = fixture();
    assert.equal(f.receive(marker(0xd8)), false);
    for (let i = 0; i < 1023; i++) assert.equal(f.receive(segment(0xfe)), false);
    assert.throws(() => f.receive(segment(0xfe)), /size or segment limit/);
    assert.equal(f.images.length, 0);
});

test('JPEG byte limits cover accumulated segments and incomplete entropy scans', () => {
    const f = fixture();
    assert.equal(f.receive(marker(0xd8)), false);
    const comment = segment(0xfe, Buffer.alloc(65533));
    for (let i = 0; i < 255; i++) assert.equal(f.receive(comment), false);
    assert.throws(() => f.receive(comment.subarray(0, 4)), /size or segment limit/,
        'reject an oversized segment before allocating or waiting for its body');

    for (const trailingMarker of [false, true]) {
        const scan = fixture();
        assert.equal(scan.receive(Buffer.concat([marker(0xd8), segment(0xc0), segment(0xda)])), false);
        const chunk = Buffer.alloc(1024 * 1024, 1);
        for (let i = 0; i < 15; i++) assert.equal(scan.receive(chunk), false);
        if (trailingMarker) chunk[chunk.length - 1] = 0xff;
        assert.throws(() => scan.receive(chunk), /size or segment limit/);
        assert.equal(scan.images.length, 0);
    }
});

test('completed scans and cached tables count toward the assembled JPEG limits', () => {
    const scan = fixture();
    assert.throws(() => scan.receive(Buffer.concat([
        marker(0xd8), segment(0xc0), segment(0xda), Buffer.alloc(16 * 1024 * 1024, 1), marker(0xd9)
    ])), /size or segment limit/);
    assert.equal(scan.images.length, 0);

    const cached = fixture();
    const table = segment(0xdb, Buffer.alloc(65533));
    assert.equal(cached.receive(Buffer.concat([marker(0xd8), segment(0xc0), table, marker(0xd9)])), true);
    assert.equal(cached.receive(Buffer.concat([marker(0xd8), segment(0xc0)])), false);
    const comment = segment(0xfe, Buffer.alloc(65533));
    for (let i = 0; i < 255; i++) assert.equal(cached.receive(comment), false);
    assert.throws(() => cached.receive(marker(0xd9)), /size or segment limit/,
        'reused tables must not bypass the image budget');
    assert.equal(cached.images.length, 1);
});
