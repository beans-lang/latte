// The page half of a Latte WebAssembly module: an adapter, owning none of the
// interface. The import list is `browser/bridge.b`; `tools/wasm_abi.sh` pairs.

import { floatImports } from "./latte-floats.js";

const CAPABILITY = {
    FRAME_CLOCK: 1,
    CLIPBOARD: 2,
    TEXT_INPUT: 3,
    ACCESSIBILITY: 4,
    GPU: 5,
    SNAPSHOT: 6,
    FONTS: 7,
    IMAGES: 8,
    POINTER_CAPTURE: 9,
    APPEARANCE: 10,
    REDUCE_MOTION: 11,
};

/// One loaded module and everything the page holds for it.
export class LatteRuntime {
    constructor(options = {}) {
        this.instance = null;
        this.memory = null;
        this.exports = null;
        this.decoder = new TextDecoder("utf-8", { fatal: false });
        this.encoder = new TextEncoder();
        this.frameHandle = 0;
        this.stdout = options.stdout || ((line) => console.log(line));
        this.stderr = options.stderr || ((line) => console.error(line));
        // Output arrives a write at a time, so it is buffered to a newline: a
        // console.log per fragment breaks one println across several lines.
        this.pending = { 1: "", 2: "" };
        this.clipboardText = "";
        this.semanticsHost = options.semanticsHost || null;
        this.editingHost = options.editingHost || null;
        this.renderer = options.renderer || null;
        this.exited = null;
        this.onFrame = options.onFrame || null;
        // Merged into `env`, where wasm-ld puts every undefined symbol. A
        // function: the memory they decode against does not exist yet.
        this.buildImports = typeof options.imports === "function"
            ? options.imports
            : (options.imports ? () => options.imports : null);
        this.extraImports = null;
    }

    /// Feature detection, not a browser name. A capability answered from a
    /// user-agent string is a capability that will be wrong in a year.
    can(capability) {
        switch (capability) {
            case CAPABILITY.FRAME_CLOCK:
                return typeof requestAnimationFrame === "function";
            case CAPABILITY.CLIPBOARD:
                return typeof navigator !== "undefined" && !!navigator.clipboard;
            case CAPABILITY.TEXT_INPUT:
                return !!this.editingHost;
            case CAPABILITY.ACCESSIBILITY:
                return !!this.semanticsHost;
            case CAPABILITY.GPU:
                return !!(this.renderer && this.renderer.isGpu && this.renderer.isGpu());
            case CAPABILITY.SNAPSHOT:
                return !!(this.renderer && this.renderer.snapshot);
            case CAPABILITY.FONTS:
                return !!(this.renderer && this.renderer.useFont);
            case CAPABILITY.IMAGES:
                return !!(this.renderer && this.renderer.image);
            case CAPABILITY.POINTER_CAPTURE:
                return typeof Element !== "undefined" &&
                       typeof Element.prototype.setPointerCapture === "function";
            case CAPABILITY.APPEARANCE:
            case CAPABILITY.REDUCE_MOTION:
                return typeof matchMedia === "function";
            default:
                return false;
        }
    }

    /// A `(pointer, length)` pair as a JavaScript string. A fresh view every
    /// time: `memory.grow` detaches every existing one, silently and to zero.
    text(pointer, length) {
        if (!pointer || length <= 0) return "";
        return this.decoder.decode(new Uint8Array(this.memory.buffer, pointer, length));
    }

    /// Writes a string into a caller's buffer and answers the bytes it needed:
    /// a null buffer asks the length, and one that size takes the copy.
    writeInto(value, pointer, capacity) {
        const bytes = this.encoder.encode(value);
        if (!pointer || capacity <= 0) return bytes.length;
        if (bytes.length > capacity) return bytes.length;
        new Uint8Array(this.memory.buffer, pointer, bytes.length).set(bytes);
        return bytes.length;
    }

