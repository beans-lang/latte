// The page half of a Latte WebAssembly module.
//
// Latte's canvas runtime is Beans compiled to WebAssembly. It owns the
// controls, the layout, the state, the editing, the focus and the
// accessibility semantics. This file owns nothing of the sort: it is an
// adapter, and every function in it either hands the module something only a
// page can answer, or takes something the module drew and puts it on screen.
//
// ## The memory rule
//
// The module exports its own linear memory. Every `(pointer, length)` pair
// that crosses is an offset into *that* memory and is decoded against it here.
// Pointers never go the other way, and they are never passed on to another
// WebAssembly module: CanvasKit is its own module with its own memory, so an
// address from Latte means something entirely different inside it — and it
// usually means *something*, which is the worst way for a mistake like that to
// fail. Text reaching CanvasKit is decoded to a JavaScript string here first.
//
// ## The import list
//
// It is exactly the `extern "C"` declarations in `browser/bridge.b`, and
// `tests/wasm_abi.sh` diffs the built module's real import table against that
// file. A name added on one side and not the other fails the gate rather than
// failing at instantiation in somebody's browser.

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
        // Output arrives a write at a time, not a line at a time, so it is
        // buffered until a newline. A console.log per fragment would break one
        // println into several lines and make a golden comparison impossible.
        this.pending = { 1: "", 2: "" };
        this.clipboardText = "";
        this.semanticsHost = options.semanticsHost || null;
        this.editingHost = options.editingHost || null;
        this.renderer = options.renderer || null;
        this.exited = null;
        this.onFrame = options.onFrame || null;
        // Imports beyond the core list — the drawing half, when a page has
        // one. They are merged into `env` rather than given a module of their
        // own because wasm-ld puts every undefined symbol in `env` and there
        // is no way to ask it for a second.
        //
        // A function, not an object, and that is what makes the drawing
        // imports possible: they decode pointers against this module's memory,
        // and that memory does not exist until the module is instantiated. So
        // they are built from the runtime, once, at the moment they are needed.
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

    /// The bytes of a `(pointer, length)` pair, as a JavaScript string.
    ///
    /// A fresh view every time rather than one kept: the module grows its
    /// memory with `memory.grow`, and growing detaches every existing
    /// `ArrayBuffer` view. A cached `Uint8Array` would read as empty from the
    /// first allocation that crossed a page boundary — silently, because a
    /// detached view is zero length rather than an error.
    text(pointer, length) {
        if (!pointer || length <= 0) return "";
        return this.decoder.decode(new Uint8Array(this.memory.buffer, pointer, length));
    }

    /// Writes a JavaScript string into a caller-supplied buffer, and answers
    /// how many bytes it needed. The two-call shape: a null buffer asks the
    /// length, and a buffer that size takes the copy.
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
                // Fire and forget: the module cannot wait for a promise,
                // and the page's own clipboard is already updated above so
                // a paste inside the same document works either way.
                navigator.clipboard.writeText(text).catch(() => {});
                return 0;
            },

            latte_js_clipboard_read(pointer, capacity) {
                // The system clipboard is only readable from a promise, and
                // a WebAssembly call cannot wait for one. What is readable
                // synchronously is the last text this document copied, plus
                // whatever a paste event handed over — `noteClipboard` is
                // how the page supplies that.
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
        // Floating-point text. Part of the core rather than an option: a
        // program that puts a float into a string panics without it, and
        // "printing a number" is not a capability a page should have to opt
        // into.
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
        // Streaming instantiation where the server sent the right type, and a
        // buffered fallback where it did not — a file server that answers
        // application/octet-stream is common enough that refusing would make
        // this unusable locally.
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
        return runtime;
    }
}

export { CAPABILITY };
