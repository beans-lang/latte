// Browser events, forwarded to Latte.
//
// Everything here is translation. Which control a click lands on, what a key
// does, where the caret goes, whether a drag is a drag — all of that is Beans'
// and is decided inside the module. This file turns a DOM event into the four
// numbers the module's pointer entry takes, and gets out of the way.
//
// ## The one real decision: not sending the same thing twice
//
// A browser reports typing through four overlapping mechanisms, and a naive
// forwarder sends one keystroke as four events:
//
//   keydown       — every key, including the ones that type nothing
//   beforeinput   — what is *about* to be inserted, including a paste and an
//                   input method's commit
//   input         — what was inserted
//   composition*  — an input method's session, wrapping several of the above
//
// Latte takes typing through one road: text arrives as `text_input`, and keys
// that move or delete arrive as `key_down`. So the rule here is:
//
//   * A key that produces text is **not** forwarded as a key. `beforeinput`
//     carries it, with its range, and that is the one that goes.
//   * A key that produces no text — arrows, Tab, Escape, Backspace, a
//     shortcut — is forwarded as a key and `beforeinput` for it is ignored.
//   * While an input method is composing, `beforeinput` is ignored entirely
//     and the composition events carry the text. Sending both is how a
//     Japanese sentence ends up doubled.

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

/// `platform.KEY_*`. Everything that types nothing and means the same on every
/// keyboard. A key that is not here is `character`, and its text is what the
/// browser said it produced.
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

/// Whether a key event is one Latte should hear about as a *key*.
///
/// A printable character with no command or control held is text, and
/// `beforeinput` is what carries it. Everything else is a key: the named ones
/// above, and any character pressed with a shortcut modifier — Cmd-A is a
/// shortcut, not the letter A.
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

/// Attaches every listener one canvas needs, and answers the function that
/// takes them all off again.
///
/// The returned function is not optional. A page that mounted and unmounted
/// without calling it would leave a pointermove listener per mount on an
/// element that is still in the document, and the handlers hold the module.
export function attachInput(element, handlers) {
    const listeners = [];
    const on = (target, type, handler, options) => {
        target.addEventListener(type, handler, options);
        listeners.push(() => target.removeEventListener(type, handler, options));
    };

    // A canvas takes the keyboard only if something makes it focusable, and a
    // focus ring around the whole canvas would be wrong — Latte draws its own,
    // around the control that has focus inside it.
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
        // Capture, so a drag that leaves the canvas keeps arriving. Without it
        // a slider dragged past its own edge stops moving and never hears the
        // release, so it stays stuck down.
        element.setPointerCapture?.(event.pointerId);
        captured = event.pointerId;
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
            element.releasePointerCapture?.(captured);
            captured = null;
        }
        const [x, y] = pointAt(event);
        handlers.pointer(EVENT.POINTER_UP, x, y,
                         BUTTON[event.button] || 1, event.detail || 1,
                         modifiersOf(event));
    };
    on(element, "pointerup", release);
    // A cancel is a release that the browser decided for us — a system gesture
    // took over, or the element went away mid-drag. Latte has to hear it, or
    // the control stays pressed forever.
    on(element, "pointercancel", release);

    on(element, "wheel", (event) => {
        const [x, y] = pointAt(event);
        // deltaMode 1 is lines and 2 is pages. Firefox reports lines for a
        // mouse wheel, so a page that treated every delta as pixels scrolls
        // about a fortieth as far there as it does in Chrome.
        const lines = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 800 : 1;
        handlers.scroll(x, y, -event.deltaX * lines, -event.deltaY * lines);
        event.preventDefault();
    }, { passive: false });

    on(element, "keydown", (event) => {
        if (composing) return;
        const code = keyCodeOf(event);
        if (code === null) return;
        const text = event.key.length === 1 ? event.key : "";
        handlers.key(EVENT.KEY_DOWN, code, text, modifiersOf(event));
        // Tab would move focus out of the canvas and arrow keys would scroll
        // the page. Latte has its own focus order and its own scrolling, so
        // the browser's are refused for the keys it handles.
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

    // The editing element is where text really arrives. It is a hidden
    // contenteditable placed under the caret, so an input method's candidate
    // window appears in the right place; `latte-editing.js` owns it.
    if (handlers.editing) {
        handlers.editing.attach({
            onBeforeInput(event) {
                if (composing) return;
                const text = event.data ?? "";
                if (event.inputType === "insertFromPaste") {
                    handlers.clipboard?.(text);
                }
                if (!text) return;
                handlers.key(EVENT.TEXT_INPUT, 0, text, 0);
            },
            onCompositionStart() { composing = true; },
            onCompositionUpdate(event) {
                handlers.key(EVENT.COMPOSITION_UPDATE, 0, event.data ?? "", 0);
            },
            onCompositionEnd(event) {
                composing = false;
                handlers.key(EVENT.TEXT_INPUT, 0, event.data ?? "", 0);
            },
        });
    }

    on(element, "paste", (event) => {
        const text = event.clipboardData?.getData("text/plain") ?? "";
        handlers.clipboard?.(text);
    });
    on(element, "copy", (event) => {
        // Latte already wrote its selection to `clipboardText`; this is the
        // page's own copy shortcut reaching the element, and letting the
        // browser copy an empty canvas selection over it would clear it.
        event.preventDefault();
    });

    // Focus leaving the page is not the same as focus leaving a control, and
    // Latte has to know: a text field that keeps its caret blinking while the
    // window is behind another one looks broken.
    on(window, "blur", () => handlers.key(EVENT.COMPOSITION_CANCEL, 0, "", 0));
    on(document, "visibilitychange", () => {
        if (document.hidden) handlers.key(EVENT.COMPOSITION_CANCEL, 0, "", 0);
    });

    return () => { for (const off of listeners) off(); };
}
