// Turns a WOFF file back into the TrueType CanvasKit can read, into
// build/fonts/. Not committed: they come from a package. See docs/browser.md.
import { inflateSync } from "node:zlib";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/// The four fonts the shipped theme asks for, by the role each one fills.
const WANTED = [
    ["regular", "node_modules/roboto-fontface/fonts/roboto/Roboto-Regular.woff"],
    ["medium", "node_modules/roboto-fontface/fonts/roboto/Roboto-Medium.woff"],
    ["bold", "node_modules/roboto-fontface/fonts/roboto/Roboto-Bold.woff"],
    ["mono", "node_modules/roboto-fontface/fonts/roboto/Roboto-Regular.woff"],
];

export function woffToSfnt(woff) {
    if (woff.readUInt32BE(0) !== 0x774f4646) {
        throw new Error("not a WOFF file (no wOFF signature)");
    }
    const flavor = woff.readUInt32BE(4);
    const tableCount = woff.readUInt16BE(12);

    const tables = [];
    for (let i = 0; i < tableCount; i++) {
        const at = 44 + i * 20;
        const tag = woff.readUInt32BE(at);
        const offset = woff.readUInt32BE(at + 4);
        const compressed = woff.readUInt32BE(at + 8);
        const original = woff.readUInt32BE(at + 12);
        const checksum = woff.readUInt32BE(at + 16);
        const slice = woff.subarray(offset, offset + compressed);
        // A table is stored rather than compressed when compressing it made it
        // no smaller, and the spec says so by the two lengths being equal.
        const data = compressed === original ? Buffer.from(slice) : inflateSync(slice);
        if (data.length !== original) {
            throw new Error(`table ${i} inflated to ${data.length}, expected ${original}`);
        }
        tables.push({ tag, checksum, data });
    }
    // The sfnt directory is ordered by tag, which is what a reader binary
    // searches. WOFF's own order is not required to be.
    tables.sort((a, b) => a.tag - b.tag);

    // searchRange, entrySelector and rangeShift describe the directory's
    // binary search: some readers reject a wrong one, so they are computed.
    let power = 1;
    let selector = 0;
    while (power * 2 <= tables.length) { power *= 2; selector++; }
    const searchRange = power * 16;

    const header = Buffer.alloc(12 + tables.length * 16);
    header.writeUInt32BE(flavor, 0);
    header.writeUInt16BE(tables.length, 4);
    header.writeUInt16BE(searchRange, 6);
    header.writeUInt16BE(selector, 8);
    header.writeUInt16BE(tables.length * 16 - searchRange, 10);

    let offset = header.length;
    const bodies = [];
    tables.forEach((table, index) => {
        const at = 12 + index * 16;
        header.writeUInt32BE(table.tag, at);
        header.writeUInt32BE(table.checksum, at + 4);
        header.writeUInt32BE(offset, at + 8);
        header.writeUInt32BE(table.data.length, at + 12);
        bodies.push(table.data);
        offset += table.data.length;
        // Every table starts on a four-byte boundary.
        const pad = (4 - (table.data.length % 4)) % 4;
        if (pad) { bodies.push(Buffer.alloc(pad)); offset += pad; }
    });
    return Buffer.concat([header, ...bodies]);
}

if (process.argv[1] && import.meta.url === `file://${resolve(process.argv[1])}`) {
    mkdirSync(resolve(ROOT, "build/fonts"), { recursive: true });
    let wrote = 0;
    for (const [name, source] of WANTED) {
        const from = resolve(ROOT, source);
        let woff;
        try {
            woff = readFileSync(from);
        } catch {
            console.error(`missing ${source} — run 'npm install' first`);
            process.exit(1);
        }
        const sfnt = woffToSfnt(woff);
        const out = resolve(ROOT, `build/fonts/latte-${name}.ttf`);
        writeFileSync(out, sfnt);
        console.log(`build/fonts/latte-${name}.ttf  ${sfnt.length} bytes`);
        wrote++;
    }
    console.log(`${wrote} font(s) ready`);
}
