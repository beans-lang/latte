// Where typing really happens.
//
// A `<canvas>` cannot receive text. Every browser routes typing, input methods,
// autocorrect and dictation through an editable element, so Latte has one:
// invisible, one line tall, positioned under the caret Beans drew.
//
// **Position is not cosmetic.** An input method puts its candidate window
// under the editing element, so an element parked at the origin puts a
// Japanese candidate list in the corner of the page while the text appears in
// the middle. Moving it is the whole reason `platform.Host.text_input` carries
// a rectangle.
//
// It is `contenteditable` rather than a `<textarea>` for one reason: Safari
// fires `compositionupdate` on a contenteditable and not reliably on a hidden
// textarea, and an input method that reports nothing until it commits cannot
// show a composition underline.

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
            // Not `display: none` and not `visibility: hidden`: an element
            // that is not rendered cannot be focused, and one that cannot be
            // focused never receives a keystroke. One transparent pixel of
            // real layout is what an input method needs to aim at.
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
            // The element's own content is never the truth — Beans holds the
            // text. Letting the browser insert into it would leave a second
            // copy that drifts, and would grow without bound over a session.
            event.preventDefault();
        });
        on("compositionstart", (event) => handlers.onCompositionStart(event));
        on("compositionupdate", (event) => handlers.onCompositionUpdate(event));
        on("compositionend", (event) => {
            handlers.onCompositionEnd(event);
            // The committed text is Beans' now. Clearing here rather than in
            // `beforeinput` is deliberate: an input method reads the element's
            // content while it composes, and emptying it mid-session cancels
            // the composition in Safari.
            this.element.textContent = "";
        });
    }

    /// Where the caret is, and what is being edited.
    ///
    /// Called from the module whenever the editing state changes. `active`
    /// false ends the session: the element is blurred, so the browser stops
    /// showing a software keyboard and an input method closes its window.
    setState(state) {
        if (!state.active) {
            if (this.active) {
                this.element.blur();
                this.element.textContent = "";
                this.active = false;
            }
            return;
        }
        // The coordinates are the scene's, and the scene is the canvas — so
        // they are offset by wherever the canvas sits inside this element's
        // parent. In the common case the canvas fills its container and the
        // offset is zero; a Latte panel beside other HTML is where it is not,
        // and an input method's candidate window would otherwise appear that
        // far away from the text.
        const origin = this.originOf();
        this.element.style.left = `${Math.round(origin.x + state.x)}px`;
        this.element.style.top = `${Math.round(origin.y + state.y)}px`;
        this.element.style.height = `${Math.max(1, Math.round(state.height))}px`;
        if (!this.active) {
            this.active = true;
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
