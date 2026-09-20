// The hidden editable element typing really arrives at, placed under the caret
// Beans drew. Why it is contenteditable, and why it moves: docs/notes.md.

export class EditingHost {
    constructor(parent, options = {}) {
        this.parent = parent || document.body;
        // The canvas the coordinates are relative to, when it is not the
        // parent itself.
        this.canvas = options.canvas || null;
        this.onText = options.onText || (() => {});
        this.listeners = [];
        this.element = document.createElement("div");
        this.element.contentEditable = "true";
        this.element.setAttribute("autocapitalize", "off");
        this.element.setAttribute("autocorrect", "off");
        this.element.setAttribute("spellcheck", "false");
        this.element.setAttribute("aria-hidden", "true");
        Object.assign(this.element.style, {
            position: "absolute",
            // Not `display: none`: an element that is not rendered cannot be
            // focused, and one that is not focused never gets a keystroke.
            opacity: "0",
            padding: "0",
            margin: "0",
            border: "0",
            outline: "none",
            background: "transparent",
            color: "transparent",
            caretColor: "transparent",
            width: "1px",
            height: "1em",
            left: "0px",
            top: "0px",
            zIndex: "-1",
            whiteSpace: "pre",
            overflow: "hidden",
        });
        this.parent.appendChild(this.element);
        this.active = false;
    }

    attach(handlers) {
        const on = (type, handler) => {
            this.element.addEventListener(type, handler);
            this.listeners.push(() => this.element.removeEventListener(type, handler));
        };
        on("beforeinput", (event) => {
            handlers.onBeforeInput(event);
            // The element's content is never the truth — Beans holds the text.
            // A browser insert would leave a second copy that grows and drifts.
            event.preventDefault();
        });
        on("compositionstart", (event) => handlers.onCompositionStart(event));
        on("compositionupdate", (event) => handlers.onCompositionUpdate(event));
        on("compositionend", (event) => {
            handlers.onCompositionEnd(event);
            // The committed text is Beans' now. Cleared here, not in
            // `beforeinput`: emptying mid-composition cancels it in Safari.
            this.element.textContent = "";
        });
    }

    /// Where the caret is and what is being edited. `active` false ends the
    /// session: blurring closes a software keyboard and an input method.
    setState(state) {
        if (!state.active) {
            if (this.active) {
                this.element.blur();
                this.element.textContent = "";
                this.active = false;
            }
            return;
        }
        // Scene coordinates, offset by where the canvas sits in this element's
        // parent — zero when it fills its container, not when it is a panel.
        const origin = this.originOf();
        this.element.style.left = `${Math.round(origin.x + state.x)}px`;
        this.element.style.top = `${Math.round(origin.y + state.y)}px`;
        this.element.style.height = `${Math.max(1, Math.round(state.height))}px`;
        this.active = true;
        // Every update, not only the first. The accessibility tree focuses its
        // own proxy element for the same control, so a session that focused
        // once loses the keyboard on the next event and typing goes nowhere.
        if (document.activeElement !== this.element) {
            this.element.focus({ preventScroll: true });
        }
    }

    /// Where the canvas is inside the element this one is positioned against.
    originOf() {
        if (!this.canvas || !this.parent) return { x: 0, y: 0 };
        const canvas = this.canvas.getBoundingClientRect();
        const parent = this.parent.getBoundingClientRect();
        return { x: canvas.left - parent.left, y: canvas.top - parent.top };
    }

    close() {
        for (const off of this.listeners) off();
        this.listeners = [];
        this.element.remove();
    }
}