    imports() {
        const self = this;
        const core = {
            latte_js_write(stream, pointer, length) {
                const which = stream === 2 ? 2 : 1;
                self.pending[which] += self.text(pointer, length);
                let at = self.pending[which].indexOf("\n");
                while (at >= 0) {
                    const line = self.pending[which].slice(0, at);
                    self.pending[which] = self.pending[which].slice(at + 1);
                    if (which === 2) self.stderr(line); else self.stdout(line);
                    at = self.pending[which].indexOf("\n");
                }
            },

            latte_js_exit(code) {
                self.exited = code;
                // A trap rather than a return. The module called exit
                // because it cannot continue, and returning would let it.
                throw new Error(`the Latte module exited with ${code}`);
            },

            latte_js_now() {
                return performance.now() / 1000;
            },

            latte_js_can(capability) {
                return self.can(capability) ? 1 : 0;
            },

            latte_js_appearance() {
                if (typeof matchMedia !== "function") return 0;
                return matchMedia("(prefers-color-scheme: dark)").matches ? 1 : 0;
            },

            latte_js_scale() {
                return typeof devicePixelRatio === "number" ? devicePixelRatio : 1;
            },

            latte_js_reduce_motion() {
                if (typeof matchMedia !== "function") return 0;
                return matchMedia("(prefers-reduced-motion: reduce)").matches ? 1 : 0;
            },

            latte_js_request_frame() {
                if (typeof requestAnimationFrame !== "function") return -1;
                if (self.frameHandle) return 0;
                self.frameHandle = requestAnimationFrame((stamp) => {
                    self.frameHandle = 0;
                    self.deliverFrame(stamp / 1000);
                });
                return 0;
            },

            latte_js_cancel_frame() {
                if (!self.frameHandle) return 0;
                cancelAnimationFrame(self.frameHandle);
                self.frameHandle = 0;
                return 1;
            },

            latte_js_clipboard_write(pointer, length) {
                const text = self.text(pointer, length);
                self.clipboardText = text;
                if (typeof navigator === "undefined" || !navigator.clipboard) return -1;
                // Fire and forget: the module cannot wait for a promise, and
                // the page's own copy is updated above for a same-document paste.
                navigator.clipboard.writeText(text).catch(() => {});
                return 0;
            },

            latte_js_clipboard_read(pointer, capacity) {
                // The system clipboard reads only from a promise, which this
                // cannot wait for; `noteClipboard` is what the page supplies.
                return self.writeInto(self.clipboardText, pointer, capacity);
            },

            latte_js_text_input(active, pointer, length, anchor, caret, x, y, width, height) {
                if (!self.editingHost) return -1;
                self.editingHost.setState({
                    active: active === 1,
                    text: self.text(pointer, length),
                    anchor, caret, x, y, width, height,
                });
                return 0;
            },

            latte_js_semantics_begin() {
                if (!self.semanticsHost) return -1;
                self.semanticsHost.begin();
                return 0;
            },

            latte_js_semantics_node(id, rolePtr, roleLen, labelPtr, labelLen,
                                    valuePtr, valueLen, x, y, width, height,
                                    enabled, focused) {
                if (!self.semanticsHost) return -1;
                self.semanticsHost.node({
                    id: typeof id === "bigint" ? id : BigInt(id),
                    role: self.text(rolePtr, roleLen),
                    label: self.text(labelPtr, labelLen),
                    value: self.text(valuePtr, valueLen),
                    x, y, width, height,
                    enabled: enabled === 1,
                    focused: focused === 1,
                });
                return 0;
            },

            latte_js_semantics_end() {
                if (!self.semanticsHost) return -1;
                self.semanticsHost.end();
                return 0;
            },
        };
        // Floating-point text, part of the core rather than an option: a
        // program that puts a float into a string panics without it.
        Object.assign(core, floatImports(this));
        if (this.buildImports && !this.extraImports) {
            this.extraImports = this.buildImports(this);
        }
        // A name supplied twice is a mistake worth catching here: the page
        // would otherwise get whichever one the spread happened to put last.
        if (this.extraImports) {
            for (const name of Object.keys(this.extraImports)) {
                if (name in core) {
                    throw new Error(`${name} is supplied twice: once by the runtime and once by the page`);
                }
            }
        }
        return { env: Object.assign(core, this.extraImports || {}) };
    }

    /// Hands the module the frame it asked for.
    deliverFrame(seconds) {
        if (this.exports.latte_frame) this.exports.latte_frame(seconds);
        if (this.onFrame) this.onFrame(seconds);
    }

    /// What a paste event put on the clipboard, so the next synchronous read
    /// sees it.
    noteClipboard(text) {
        this.clipboardText = text;
    }

    /// Flushes any output that has no newline after it. Called at the end of a
    /// run, so a last line without a `\n` is not silently dropped.
    flush() {
        for (const which of [1, 2]) {
            if (this.pending[which]) {
                const line = this.pending[which];
                this.pending[which] = "";
                if (which === 2) this.stderr(line); else this.stdout(line);
            }
        }
    }

    static async load(url, options = {}) {
        const runtime = new LatteRuntime(options);
        const response = await fetch(url);
        if (!response.ok) {
            throw new Error(`could not fetch ${url}: ${response.status} ${response.statusText}`);
        }
        // Streaming where the server sent the right type, buffered where it
        // did not: application/octet-stream is what a file server often sends.
        let result;
        const imports = runtime.imports();
        if (WebAssembly.instantiateStreaming &&
            (response.headers.get("content-type") || "").includes("application/wasm")) {
            result = await WebAssembly.instantiateStreaming(response, imports);
        } else {
            result = await WebAssembly.instantiate(await response.arrayBuffer(), imports);
        }
        runtime.instance = result.instance;
        runtime.exports = result.instance.exports;
        runtime.memory = result.instance.exports.memory;
        if (!runtime.memory) {
            throw new Error(`${url} did not export its linear memory`);
        }
        // The module's own startup, which a library has no `main` to run. It
        // does not fail without this; reflection is simply absent. Idempotent.
        if (typeof runtime.exports.beans_module_start === "function") {
            runtime.exports.beans_module_start();
        } else {
            throw new Error(
                `${url} does not export beans_module_start — it was built with a compiler older than the one that emits it, and its reflection registry would be empty`);
        }
        return runtime;
    }
}

export { CAPABILITY };
