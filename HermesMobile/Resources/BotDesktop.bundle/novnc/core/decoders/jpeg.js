/*
 * noVNC: HTML5 VNC client
 * Copyright (C) 2019 The noVNC authors
 * Licensed under MPL 2.0 (see LICENSE.txt)
 *
 * See README.md for usage and integration instructions.
 *
 */

// Hermex: bound a whole image, not just each WebSocket receive chunk.
const MAX_JPEG_BYTES = 16 * 1024 * 1024;
const MAX_JPEG_SEGMENTS = 1024;

export default class JPEGDecoder {
    constructor() {
        // RealVNC will reuse the quantization tables
        // and Huffman tables, so we need to cache them.
        this._cachedQuantTables = [];
        this._cachedHuffmanTables = [];

        this._segments = [];
        this._segmentBytes = 0;
    }

    decodeRect(x, y, width, height, sock, display, depth) {
        // A rect of JPEG encodings is simply a JPEG file
        while (true) {
            let segment = this._readSegment(sock);
            if (segment === null) {
                return false;
            }
            this._segments.push(segment);
            this._segmentBytes += segment.length;
            // End of image?
            if (segment[1] === 0xD9) {
                break;
            }
        }

        let huffmanTables = [];
        let quantTables = [];
        for (let segment of this._segments) {
            let type = segment[1];
            if (type === 0xC4) {
                // Huffman tables
                huffmanTables.push(segment);
            } else if (type === 0xDB) {
                // Quantization tables
                quantTables.push(segment);
            }
        }

        const sofIndex = this._segments.findIndex(
            x => x[1] == 0xC0 || x[1] == 0xC2
        );
        if (sofIndex == -1) {
            throw new Error("Illegal JPEG image without SOF");
        }

        const cachedTables = [
            ...(huffmanTables.length === 0 ? this._cachedHuffmanTables : []),
            ...(quantTables.length === 0 ? this._cachedQuantTables : []),
        ];
        const cachedBytes = cachedTables.reduce((sum, segment) => sum + segment.length, 0);
        this._checkLimits(cachedBytes, cachedTables.length);
        this._segments.splice(sofIndex+1, 0, ...cachedTables);

        let length = this._segmentBytes + cachedBytes;

        let data = new Uint8Array(length);
        length = 0;
        for (let segment of this._segments) {
            data.set(segment, length);
            length += segment.length;
        }

        display.imageRect(x, y, width, height, "image/jpeg", data);

        if (huffmanTables.length !== 0) {
            this._cachedHuffmanTables = huffmanTables;
        }
        if (quantTables.length !== 0) {
            this._cachedQuantTables = quantTables;
        }

        this._segments = [];
        this._segmentBytes = 0;

        return true;
    }

    _checkLimits(bytes, segments = 1) {
        if (this._segmentBytes + bytes > MAX_JPEG_BYTES ||
            this._segments.length + segments > MAX_JPEG_SEGMENTS) {
            throw new Error("JPEG image exceeds size or segment limit");
        }
    }

    _readSegment(sock) {
        if (sock.rQwait("JPEG", 2)) {
            return null;
        }

        let marker = sock.rQshift8();
        if (marker != 0xFF) {
            throw new Error("Illegal JPEG marker received (byte: " +
                               marker + ")");
        }
        let type = sock.rQshift8();
        if (type === 0xD8 && this._segments.length !== 0) {
            throw new Error("Illegal repeated JPEG start marker");
        }
        this._checkLimits(2);
        if (type >= 0xD0 && type <= 0xD9 || type == 0x01) {
            // No length after marker
            return new Uint8Array([marker, type]);
        }

        if (sock.rQwait("JPEG", 2, 2)) {
            return null;
        }

        let length = sock.rQshift16();
        if (length < 2) {
            throw new Error("Illegal JPEG length received (length: " +
                               length + ")");
        }
        this._checkLimits(2 + length);

        if (sock.rQwait("JPEG", length-2, 4)) {
            return null;
        }

        let extra = 0;
        if (type === 0xDA) {
            // start of scan
            if (sock.rQwait("JPEG", length-2 + 2, 4)) {
                return null;
            }

            let len = sock.rQlen();
            let data = sock.rQpeekBytes(len, false);

            while (true) {
                let idx = data.indexOf(0xFF, length-2+extra);
                if (idx === -1) {
                    this._checkLimits(4 + len);
                    sock.rQwait("JPEG", Infinity, 4);
                    return null;
                }

                if (idx === len-1) {
                    // The final FF might begin the next marker, not scan data.
                    this._checkLimits(4 + len - 1);
                    sock.rQwait("JPEG", Infinity, 4);
                    return null;
                }

                if (data.at(idx+1) === 0x00 ||
                    (data.at(idx+1) >= 0xD0 && data.at(idx+1) <= 0xD7)) {
                    extra = idx+2 - (length-2);
                    continue;
                }

                extra = idx - (length-2);
                break;
            }
        }

        this._checkLimits(2 + length + extra);
        let segment = new Uint8Array(2 + length + extra);
        segment[0] = marker;
        segment[1] = type;
        segment[2] = length >> 8;
        segment[3] = length;
        segment.set(sock.rQshiftBytes(length-2+extra, false), 4);

        return segment;
    }
}

