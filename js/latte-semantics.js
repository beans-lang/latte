// The accessibility tree, as real DOM.
//
// A `<canvas>` is one element to a screen reader, whatever is drawn on it. So
// Latte publishes its semantics tree and this builds a matching element for
// each node: a real `<button>`, a real `<input>`, with the role, the name and
// the box the control actually occupies.
//
// **The elements are focusable and clickable, and that is the point.** A
// screen reader moves through them, reads them, and activates them; the
// activation comes back here and goes into the module as an accessibility
// action, which runs the same code a click runs. Nothing is simulated — there
// is one code path, and the DOM mirror is a way into it.
//
// They sit behind the canvas and are invisible: `clip-path` rather than
// `display: none`, because an element that is not rendered is not in the
// accessibility tree either.

/// Latte's roles, and the HTML that carries each one best.
const ELEMENTS = {
    button: "button",
    link: "a",
    checkbox: "input",
    radio: "input",
    switch: "button",
    slider: "input",
    textbox: "input",
    text: "span",
    group: "div",
    tab: "button",
    tablist: "div",
    table: "div",
    row: "div",
    cell: "div",
    progressbar: "div",
};

/// What a screen reader can ask a node to do. The numbers are
/// `stage.SemanticsAction`'s.
const ACTION = { ACTIVATE: 1, FOCUS: 2 };

export class SemanticsHost {
    constructor(parent, options = {}) {
        this.onAction = options.onAction || (() => {});
        this.root = document.createElement("div");
        this.root.setAttribute("role", "application");
        Object.assign(this.root.style, {
            position: "absolute",
            left: "0", top: "0", width: "100%", height: "100%",
            // Not hidden: a hidden element is not in the accessibility tree.
            // Zero opacity and no pointer events leave it readable by a screen
            // reader and invisible and untouchable to everyone else.
            opacity: "0",
            pointerEvents: "none",
            overflow: "hidden",
        });
        (parent || document.body).appendChild(this.root);
        this.nodes = new Map();
        this.seen = new Set();
        this.published = 0;
        // Set while this file is the one moving focus.
        //
        // Without it the tree feeds itself: publishing a node that Latte says
        // is focused calls `element.focus()`, the focus listener reports it
        // back as a focus *action*, the action changes the scene, the scene
        // publishes a new tree, and the page asks for a frame forever. It read
        // as "the page never goes idle" and the cause was three calls away.
        this.moving = false;
    }

    begin() {
        this.seen.clear();
    }

    node(item) {
        const key = String(item.id);
        this.seen.add(key);
        let element = this.nodes.get(key);
        const tag = ELEMENTS[item.role] || "div";
        if (!element || element.tagName.toLowerCase() !== tag) {
            if (element) element.remove();
            element = document.createElement(tag);
            element.style.position = "absolute";
            element.style.margin = "0";
            element.style.padding = "0";
            element.style.border = "0";
            element.style.background = "transparent";
            element.style.pointerEvents = "auto";
            if (tag === "input") {
                element.type = item.role === "checkbox" ? "checkbox"
                             : item.role === "radio" ? "radio"
                             : item.role === "slider" ? "range" : "text";
            }
            // Activation goes back into the module, which runs the same code
            // a click on the canvas runs. Two code paths for "press this
            // button" is how one of them ends up subtly different.
            element.addEventListener("click", (event) => {
                event.preventDefault();
                this.onAction(BigInt(key), ACTION.ACTIVATE);
            });
            element.addEventListener("focus", () => {
                if (this.moving) return;
                this.onAction(BigInt(key), ACTION.FOCUS);
            });
            this.root.appendChild(element);
            this.nodes.set(key, element);
        }
        element.style.left = `${item.x}px`;
        element.style.top = `${item.y}px`;
        element.style.width = `${Math.max(1, item.width)}px`;
        element.style.height = `${Math.max(1, item.height)}px`;
        if (element.getAttribute("role") !== item.role) element.setAttribute("role", item.role);
        // aria-label rather than text content: the text is drawn on the
        // canvas, and putting it in the DOM as well would have a screen reader
        // read the same words from two places when the two ever disagree.
        if (element.getAttribute("aria-label") !== item.label) {
            element.setAttribute("aria-label", item.label);
        }
        if (item.value) element.setAttribute("aria-valuetext", item.value);
        else element.removeAttribute("aria-valuetext");
        element.setAttribute("aria-disabled", item.enabled ? "false" : "true");
        // A node with no name that nothing can do anything with is decoration.
        // Left in the tree it would be a stop with nothing to announce, which
        // is how a canvas full of drawn shapes becomes a screen reader reading
        // "image, image, image".
        const silent = !item.label && !item.value &&
                       (item.role === "image" || item.role === "group");
        if (silent) element.setAttribute("aria-hidden", "true");
        else element.removeAttribute("aria-hidden");

        // Only what can take focus is given a tab stop. A label is in the tree
        // so a screen reader can read it, and tabbing onto one would be a stop
        // the canvas itself does not have. A hidden node with a tab stop is
        // worse still: focus lands somewhere nothing is announced.
        const focusable = item.enabled && !silent && item.role !== "text" &&
                          item.role !== "group" && item.role !== "progressbar";
        element.tabIndex = focusable ? 0 : -1;
        if (item.focused && focusable && document.activeElement !== element) {
            this.moving = true;
            try { element.focus({ preventScroll: true }); } finally { this.moving = false; }
        }
    }

    end() {
        // Anything the tree no longer names is gone. Leaving it would have a
        // screen reader announce a control that is not on screen any more,
        // which is the accessibility version of a memory leak.
        for (const [key, element] of this.nodes) {
            if (!this.seen.has(key)) { element.remove(); this.nodes.delete(key); }
        }
        this.published++;
    }

    /// What a gate reads: the elements now standing, and how many trees have
    /// been published.
    count() { return this.nodes.size; }

    close() {
        for (const element of this.nodes.values()) element.remove();
        this.nodes.clear();
        this.root.remove();
    }
}

export { ACTION };
