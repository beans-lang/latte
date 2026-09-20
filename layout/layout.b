// The algorithm that sizes and places a node's children.
package layout

import latte.geometry

/// One arrangement strategy.
///
/// A `LayoutNode` holds exactly one of these, and the pair of methods below is
/// the whole contract: say how big you want to be inside a limit, then place
/// your children inside the box you were given. Two passes rather than one,
/// because a parent cannot size itself until its children have reported, and a
/// child cannot be placed until the parent has decided.
///
/// Subclasses are free to ignore `LayoutSpec` fields that do not apply —
/// `grow` means nothing in a grid — but they must never change a node's own
/// frame. Only `LayoutNode.place` does that, so the answer to "who set this
/// frame" is always the same one.
pub abstract class Layout {
    /// How big a node using this layout wants to be within `limit`.
    ///
    /// The answer includes this layout's own padding and must already respect
    /// `limit`; the caller clamps again, so a layout that forgets is corrected
    /// rather than allowed to overflow, but a layout that measures its
    /// children against the wrong room is not.
    pub abstract fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size>

    /// Place every child inside `content`.
    ///
    /// `content` is in the node's own coordinate space and already has this
    /// layout's padding taken off it, so a child placed at `content.x` sits
    /// just inside the padding. Child frames are relative to the node's frame
    /// origin, which is what every platform's "set this subview's frame"
    /// call expects.
    pub abstract fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool>

    /// Space this layout keeps inside the node's frame.
    pub fn padding() -> geometry.EdgeInsets {
        return geometry.EdgeInsets.zero()
    }

    /// Whether this layout's children flip when the locale reads right to
    /// left.
    ///
    /// True for everything that flows — a row of buttons should start at the
    /// right in Arabic. False for a layout whose positions were given as
    /// explicit coordinates, because those are physical by definition and the
    /// caller who wrote them has already decided where they go.
    pub fn mirrors_in_rtl() -> bool {
        return true
    }

    /// Whether this layout shows less than it holds.
    ///
    /// A run asks so it can leave a scrolling child out of the shrinking: a
    /// control that scrolls has no minimum along its scroll axis, and a run
    /// that treated its content as one would squeeze every other child to fit
    /// something that was going to scroll anyway.
    pub fn scrolls() -> bool {
        return false
    }

    /// The name expected outputs print for this layout.
    pub fn label() -> string {
        return "layout"
    }
}
