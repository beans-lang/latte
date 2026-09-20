// Browser events, forwarded to Latte. Everything here is translation; what a
// click or a key means is Beans'. Not sending typing twice: docs/notes.md.

/// Latte's event kinds. The numbers are `platform.EV_*`, which is the one
/// place they are declared; a copy that drifts sends a click as a key.
export const EVENT = {
    POINTER_DOWN: 5,
    POINTER_UP: 6,
    POINTER_MOVE: 7,
    KEY_DOWN: 8,
    KEY_UP: 9,
    TEXT_INPUT: 40,
    COMPOSITION_UPDATE: 41,
    COMPOSITION_CANCEL: 42,
};

/// `platform.MOD_*`.
export const MOD = { SHIFT: 1, CONTROL: 2, ALT: 4, COMMAND: 8 };

/// `platform.BTN_*`.
const BUTTON = { 0: 1, 2: 2, 1: 3 };

/// `platform.KEY_*`: everything that types nothing and means the same on every
/// keyboard. A key that is not here is `character`, with the text it produced.
const KEYS = {
    Escape: 2, Tab: 3, Enter: 4, NumpadEnter: 4, " ": 5, Backspace: 6, Delete: 7,
    ArrowLeft: 8, ArrowRight: 9, ArrowUp: 10, ArrowDown: 11,
    Home: 12, End: 13, PageUp: 14, PageDown: 15,
    F1: 16, F2: 17, F3: 18, F4: 19, F5: 20, F6: 21,
    F7: 22, F8: 23, F9: 24, F10: 25, F11: 26, F12: 27,
};
const KEY_CHARACTER = 1;

export function modifiersOf(event) {
    let bits = 0;
    if (event.shiftKey) bits |= MOD.SHIFT;
    if (event.ctrlKey) bits |= MOD.CONTROL;
    if (event.altKey) bits |= MOD.ALT;
    if (event.metaKey) bits |= MOD.COMMAND;
    return bits;
}

/// Whether a key event is one Latte hears as a *key*. A bare printable is
/// text and rides `beforeinput`; Cmd-A is a shortcut, not the letter A.
function keyCodeOf(event) {
    if (KEYS[event.key] !== undefined && event.key !== " ") return KEYS[event.key];
    if (event.key === " ") return KEYS[" "];
    if (event.key.length === 1) {
        return (event.metaKey || event.ctrlKey) ? KEY_CHARACTER : null;
    }
    // A dead key, a modifier on its own, or something this table does not
    // know. Not forwarded: it would arrive as `unknown` and mean nothing.
    return null;
}

/// Attaches every listener a canvas needs and answers the one that removes
/// them. Not optional: the handlers hold the module, one set per mount.
export function attachInput(element, handlers) {
    const listeners = [];
    const on = (target, type, handler, options) => {
        target.addEventListener(type, handler, options);
        listeners.push(() => target.removeEventListener(type, handler, options));
    };

    // A canvas takes the keyboard only once something makes it focusable, and
    // the browser's ring is off: Latte draws its own, around the control.
    if (!element.hasAttribute("tabindex")) element.tabIndex = 0;
    element.style.outline = "none";
    element.style.touchAction = "none";

    const pointAt = (event) => {
        const box = element.getBoundingClientRect();
        return [event.clientX - box.left, event.clientY - box.top];
    };

    let composing = false;
    let captured = null;

    on(element, "pointerdown", (event) => {
        // Capture, so a drag that leaves the canvas keeps arriving. In a try:
        // Firefox throws for an unknown pointer id, which would lose the click.
        try {
            element.setPointerCapture?.(event.pointerId);
            captured = event.pointerId;
        } catch {
            captured = null;
        }
        element.focus({ preventScroll: true });
        const [x, y] = pointAt(event);
        handlers.pointer(EVENT.POINTER_DOWN, x, y,
                         BUTTON[event.button] || 1, event.detail || 1,
                         modifiersOf(event));
        event.preventDefault();
    });

    on(element, "pointermove", (event) => {
        const [x, y] = pointAt(event);
        handlers.pointer(EVENT.POINTER_MOVE, x, y,
                         BUTTON[event.button] || 1, 0, modifiersOf(event));
    });

    const release = (event) => {
        if (captured !== null) {
            try { element.releasePointerCapture?.(captured); } catch { /* already gone */ }
            captured = null;
        }
        const [x, y] = pointAt(event);
        handlers.pointer(EVENT.POINTER_UP, x, y,
                         BUTTON[event.button] || 1, event.detail || 1,
                         modifiersOf(event));
    };
    on(element, "pointerup", release);
    // A cancel is a release the browser decided for us. Latte has to hear it,
    // or the control stays pressed forever.
    on(element, "pointercancel", release);

    on(element, "wheel", (event) => {
        const [x, y] = pointAt(event);
        // deltaMode 1 is lines and 2 is pages. Firefox reports lines for a
        // mouse wheel, so pixels-for-everything scrolls a fortieth as far.
        const lines = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 800 : 1;
        // The sign goes through unchanged: `deltaY` and Latte's scroll offset
        // both mean further down the content. Negating scrolled backwards.
        handlers.scroll(x, y, event.deltaX * lines, event.deltaY * lines);
        event.preventDefault();
    }, { passive: false });

    on(element, "keydown", (event) => {
        if (composing) return;
        const code = keyCodeOf(event);
        if (code === null) return;
        const text = event.key.length === 1 ? event.key : "";
        handlers.key(EVENT.KEY_DOWN, code, text, modifiersOf(event));
        // Tab would move focus out and the arrows would scroll the page.
        // Latte has its own focus order and scrolling, so both are refused.
        if (code !== KEY_CHARACTER || event.metaKey || event.ctrlKey) {
            if (event.key !== "F5" && event.key !== "F12") event.preventDefault();
        }
    });

    on(element, "keyup", (event) => {
        if (composing) return;
        const code = keyCodeOf(event);
        if (code === null) return;
        handlers.key(EVENT.KEY_UP, code, "", modifiersOf(event));
    });

    // Text arrives at the editing element `latte-editing.js` owns and goes
    // through the *text* entry, never the key one. Why: docs/notes.md.
    if (handlers.editing) {
        handlers.editing.attach({
            onBeforeInput(event) {
                if (composing) return;
                const text = event.data ?? "";
                if (event.inputType === "insertFromPaste") {
                    handlers.clipboard?.(text);
                }
                if (!text) return;
                handlers.text(EVENT.TEXT_INPUT, text, -1, -1);
            },
            onCompositionStart() { composing = true; },
            onCompositionUpdate(event) {
                handlers.text(EVENT.COMPOSITION_UPDATE, event.data ?? "", -1, -1);
            },
            onCompositionEnd(event) {
                composing = false;
                handlers.text(EVENT.TEXT_INPUT, event.data ?? "", -1, -1);
            },
        });
    }

    on(element, "paste", (event) => {
        const text = event.clipboardData?.getData("text/plain") ?? "";
        handlers.clipboard?.(text);
    });
    on(element, "copy", (event) => {
        // Latte already wrote its selection to `clipboardText`; letting the
        // browser copy the element's empty selection over it would clear it.
        event.preventDefault();
    });

    // Focus leaving the page is not focus leaving a control, and Latte has to
    // know: a caret still blinking behind another window looks broken.
    on(window, "blur", () => handlers.text(EVENT.COMPOSITION_CANCEL, "", -1, -1));
    on(document, "visibilitychange", () => {
        if (document.hidden) handlers.text(EVENT.COMPOSITION_CANCEL, "", -1, -1);
    });

    return () => { for (const off of listeners) off(); };
}
