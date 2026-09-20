// A static server for the browser checks and the showcase. Its reason to exist
// is the media types: `application/wasm`, and `text/javascript` for a module.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";

// Read from the environment, not argv: this file is imported by tools with
// argv of their own, and one of them passed an output path as the root.
const ROOT = resolve(process.env.LATTE_SERVE_ROOT || ".");
const PORT = Number(process.env.LATTE_SERVE_PORT || 8731);

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
            // Not used, but a threaded CanvasKit build needs both, and a page
            // that gets them late has to be reloaded.
            "cross-origin-opener-policy": "same-origin",
            "cross-origin-embedder-policy": "require-corp",
            "cross-origin-resource-policy": "cross-origin",
        });
        response.end(body);
    } catch {
        response.writeHead(404).end("not found");
    }
});

// Listening only when this file is the program: the browser check imports it
// and picks its own port, and an import that listened would take the default.
if (process.argv[1] && import.meta.url === `file://${resolve(process.argv[1])}`) {
    const port = Number(process.argv[2] || PORT);
    server.listen(port, "127.0.0.1", () => {
        console.log(`serving ${ROOT} at http://127.0.0.1:${port}/`);
    });
}

/// Starts the server on a free port. Port 0 rather than a fixed one: two
/// checks at once collided, and a check that fails that way cannot be trusted.
export async function listenOnAFreePort(wanted = 0) {
    await new Promise((done, fail) => {
        server.once("error", fail);
        server.listen(wanted, "127.0.0.1", () => { server.removeListener("error", fail); done(); });
    });
    return server.address().port;
}

export { server, ROOT };
