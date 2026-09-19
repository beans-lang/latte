// Putting a Latte module on a page.
//
// Three things have to meet: the Beans module (the controls, the layout, the
// state), CanvasKit (the drawing), and the DOM (the events, the accessibility
// tree, the editing element). This is where they meet, and it is the only file
// that knows about all three.
//
// It decides nothing about the interface. Every event is forwarded as it
// arrives and every answer comes back out of the module; there is no control
// behaviour here, no hit testing, no focus policy. Those belong to Beans, and
// a copy of any of them here would be a second implementation that the Beans
// gates could not see.

import { LatteRuntime } from "./latte-runtime.js";
import { CanvasKitSurface, canvasKitImports } from "./latte-canvaskit.js";
import { SemanticsHost } from "./latte-semantics.js";
import { EditingHost } from "./latte-editing.js";
import { attachInput, EVENT } from "./latte-input.js";

/// One mounted Latte application.
export class LattePage {
    constructor(options) {
        this.element = options.element;
        this.runtime = null;
        this.surface = null;
        this.semantics = null;
        this.editing = null;
        this.detachInput = null;
        this.resizeObserver = null;
        this.mounted = false;
        this.onError = options.onError || ((message) => console.error(message));
        this.stdout = options.stdout || ((line) => console.log(line));
    }

    /// The module's last failure, as a string. Every export answers an
    /// integer, so this is how -1 gets a reason.
    lastError() {
        const exports = this.runtime.exports;
        if (!exports.latte_last_error) return "";
        const needed = exports.latte_last_error(0, 0);
        if (needed <= 0) return "";
        const scratch = exports.latte_scratch_take(needed);
        try {
            exports.latte_last_error(scratch, needed);
            return this.runtime.text(scratch, needed);
        } finally {
            exports.latte_scratch_drop(scratch);
        }
    }

    /// Calls one export and turns -1 into the reason behind it.
    call(name, ...args) {
        const answer = this.runtime.exports[name](...args);
        if (answer < 0) {
            const reason = this.lastError();
            this.onError(reason || `${name} failed`);
        }
        return answer;
    }

    /// The size the canvas should be, in logical points, and the device pixel
    /// ratio to draw it at.
    measure() {
        const box = this.element.getBoundingClientRect();
        return {
            width: Math.max(1, Math.round(box.width)),
            height: Math.max(1, Math.round(box.height)),
            scale: window.devicePixelRatio || 1,
        };
    }

    static async load(options) {
        const page = new LattePage(options);
        const canvasKit = options.canvasKit;
        const element = options.element;

        page.surface = new CanvasKitSurface(canvasKit, element, {
            software: options.software === true,
        });
        page.semantics = options.accessibility === false
            ? null
            : new SemanticsHost(options.semanticsRoot || element.parentElement, {
                onAction: (handle, action) => page.call("latte_semantics_action", handle, action),
              });
        page.editing = options.editing === false
            ? null
            : new EditingHost(options.editingRoot || element.parentElement, {
                onText: (kind, text, anchor, caret) =>
                    page.withText(text, (pointer, length) =>
                        page.call("latte_text_input", kind, pointer, length, anchor, caret)),
              });

        // The drawing imports need the module's memory, which does not exist
        // until it is instantiated — so they are built from the runtime, by
        // the runtime, at the moment it wires its import object up.
        page.runtime = await LatteRuntime.load(options.module, {
            stdout: page.stdout,
            stderr: (line) => page.onError(line),
            renderer: page.surface,
            semanticsHost: page.semantics,
            editingHost: page.editing,
            imports: (runtime) => canvasKitImports(runtime, page.surface),
        });
        // A frame the module asked for lands here and goes straight back in.
        page.runtime.onFrame = null;

        // The fonts, before anything is mounted. CanvasKit has none of its
        // own, so a page that mounted first would shape its first frame with
        // nothing and lay every control out around empty text. `mount()` waits
        // for them.
        if (options.fonts && options.fonts.length) {
            page.surface.useFont(options.fonts.join(" "));
        }
        return page;
    }

