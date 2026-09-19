// A row or a column of children.
package layout

import latte.geometry

/// Lays children out one after another along one axis.
///
/// This is the layout almost every screen is made of: a column of rows. Each
/// child keeps the size it measured; leftover space along the main axis is
/// shared out by `justify`, and the cross axis is settled per child by
/// `align`, with `Align.stretch` filling the run.
///
/// `FlexLayout` extends this class and replaces exactly one method,
/// `distribute`, which is the step that decides each child's main-axis size.
/// Everything else — measuring, margins, justification, cross alignment,
/// padding, the second measure pass — is shared, so a fix to any of it lands
/// in both layouts and cannot drift between them.
pub class StackLayout extends Layout {
    axis: Direction = Direction.vertical
    spacing: f64 = 0.0
    pad: geometry.EdgeInsets = geometry.EdgeInsets {}
    justify: Justify = Justify.start
    cross: geometry.Align = geometry.Align.start

    pub fn init(axis: Direction, spacing: f64) {
        self.axis = axis
        self.spacing = spacing
    }

    /// A left-to-right run.
    pub static fn row(spacing: f64) -> StackLayout {
        return new StackLayout(Direction.horizontal, spacing)
    }

    /// A top-to-bottom run.
    pub static fn column(spacing: f64) -> StackLayout {
        return new StackLayout(Direction.vertical, spacing)
    }

    pub fn set_spacing(gap: f64) {
        self.spacing = gap
    }

    pub fn set_padding(insets: geometry.EdgeInsets) {
        self.pad = insets
    }

    pub fn set_justify(mode: Justify) {
        self.justify = mode
    }

    /// The cross-axis alignment children take when they express no opinion.
    pub fn set_align(mode: geometry.Align) {
        self.cross = mode
    }

    pub fn direction() -> Direction {
        return self.axis
    }

    /// The cross-axis alignment a child with no opinion takes.
    pub fn cross_default() -> geometry.Align {
        return self.cross
    }

    pub override fn padding() -> geometry.EdgeInsets {
        return self.pad
    }

    pub override fn label() -> string {
        return "stack"
    }

