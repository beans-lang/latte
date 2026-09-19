// What a component tag may ask of the run its root sits in.
package compose

import std.reflect

/// The handle `Builder.child`, `show` and `embed` answer, so the parent can
/// write what the child's root asks of the run around it.
///
/// `<Tile margin_left={8} grow={1} />` is a component tag with two placements.
/// They apply after the child has rendered, so the parent's word is the last.
pub class Placement {
    owner: Builder
    subject: Option<Element> = none
    kind: Option<reflect.Type> = none

    pub fn init(owner: Builder, subject: Option<Element>, kind: Option<reflect.Type>) {
        self.owner = owner
        self.subject = subject
        self.kind = kind
    }

    /// A placement with nothing to place: the child was refused, and the
    /// builder already holds the fault that says why.
    pub static fn nowhere(owner: Builder) -> Placement {
        return new Placement(owner, none, none)
    }

    /// A number the child's root asks of its run: `margin` and its edges,
    /// `grow`, `shrink`, `basis`, `width`, `height`, `x` or `y`.
    pub fn number(name: string, value: f64) -> Placement {
        match self.subject {
            none => {}
            some(root) => { self.owner.place_number(root, self.kind, name, value) }
        }
        return self
    }

    /// A word the child's root asks of its run — `align`, and nothing else.
    pub fn word(name: string, value: string) -> Placement {
        match self.subject {
            none => {}
            some(root) => { self.owner.place_word(root, self.kind, name, value) }
        }
        return self
    }
}
