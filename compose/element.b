// What a component said it wants.
package compose

import latte.platform
import latte.controls
import latte.layout
import latte.input
import latte.visual

/// One described widget — not a widget.
///
/// A render does not touch the platform. It produces a tree of these, which is
/// a plain Beans value the differ can compare against the last one. Only the
/// difference between the two reaches a native control, so a render that
/// changed one label's text costs one `ctd_set_text` and not a rebuilt window.
///
/// That indirection buys three things worth the type:
///
/// - **Renders are testable with no platform.** A whole application's render
///   output is a value you can print, and latte's differ goldens run on
///   Linux with no display.
/// - **The tree can be described out of order.** Markup reads top to bottom;
///   the platform wants parents created before children and siblings in final
///   order. The applier sorts that out once.
/// - **Nothing is destroyed that did not change.** A native control holds
///   focus, a selection, an input-method session and scroll position. Rebuilding
///   one because its sibling changed loses all of it, visibly.
pub class Element {
    pub kind: controls.WidgetKind = controls.WidgetKind.container

    /// What the markup called this, kept for goldens and error messages. Never
    /// used for matching — that is `key` and `kind`.
    pub tag: string = ""

    /// Identity among siblings, across renders.
    ///
    /// An element with a key keeps its control when the list around it is
    /// reordered, inserted into or filtered. An element without one is matched
    /// by position, which is right for a fixed layout and wrong for a list —
    /// remove the first of five unkeyed rows and every row after it is told it
    /// is now the row below, so four controls are rewritten where one should
    /// have been removed.
    pub key: string = ""

    /// How this element's children are arranged, for a container. `none` for a
    /// leaf, and `none` on a container means its children are placed by
    /// whatever contains it.
    pub arranger: Option<layout.Layout> = none

    /// What this element asks of the run it sits in.
    pub spec: layout.LayoutSpec = layout.LayoutSpec {}

    /// What this element still needs of whatever contains it, when its own
    /// render did not contain it: "place", "flex", or "" once that is settled.
    ///
    /// A component renders into a builder of its own, so its root element has
    /// no parent at the moment `x` or `grow` is written on it. The requirement
    /// is carried here and answered by `Builder.embed`, where the container it
    /// actually landed in is known.
    pub pending: string = ""

    /// The attribute that asked, so the refusal names what the author wrote.
    pub pending_name: string = ""

    /// Whether `flex` was written, and whether `grow`, `shrink` or `basis`
    /// was: the two spell the same fields, so both on one element is refused.
    pub flexed: bool = false
    pub tuned: bool = false

    /// The control this element became, once one exists.
    ///
    /// An integer, not a reference, so an element that outlives its control
    /// holds a stale handle rather than a dangling pointer — every call
    /// through it is a typed refusal. Written by the mount as it records the
    /// control, and read by `Stage` so a component can reach what it rendered.
    pub control: platform.Handle = platform.Handle.none()

    attributes: List<Attribute> = []
    listeners: List<Listener> = []
    contents: List<Element> = []

    pub fn init(kind: controls.WidgetKind, tag: string) {
        self.kind = kind
        self.tag = tag
    }

    // ---- attributes ----

    /// Sets a property, replacing any earlier value for the same one.
    ///
    /// Replacing rather than appending, because two values for one property
    /// means the applier writes both and the last one wins — which is an order
    /// dependency nobody can see in the markup that produced it.
    pub fn set(attribute: Attribute) {
        var index: int = 0
        for index: int in 0..self.attributes.len() {
            if self.attributes[index].property == attribute.property &&
               self.attributes[index].kind == attribute.kind {
                self.attributes[index] = attribute
                return
            }
        }
        // A transition governs the writes that follow it, so it is kept ahead
        // of them all. In markup order a knob's offset_x written before its
        // transition_seconds took the previous render's duration — zero, while
        // the switch was held down — and the knob jumped instead of sliding.
        if Element.governs_motion(attribute) {
            var at: int = 0
            for at: int in 0..self.attributes.len() {
                if !Element.governs_motion(self.attributes[at]) {
                    self.attributes.insert(at, attribute)
                    return
                }
            }
        }
        self.attributes.push(attribute)
    }

    /// The two attributes that decide how every later write animates.
    static fn governs_motion(attribute: Attribute) -> bool {
        return attribute.property == visual.TRANSITION_SECONDS ||
               attribute.property == visual.TRANSITION_EASING
    }

    pub fn attribute_count() -> int {
        return self.attributes.len()
    }

    pub fn attribute_at(index: int) -> Attribute {
        return self.attributes[index]
    }

    /// The value set for a property, or `none`.
    pub fn attribute(property: int, kind: AttributeKind) -> Option<Attribute> {
        for held: Attribute in self.attributes {
            if held.property == property && held.kind == kind {
                return some(held)
            }
        }
        return none
    }

    // ---- listeners ----

    pub fn listen(kind: input.EventKind, action: fn(input.UiEvent)) {
        var index: int = 0
        for index: int in 0..self.listeners.len() {
            if self.listeners[index].kind == kind {
                self.listeners[index] = new Listener(kind, action)
                return
            }
        }
        self.listeners.push(new Listener(kind, action))
    }

    pub fn listener_count() -> int {
        return self.listeners.len()
    }

    pub fn listener_at(index: int) -> Listener {
        return self.listeners[index]
    }

    pub fn listens_for(kind: input.EventKind) -> bool {
        for held: Listener in self.listeners {
            if held.kind == kind { return true }
        }
        return false
    }

    pub fn listener(kind: input.EventKind) -> Option<Listener> {
        for held: Listener in self.listeners {
            if held.kind == kind { return some(held) }
        }
        return none
    }

    // ---- children ----

    pub fn add(child: Element) -> Element {
        self.contents.push(child)
        return child
    }

    pub fn count() -> int {
        return self.contents.len()
    }

    pub fn child_at(index: int) -> Element {
        return self.contents[index]
    }

    pub fn children() -> List<Element> {
        var out: List<Element> = []
        for child: Element in self.contents {
            out.push(child)
        }
        return move out
    }

    /// Whether two elements describe the same *thing*, so one can become the
    /// other rather than being torn down and rebuilt.
    ///
    /// Kind must match: a `Label` cannot turn into a `Button`, because there
    /// is no platform operation that does that. Keys must match when either
    /// has one — a keyed element is the author saying which is which, and
    /// matching a keyed element with an unkeyed one would silently ignore
    /// that.
    pub fn matches(other: Element) -> bool {
        if self.kind != other.kind { return false }
        if (visual.is_tag(self.tag) || visual.is_tag(other.tag)) && self.tag != other.tag { return false }
        return self.key == other.key
    }
}