    /// Writes a string into the module's scratch buffer and hands the callback
    /// its (pointer, length), then gives the buffer back.
    withText(text, body) {
        const bytes = new TextEncoder().encode(text);
        if (bytes.length === 0) return body(0, 0);
        const pointer = this.runtime.exports.latte_scratch_take(bytes.length);
        try {
            new Uint8Array(this.runtime.memory.buffer, pointer, bytes.length).set(bytes);
            return body(pointer, bytes.length);
        } finally {
            this.runtime.exports.latte_scratch_drop(pointer);
        }
    }

    /// Waits for the fonts to arrive, or answers why they did not.
    ///
    /// A caller that skips this gets a first frame with no text in it and a
    /// layout measured around nothing. `mount()` is async for that reason
    /// alone.
    async fontsReady(timeoutMs = 10000) {
        const until = Date.now() + timeoutMs;
        while (this.surface.fontState === 1 && Date.now() < until) {
            await new Promise((done) => setTimeout(done, 10));
        }
        if (this.surface.fontState === 2) return true;
        if (this.surface.fontState === 0) return true;   // none were asked for
        throw new Error(this.surface.lastError || "the fonts did not load");
    }

    /// Mounts the module's root component and starts following the element's
    /// size, the display's scale and the page's visibility.
    async mount() {
        if (this.mounted) return;
        await this.fontsReady();
        const size = this.measure();
        this.call("latte_boot");
        if (this.call("latte_mount", size.width, size.height, size.scale) < 0) return;
        this.mounted = true;

        this.detachInput = attachInput(this.element, {
            pointer: (kind, x, y, button, clicks, modifiers) =>
                this.call("latte_pointer", kind, x, y, button, clicks, modifiers),
            key: (kind, code, text, modifiers) =>
                this.withText(text, (pointer, length) =>
                    this.call("latte_key", kind, code, pointer, length, modifiers)),
            scroll: (x, y, dx, dy) => this.call("latte_scroll", x, y, dx, dy),
            clipboard: (text) => this.runtime.noteClipboard(text),
            editing: this.editing,
        });

        // The element's own size, not the window's: a Latte canvas can be one
        // panel on a page, and a window resize is not the only way its box
        // changes.
        if (typeof ResizeObserver === "function") {
            this.resizeObserver = new ResizeObserver(() => this.resized());
            this.resizeObserver.observe(this.element);
        } else {
            this.onResize = () => this.resized();
            window.addEventListener("resize", this.onResize);
        }

        // Browser zoom changes devicePixelRatio and raises no resize event of
        // its own. A media query at the current ratio does fire, and it is
        // re-armed each time because the ratio it watches has moved.
        this.watchScale();
    }

    watchScale() {
        if (typeof matchMedia !== "function") return;
        const ratio = window.devicePixelRatio || 1;
        this.scaleWatch = matchMedia(`(resolution: ${ratio}dppx)`);
        const onChange = () => { this.resized(); this.watchScale(); };
        // `addEventListener` on a MediaQueryList is the modern spelling and
        // `addListener` is what older WebKit has; both are tried because the
        // gate runs on both.
        if (this.scaleWatch.addEventListener) {
            this.scaleWatch.addEventListener("change", onChange, { once: true });
        } else if (this.scaleWatch.addListener) {
            this.scaleWatch.addListener(onChange);
        }
    }

    resized() {
        if (!this.mounted) return;
        const size = this.measure();
        this.call("latte_resize", size.width, size.height, size.scale);
    }

    /// Tells the page the GPU context went away. The next frame makes a new
    /// surface — a software one if WebGL still refuses — and repaints
    /// everything, because a new surface holds none of the old pixels.
    contextLost() {
        this.surface.noteContextLost();
        this.call("latte_resize", ...Object.values(this.measure()));
    }

    /// Everything goes: the input listeners, the accessibility elements, the
    /// editing element, the scene, and every Skia object the module's handles
    /// named. `surface.resourceCount()` is zero afterwards, which is what the
    /// teardown gate asserts.
    unmount() {
        if (!this.mounted) return;
        this.mounted = false;
        if (this.detachInput) { this.detachInput(); this.detachInput = null; }
        if (this.resizeObserver) { this.resizeObserver.disconnect(); this.resizeObserver = null; }
        if (this.onResize) { window.removeEventListener("resize", this.onResize); this.onResize = null; }
        this.call("latte_unmount");
        if (this.semantics) this.semantics.close();
        if (this.editing) this.editing.close();
        this.surface.close();
    }
}

export { EVENT };
