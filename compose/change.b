// One edit, as a value.
package compose

import latte.input

/// A single operation on the mounted tree.
///
/// Changes are a list, not a callback, and that is the design decision this
/// type exists to make possible. A list can be printed, compared against a
/// golden file, and checked for properties no single-step API could be —
/// that a render which moved one row emits one `move` and not five `set`s,
/// that nothing is created and immediately removed, that the order is
/// applicable. `tests/diff.b` does exactly that, with no platform anywhere
/// near it.
///
/// `path` names an element by the child indices that reach it from the root,
/// so `[0, 2]` is the third child of the first child. For `create`, `remove`
/// and `move` it names the **parent**, and `index` says which child; for
/// everything else it names the element itself.
pub class Change {
    pub kind: ChangeKind = ChangeKind.set
    steps: List<int> = []

    /// The child position a structural change acts on.
    pub index: int = -1
    /// Where a `move` is going.
    pub target: int = -1
    /// The value a `set` writes.
    pub attribute: Attribute = Attribute {}
    /// The event a `bind` or `unbind` concerns.
    pub event: input.EventKind = input.EventKind.unknown
    /// What a `create` should build.
    pub element: Option<Element> = none

    /// Whether this change acts on the surface itself rather than on an
    /// element.
    ///
    /// There is exactly one place the two can be confused: the element tree
    /// has a root, and that root's *parent* is not an element at all — it is
    /// the container the mount was given to fill. A first render, and a render
    /// whose root changed kind, act there. Every other change names an element.
    /// Saying which is which explicitly beats a rule about what an empty path
    /// means in each of six cases, and goldens print `surface` rather than
    /// `root` so a reader can see it too.
    pub at_surface: bool = false

    pub fn init(kind: ChangeKind, steps: List<int>) {
        self.kind = kind
        // Copied, not moved: a parameter is a borrowed binding, and the
        // differ reuses one mutable path for the whole walk. This copy is the
        // one that outlives it.
        for step: int in steps {
            self.steps.push(step)
        }
    }

    pub fn depth() -> int {
        return self.steps.len()
    }

    pub fn step(index: int) -> int {
        return self.steps[index]
    }

    /// The path as goldens print it: `root`, `root.0`, `root.0.2`.
    pub fn path_text() -> string {
        var out: string = "root"
        if self.at_surface { out = "surface" }
        for step: int in self.steps {
            out = "{out}.{step}"
        }
        return out
    }

    /// The line a golden file carries.
    pub fn show() -> string {
        match self.kind {
            create => {
                var what: string = "?"
                match self.element {
                    some(element) => { what = describe(element) }
                    none => {}
                }
                return "create {self.path_text()}[{self.index}] {what}"
            }
            remove => { return "remove {self.path_text()}[{self.index}]" }
            relocate => { return "move {self.path_text()}[{self.index}] -> [{self.target}]" }
            set => { return "set {self.path_text()} {self.attribute.show()}" }
            bind => { return "bind {self.path_text()} {self.event.name()}" }
            unbind => { return "unbind {self.path_text()} {self.event.name()}" }
        }
    }
}

// A created element as one line: its tag, its key if it has one, and how many
// children come with it. The subtree itself is not printed — a golden that
// carried every attribute of every descendant would change whenever anything
// anywhere did, and stop being read.
fn describe(element: Element) -> string {
    var out: string = "<{element.tag}>"
    if element.key != "" {
        out = "{out} key={element.key}"
    }
    if element.count() > 0 {
        out = "{out} +{element.count()}"
    }
    return out
}