    // ---- pass one: how big does this run want to be ----

    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        let inner: Constraint = limit.deflate(self.pad)
        let cross_axis: Direction = self.axis.cross()
        var main_total: f64 = 0.0
        var cross_max: f64 = 0.0
        var seen: int = 0
        for index: int in 0..node.count() {
            let child: LayoutNode = node.at(index)
            // Judged by the width this run will have; a child the room hides takes nothing.
            if !child.spec.shown_in(inner.max_width) { continue }
            // Each child is measured with no limit along the main axis: the
            // run is asking how big everyone naturally is, and only once that
            // is known can it decide whether there is room to share out.
            var offer: Constraint = inner.deflate(child.spec.margin).unbound(self.axis).loosen()
            // A child that will be stretched is measured at the width it will
            // get, as `arrange` does — but only once that width is settled. A
            // run still finding its own width takes its children's natural one.
            if child.spec.align.resolve(self.cross) == geometry.Align.stretch &&
               self.cross_settled(inner) {
                var band: f64 = cross_axis.main_of(inner.available()) - child.spec.margin_on(cross_axis)
                if band < 0.0 { band = 0.0 }
                if self.axis.is_horizontal() {
                    offer = Constraint.of(0.0, -1.0, band, band)
                } else {
                    offer = Constraint.of(band, band, 0.0, -1.0)
                }
            }
            let size: geometry.Size = child.measure(offer, ruler)?
            main_total = main_total + self.axis.main_of(size) + child.spec.margin_on(self.axis)
            let reach: f64 = cross_axis.main_of(size) + child.spec.margin_on(cross_axis)
            if reach > cross_max { cross_max = reach }
            seen = seen + 1
        }
        if seen > 1 {
            main_total = main_total + self.spacing * ((seen - 1) as f64)
        }
        let padded: geometry.Size = self.axis.size(
            main_total + self.axis.main_of(insets_size(self.pad)),
            cross_max + cross_axis.main_of(insets_size(self.pad)))
        return ok(limit.clamp(padded))
    }

    /// Whether `limit` pins this run's cross axis to one number.
    fn cross_settled(limit: Constraint) -> bool {
        if self.axis.is_horizontal() {
            return limit.has_max_height() && limit.min_height == limit.max_height
        }
        return limit.has_max_width() && limit.min_width == limit.max_width
    }

    // ---- pass two: place everyone ----

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        // Who is in the run: a child the room hides is culled and takes nothing.
        let members: List<int> = members_of(node, content.width)
        let count: int = members.len()
        if count == 0 {
            return ok(true)
        }
        let cross_axis: Direction = self.axis.cross()
        let room_main: f64 = self.axis.main_extent(content)
        let room_cross: f64 = self.axis.cross_extent(content)

        // Everything the children cannot use: their margins, and the fixed
        // gaps between them. Taking it off up front means `run.room` is the
        // space actually up for distribution, so `free` is a straight
        // subtraction rather than a running tally that is easy to get wrong.
        var reserved: f64 = self.spacing * ((count - 1) as f64)
        for slot: int in 0..count {
            reserved = reserved + node.at(members[slot]).spec.margin_on(self.axis)
        }

        var run: AxisRun = new AxisRun(room_main - reserved)
        for slot: int in 0..count {
            let child: LayoutNode = node.at(members[slot])
            var offer: Constraint = Constraint.loose(
                geometry.Size.of(content.width, content.height))
                .deflate(child.spec.margin).unbound(self.axis)
            // A child that will be stretched is measured at the size it will
            // get, so a wrapped label or an aspect ratio answers for the real box.
            if child.spec.align.resolve(self.cross) == geometry.Align.stretch {
                var band: f64 = room_cross - child.spec.margin_on(cross_axis)
                if band < 0.0 { band = 0.0 }
                if self.axis.is_horizontal() {
                    offer = Constraint.of(0.0, -1.0, band, band)
                } else {
                    offer = Constraint.of(band, band, 0.0, -1.0)
                }
            }
            let measured: geometry.Size = child.measure(offer, ruler)?
            var base: f64 = self.axis.main_of(measured)
            // A scroll view that grows starts from nothing and takes what is
            // left. Starting from its content instead made the run overflow by
            // whatever it was going to scroll, and the shrinking that followed
            // came off its siblings — a header losing the second line it had
            // just wrapped onto.
            if child.layout().scrolls() && child.spec.grow > 0.0 {
                base = 0.0
            }
            if child.spec.basis >= 0.0 {
                base = child.spec.basis
            }
            // A share of the run is a basis: the child still grows and shrinks
            // from it, and a basis written beside it is a contradiction.
            let share: f64 = child.spec.percent_size(self.axis, room_main - child.spec.margin_on(self.axis))
            if share >= 0.0 {
                if child.spec.basis >= 0.0 {
                    return err("\"{child.name}\" asks for a basis of {child.spec.basis} and a share of {child.spec.percent_on(self.axis)}% along the same axis — write one",
                               "basis_and_percent")
                }
                base = share
            }
            // A child that asked to grow, in a layout that hands nothing out.
            //
            // This is a refusal rather than a silent ignore, and it is here
            // because the silent version cost three separate afternoons: a
            // canvas 0 points wide, a table 0 points wide, and a search field
            // squeezed to its intrinsic size — each laid out exactly as asked,
            // each invisible or useless, and none of them saying anything. A
            // `StackLayout` gives every child the size it measured; `grow` is
            // `FlexLayout`'s word, and asking for it here is asking the wrong
            // layout.
            if child.spec.grow > 0.0 && !self.shares_space() {
                return err("\"{child.name}\" asks to grow by {child.spec.grow}, but its parent is a StackLayout, which gives every child the size it measures — use FlexLayout.{self.axis.name()} to hand out the leftover space",
                           "grow_in_a_stack")
            }
            run.add(base, child.spec.min_on(self.axis), child.spec.max_on(self.axis),
                    child.spec.grow, child.spec.shrink)
        }

        self.distribute(run)
        // What the children still need past the room, once shrinking is done.
        let spilled: f64 = run.total() - run.room
        if spilled > 0.0000001 { node.overflow = spilled }

        let free: f64 = run.room - run.total()
        let lead: f64 = self.justify.lead(free, count)
        let gap: f64 = self.justify.gap(free, count)

        var cursor: f64 = self.axis.main_start(content) + lead
        for slot: int in 0..count {
            let child: LayoutNode = node.at(members[slot])
            let main_size: f64 = run.main_at(slot)
            cursor = cursor + child.spec.margin_lead(self.axis)

            // The run of space this child's cross axis may use, after its own
            // margin is taken off both sides.
            var band: f64 = room_cross - child.spec.margin_on(cross_axis)
            if band < 0.0 { band = 0.0 }

            let placement: geometry.Align = child.spec.align.resolve(self.cross)
            var cross_size: f64 = band
            if placement != geometry.Align.stretch {
                // Measure again, now that the main size is settled. A label
                // that grew wider needs fewer lines, and a run that skipped
                // this would size it from the width it was guessed at.
                let settled: Constraint = self.axis.pin(main_size, band)
                let final_size: geometry.Size = child.measure(settled, ruler)?
                cross_size = cross_axis.main_of(final_size)
            }
            cross_size = clamp_cross(cross_size, child.spec, cross_axis, band)

            let band_start: f64 = self.axis.cross_start(content) + child.spec.margin_lead(cross_axis)
            let cross_at: f64 = band_start + placement.offset(cross_size, band)
            child.place(self.axis.rect(cursor, cross_at, main_size, cross_size), ruler)?

            let margin_trail: f64 = child.spec.margin_on(self.axis) - child.spec.margin_lead(self.axis)
            cursor = cursor + main_size + margin_trail + self.spacing + gap
        }
        return ok(true)
    }

    /// Decides each child's final main-axis size.
    ///
    /// A stack gives every child the size it measured, pulled inside whatever
    /// bounds that child set. It does not grow anyone into leftover space and
    /// does not shrink anyone to fit — that is `FlexLayout`, which replaces
    /// this method and nothing else.
    ///
    /// Package-private on purpose: it is the extension point between these two
    /// classes, not something an application overrides.
    /// Whether this layout hands out the leftover space along its main axis.
    ///
    /// False here, true in `FlexLayout`, and the only reason it exists is the
    /// refusal above: `arrange` is shared between the two, so the check that
    /// catches `grow` in a stack has to be able to tell which one it is in.
    fn shares_space() -> bool {
        return false
    }

    fn distribute(run: AxisRun) {
        var index: int = 0
        for index: int in 0..run.count {
            run.set_main(index, run.clamp_at(index, run.base_at(index)))
        }
    }
}

// The padding of a box expressed as the size it costs, so the axis accessors
// can read it the same way they read any other size.
fn insets_size(insets: geometry.EdgeInsets) -> geometry.Size {
    return geometry.Size.of(insets.horizontal(), insets.vertical())
}

// A cross-axis size pulled inside the child's own bounds and the room it has.
fn clamp_cross(value: f64, spec: LayoutSpec, cross_axis: Direction, band: f64) -> f64 {
    // A share of the band is the size, whatever stretching would have given.
    let share: f64 = spec.percent_size(cross_axis, band)
    if share >= 0.0 { return share }
    var out: f64 = value
    let lower: f64 = spec.min_on(cross_axis)
    let upper: f64 = spec.max_on(cross_axis)
    if out < lower { out = lower }
    if upper >= 0.0 && out > upper { out = upper }
    if out > band { out = band }
    if out < 0.0 { out = 0.0 }
    return out
}
