// One child, as tall as it needs, behind a viewport that is not.
package layout

import latte.geometry

/// The arrangement of a container that scrolls what it cannot show.
///
/// A `FillLayout` hands every child the whole box, which is right for a group
/// box and wrong for a scroll view: the content can then never be bigger than
/// the viewport, so nothing ever scrolls.
///
/// **This is the difference, and it is the whole class.** Children are
/// measured with the scroll axis *unbounded* — how tall would you like to be,
/// with no ceiling — and placed at that height when it exceeds the viewport.
/// The node remembers the result in `content`, which is what the platform is
/// told so it has something to scroll over.
///
/// The axis is vertical. That is what every host enables — AppKit sets
/// `hasVerticalScroller`, Win32 sets `WS_VSCROLL` — and a horizontal one would
/// need a direction on `<ScrollView>` and the matching scroller in four hosts.
///
/// No padding. `Builder.set_padding` refuses a scroll view already, so a
/// padding field here would be a field nothing could ever write.
pub class ScrollLayout extends Layout {
    pub fn init() {}

    /// As big as the content wants, then clamped to the room on offer.
    ///
    /// The clamp is what makes a scroll view fill a bounded parent rather than
    /// push it open; the unbounded measure below is what makes the content's
    /// real height reach `arrange` instead of the viewport's.
    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        // A scroll view nobody gave a height to, in a run that hands none out.
        // It would take its content's height and never scroll, saying nothing.
        if !limit.has_max_height() && node.spec.max_height < 0.0 &&
           node.spec.grow <= 0.0 {
            return err("\"{node.name}\" is a scroll view with no height of its own, in a run that hands none out — it would grow to its content and scroll nothing. Give it height=\{ \}, or flex=\{ \} inside a VStack",
                       "unbounded_scroll")
        }
        return ok(limit.clamp(self.content_of(node, limit, ruler)?))
    }

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        let room: Constraint = Constraint.loose(
            geometry.Size.of(content.width, content.height))
        let wanted: geometry.Size = self.content_of(node, room, ruler)?
        var tall: f64 = content.height
        if wanted.height > tall { tall = wanted.height }
        let members: List<int> = members_of(node, content.width)
        for slot: int in 0..members.len() {
            let child: LayoutNode = node.at(members[slot])
            child.place(child.spec.margin.deflate(geometry.Rect.of(content.x, content.y,
                                                                   content.width, tall)), ruler)?
        }
        // What the platform is given to scroll over. Equal to the frame when
        // the content fits, which is a scroll view with nothing to scroll.
        node.content = geometry.Size.of(content.width, tall)
        return ok(true)
    }

    /// How tall the one child wants to be with no ceiling on the scroll axis.
    ///
    /// **One child, and it is refused rather than arranged.** Every toolkit
    /// here scrolls a single content view, so children share a box the way a
    /// group box's do — twelve of them land in the same rectangle, on top of
    /// one another, which is what a person writing a screen actually hits.
    fn content_of(node: LayoutNode, room: Constraint,
                  ruler: Measure) -> Result<geometry.Size> {
        if node.count() > 1 {
            return err("\"{node.name}\" scrolls {node.count()} children, and a scroll view scrolls one — every platform here has a single content view, so the others would be laid on top of it. Put them in a <VStack> inside it",
                       "too_many_children")
        }
        let sky: Constraint = room.unbound(Direction.vertical)
        var widest: f64 = 0.0
        var tallest: f64 = 0.0
        for index: int in 0..node.count() {
            let child: LayoutNode = node.at(index)
            if !child.spec.shown_in(room.max_width) { continue }
            let wanted: geometry.Size = child.measure(sky.deflate(child.spec.margin), ruler)?
            let wide: f64 = wanted.width + child.spec.margin.horizontal()
            let tall: f64 = wanted.height + child.spec.margin.vertical()
            if wide > widest { widest = wide }
            if tall > tallest { tallest = tall }
        }
        return ok(geometry.Size.of(widest, tallest))
    }

    pub override fn scrolls() -> bool {
        return true
    }

    /// Nothing to mirror: one child, and it fills the width either way.
    pub override fn mirrors_in_rtl() -> bool {
        return false
    }

    pub override fn label() -> string {
        return "scroll"
    }
}
