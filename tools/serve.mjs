// A static server for the browser gates and the showcase.
//
// `python3 -m http.server` would do for a page, but not for this: a
// WebAssembly module has to arrive as `application/wasm` for
// `instantiateStreaming` to take it, and an ES module has to arrive as
// `text/javascript` or the browser refuses the import outright. Both are
// exactly the kind of thing that works on one machine and not the next.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";

const ROOT = resolve(process.argv[3] || ".");
const PORT = Number(process.argv[2] || 8731);

const TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".wasm": "application/wasm",
    ".css": "text/css; charset=utf-8",
    ".png": "image/png",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
    ".map": "application/json; charset=utf-8",
};

const server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://localhost");
    // A path is joined to the root and then checked to still be under it, so
    // `..` in a request cannot read the machine.
    const path = join(ROOT, normalize(decodeURIComponent(url.pathname)));
    if (!path.startsWith(ROOT)) {
        response.writeHead(403).end("outside the served directory");
        return;
    }
    try {
        const info = await stat(path);
        const file = info.isDirectory() ? join(path, "index.html") : path;
        const body = await readFile(file);
        response.writeHead(200, {
            "content-type": TYPES[extname(file)] || "application/octet-stream",
            "cache-control": "no-store",
            // SharedArrayBuffer is not used, but a CanvasKit build that wants
            // threads needs these two and a page that gets them late is a page
            // that has to be reloaded.
            "cross-origin-opener-policy": "same-origin",
            "cross-origin-embedder-policy": "require-corp",
            "cross-origin-resource-policy": "cross-origin",
        });
        response.end(body);
    } catch {
        response.writeHead(404).end("not found");
    }
});

// Listening only when this file is the program. The browser gate imports it
// for the server object and chooses its own port; a module that listened on
// import would take the default port away from a serve running beside it.
if (process.argv[1] && import.meta.url === `file://${resolve(process.argv[1])}`) {
    server.listen(PORT, "127.0.0.1", () => {
        console.log(`serving ${ROOT} at http://127.0.0.1:${PORT}/`);
    });
}

export { server, ROOT };
