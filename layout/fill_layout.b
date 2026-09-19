// Every child gets the whole box.
package layout

import latte.geometry

/// The arrangement of a container that holds one thing and wants it to fill.
///
/// A group box, a disclosure, a scroll view, a tab view's page: each holds a
/// subtree and has nothing to say about where it goes, because the subtree is
/// usually a stack that arranges itself. What such a container has to do is
/// hand over all the room it has — which is what this does, and what nothing
/// else in this package did.
///
/// **It exists because a holder with no arranger is a leaf.** A `LayoutNode`
/// built for a tag the component vocabulary had no arranger for measured
/// itself through the platform and placed none of its children, so every
/// control inside a `<GroupBox>` in markup came out at 0,0,0,0 — laid out
/// correctly, by a layout that had decided there was nothing to lay out, and
/// invisible.
///
/// Children are stacked in the same box rather than beside one another. That
/// is deliberate: the containers this is for hold one child, and the ones that
/// hold two — a split view's panes, a tab view's pages — have the *platform*
/// deciding where each goes. Giving each the whole content box is what makes
/// the subtree inside it solve against the right size.
pub class FillLayout extends Layout {
    priv pad: geometry.EdgeInsets = geometry.EdgeInsets.zero()

    pub fn init() {}

    pub fn set_padding(insets: geometry.EdgeInsets) {
        self.pad = insets
    }

    pub override fn padding() -> geometry.EdgeInsets {
        return self.pad
    }

    /// The biggest a child wants to be, plus the padding.
    ///
    /// Not the sum: the children share one box rather than following one
    /// another, so what the container needs is enough room for the largest.
    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        let room: Constraint = limit.deflate(self.pad)
        var widest: f64 = 0.0
        var tallest: f64 = 0.0
        for index: int in 0..node.count() {
            let child: LayoutNode = node.at(index)
            if !child.spec.shown_in(room.max_width) { continue }
            let wanted: geometry.Size = child.measure(room.deflate(child.spec.margin), ruler)?
            let wide: f64 = wanted.width + child.spec.margin.horizontal()
            let tall: f64 = wanted.height + child.spec.margin.vertical()
            if wide > widest { widest = wide }
            if tall > tallest { tallest = tall }
        }
        return ok(limit.clamp(geometry.Size.of(widest + self.pad.horizontal(),
                                               tallest + self.pad.vertical())))
    }

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        let members: List<int> = members_of(node, content.width)
        for slot: int in 0..members.len() {
            let child: LayoutNode = node.at(members[slot])
            child.place(child.spec.margin.deflate(content), ruler)?
        }
        return ok(true)
    }

    /// Nothing to mirror: one box, and the box does not have a side.
    pub override fn mirrors_in_rtl() -> bool {
        return false
    }

    pub override fn label() -> string {
        return "fill"
    }
}
