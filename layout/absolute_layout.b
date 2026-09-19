// Layers in one box, each placed by its own insets.
package layout

import latte.geometry

/// Places each child by the insets its spec carries, in one shared box.
///
/// Per axis: no inset and no size opinion fills the box; one inset places the
/// measured size against that edge; two opposite insets stretch between them;
/// a pinned size or a share sits where its inset says, else at the start.
/// Nothing is clipped, and nothing mirrors in right-to-left: an inset is a
/// physical edge the author chose.
pub class AbsoluteLayout extends Layout {
    pad: geometry.EdgeInsets = geometry.EdgeInsets {}

    pub fn init() {}

    pub fn set_padding(insets: geometry.EdgeInsets) {
        self.pad = insets
    }

    pub override fn padding() -> geometry.EdgeInsets {
        return self.pad
    }

    pub override fn mirrors_in_rtl() -> bool {
        return false
    }

    pub override fn label() -> string {
        return "absolute"
    }

    /// The box that holds every layer at its natural size, insets and
    /// margins included, so a box inside a stack is sized by what it holds.
    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        var right: f64 = 0.0
        var bottom: f64 = 0.0
        let inner: Constraint = limit.deflate(self.pad)
        for index: int in 0..node.count() {
            let child: LayoutNode = node.at(index)
            if !child.spec.shown_in(inner.max_width) { continue }
            let size: geometry.Size = child.measure(inner.loosen(), ruler)?
            let reach_x: f64 = extent(child.spec, Direction.horizontal, size.width)
            let reach_y: f64 = extent(child.spec, Direction.vertical, size.height)
            if reach_x > right { right = reach_x }
            if reach_y > bottom { bottom = reach_y }
        }
        return ok(limit.clamp(geometry.Size.of(right + self.pad.horizontal(),
                                               bottom + self.pad.vertical())))
    }

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        var spilled: f64 = 0.0
        let members: List<int> = members_of(node, content.width)
        for slot: int in 0..members.len() {
            let child: LayoutNode = node.at(members[slot])
            let spec: LayoutSpec = child.spec
            let across: Span = plan(spec, Direction.horizontal, content.width)
            let down: Span = plan(spec, Direction.vertical, content.height)
            // With a shape, an axis nobody asked anything of follows the other,
            // the height first: a poster fills across and is as tall as that makes it.
            var follow_x: bool = false
            var follow_y: bool = false
            if spec.aspect_ratio > 0.0 {
                if down.filled { follow_y = true } else if across.filled { follow_x = true }
            }
            // The offer pins an axis the box decides, and is loose on the rest.
            var offer: Constraint = Constraint.of(0.0, across.room, 0.0, down.room)
            if across.settled && !follow_x && across.size >= 0.0 {
                offer.min_width = across.size
                offer.max_width = across.size
            }
            if down.settled && !follow_y && down.size >= 0.0 {
                offer.min_height = down.size
                offer.max_height = down.size
            }
            if follow_x { offer.min_width = 0.0; offer.max_width = across.room }
            if follow_y { offer.min_height = 0.0; offer.max_height = down.room }
            let size: geometry.Size = child.measure(offer, ruler)?
            let x: f64 = start(spec, Direction.horizontal, size.width, content.width)
            let y: f64 = start(spec, Direction.vertical, size.height, content.height)
            child.place(geometry.Rect.of(content.x + x, content.y + y,
                                         size.width, size.height), ruler)?
            let past_x: f64 = x + size.width + trail_of(spec, Direction.horizontal) - content.width
            let past_y: f64 = y + size.height + trail_of(spec, Direction.vertical) - content.height
            if past_x > spilled { spilled = past_x }
            if past_y > spilled { spilled = past_y }
        }
        if spilled > 0.0000001 { node.overflow = spilled }
        return ok(true)
    }
}

/// What the box decides about one axis of one layer, before it is measured.
struct Span {
    /// Whether the box settles the size: filled, stretched, or the child's own.
    pub settled: bool = false
    /// The size the box hands down when it decides one, or -1 for the child's.
    pub size: f64 = -1.0
    /// The room the child may measure in: the box less this child's margin.
    pub room: f64 = 0.0
    /// Settled only because nobody asked anything: the weakest claim.
    pub filled: bool = false
}

/// The plan for `spec` along `axis` in a box `room` wide on that axis.
fn plan(spec: LayoutSpec, axis: Direction, room: f64) -> Span {
    var out: Span = Span {}
    out.room = widen(room - spec.margin_on(axis))
    let lead: f64 = spec.inset_lead(axis)
    let trail: f64 = spec.inset_trail(axis)
    if spec.sizes(axis) {
        out.settled = true
        return out
    }
    if lead >= 0.0 && trail >= 0.0 {
        out.settled = true
        out.size = widen(out.room - lead - trail)
        return out
    }
    if lead < 0.0 && trail < 0.0 {
        out.settled = true
        out.filled = true
        out.size = out.room
    }
    return out
}

/// Where a layer of `size` starts along `axis`: after its leading inset, or
/// before its trailing one, or at its own margin.
fn start(spec: LayoutSpec, axis: Direction, size: f64, room: f64) -> f64 {
    let lead: f64 = spec.inset_lead(axis)
    let trail: f64 = spec.inset_trail(axis)
    let margin_lead: f64 = spec.margin_lead(axis)
    if lead >= 0.0 { return lead + margin_lead }
    if trail >= 0.0 {
        return room - trail - (spec.margin_on(axis) - margin_lead) - size
    }
    return margin_lead
}

/// The trailing inset along `axis`, or 0.
fn trail_of(spec: LayoutSpec, axis: Direction) -> f64 {
    let trail: f64 = spec.inset_trail(axis)
    if trail < 0.0 { return 0.0 }
    return trail
}

/// How far a layer of natural `size` reaches along `axis`: insets, margin
/// and the size, so a trailing inset counts in a box measuring itself.
fn extent(spec: LayoutSpec, axis: Direction, size: f64) -> f64 {
    var lead: f64 = spec.inset_lead(axis)
    if lead < 0.0 { lead = 0.0 }
    return lead + spec.margin_on(axis) + size + trail_of(spec, axis)
}
