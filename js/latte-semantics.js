// Latte's semantics tree as real DOM, one focusable element per node: a screen
// reader activates them and the action runs the same code a click runs.

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
            // Not hidden — a hidden element is not in the accessibility tree.
            // Zero opacity and no pointer events leave it readable, not seen.
            opacity: "0",
            pointerEvents: "none",
            overflow: "hidden",
        });
        (parent || document.body).appendChild(this.root);
        this.nodes = new Map();
        this.seen = new Set();
        this.published = 0;
        // Set while this file is the one moving focus: without it,
        // `element.focus()` comes back as a focus action and the page loops.
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
            // Activation goes back into the module and runs the same code a
            // click runs: two paths to one button is how they diverge.
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
        // aria-label rather than text content: the words are drawn on the
        // canvas, and two copies is two things that can disagree.
        if (element.getAttribute("aria-label") !== item.label) {
            element.setAttribute("aria-label", item.label);
        }
        if (item.value) element.setAttribute("aria-valuetext", item.value);
        else element.removeAttribute("aria-valuetext");
        element.setAttribute("aria-disabled", item.enabled ? "false" : "true");
        // A node with no name and nothing to do is decoration: left in, it is
        // a stop with nothing to announce.
        const silent = !item.label && !item.value &&
                       (item.role === "image" || item.role === "group");
        if (silent) element.setAttribute("aria-hidden", "true");
        else element.removeAttribute("aria-hidden");

        // Only what can take focus gets a tab stop. A label is in the tree to
        // be read; a tab stop on one is a stop the canvas does not have.
        const focusable = item.enabled && !silent && item.role !== "text" &&
                          item.role !== "group" && item.role !== "progressbar";
        element.tabIndex = focusable ? 0 : -1;
        if (item.focused && focusable && document.activeElement !== element) {
            this.moving = true;
            try { element.focus({ preventScroll: true }); } finally { this.moving = false; }
        }
    }

    end() {
        // Anything the tree no longer names is gone: leaving it announces a
        // control that is not on screen any more.
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
