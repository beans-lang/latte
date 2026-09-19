// A run whose children share out the space that is left over.
package layout

import latte.geometry

/// A stack that grows and shrinks its children to fit, and breaks into lines
/// when told to wrap. `distribute` is the one method a plain stack lacks.
pub class FlexLayout extends StackLayout {
    wrapping: bool = false
    line_gap: f64 = 0.0

    pub fn init(axis: Direction, spacing: f64) {
        super.init(axis, spacing)
    }

    pub static fn row(spacing: f64) -> FlexLayout {
        return new FlexLayout(Direction.horizontal, spacing)
    }

    pub static fn column(spacing: f64) -> FlexLayout {
        return new FlexLayout(Direction.vertical, spacing)
    }

    /// Whether children start a new line along the cross axis when the next
    /// would not fit. Off, a run overflows or shrinks; on, it breaks.
    pub fn set_wrap(state: bool) {
        self.wrapping = state
    }

    pub fn wraps() -> bool {
        return self.wrapping
    }

    /// The gap between one line and the next, read only when wrapping.
    pub fn set_line_spacing(gap: f64) {
        self.line_gap = gap
    }

    pub fn line_spacing() -> f64 {
        return self.line_gap
    }

    pub override fn label() -> string {
        if self.wrapping { return "wrap" }
        return "flex"
    }

    override fn shares_space() -> bool {
        return true
    }

    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        if !self.wrapping { return super.measure(node, limit, ruler) }
        return self.measure_lines(node, limit, ruler)
    }

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        if !self.wrapping { return super.arrange(node, content, ruler) }
        return self.arrange_lines(node, content, ruler)
    }

    /// Hands out free space by `grow` and takes overflow back by `shrink`,
    /// freezing each child that hits a bound and redistributing the rest.
    override fn distribute(run: AxisRun) {
        for index: int in 0..run.count {
            let base: f64 = run.base_at(index)
            let fitted: f64 = run.clamp_at(index, base)
            run.set_main(index, fitted)
            if fitted != base {
                run.freeze(index)
            }
        }

        // At least one child freezes per round or nothing moves, so this
        // runs at most once per child.
        for round: int in 0..(run.count + 1) {
            let slack: f64 = run.room - run.total()
            if slack > -0.0000001 && slack < 0.0000001 {
                return
            }
            let growing: bool = slack > 0.0
            var weight: f64 = 0.0
            for index: int in 0..run.count {
                if run.is_frozen(index) { continue }
                if growing {
                    weight = weight + run.grow_at(index)
                } else {
                    // Weighted by size too, so a narrow child does not vanish first.
                    weight = weight + run.shrink_at(index) * run.main_at(index)
                }
            }
            if weight <= 0.0 {
                return
            }

            var froze: bool = false
            for index: int in 0..run.count {
                if run.is_frozen(index) { continue }
                var share: f64 = run.grow_at(index) / weight
                if !growing {
                    share = run.shrink_at(index) * run.main_at(index) / weight
                }
                let wanted: f64 = run.main_at(index) + slack * share
                let allowed: f64 = run.clamp_at(index, wanted)
                run.set_main(index, allowed)
                if allowed != wanted {
                    run.freeze(index)
                    froze = true
                }
            }
            if !froze {
                return
            }
        }
    }

    // ---- wrapping: pass one ----

    /// Lines break against the main-axis room offered; with none offered
    /// everything goes on one line, which is what an unbounded row is.
    fn measure_lines(node: LayoutNode, limit: Constraint,
                     ruler: Measure) -> Result<geometry.Size> {
        let inner: Constraint = limit.deflate(self.padding())
        let axis: Direction = self.direction()
        let cross_axis: Direction = axis.cross()
        let room: f64 = axis.main_of(inner.available())
        var widest: f64 = 0.0
        var stacked: f64 = 0.0
        var lines: int = 0
        var used: f64 = 0.0
        var band: f64 = 0.0
        var in_line: int = 0
        for index: int in 0..node.count() {
            let child: LayoutNode = node.at(index)
            if !child.spec.shown_in(inner.max_width) { continue }
            let offer: Constraint = inner.deflate(child.spec.margin).unbound(axis).loosen()
            let size: geometry.Size = child.measure(offer, ruler)?
            let along: f64 = axis.main_of(size) + child.spec.margin_on(axis)
            let across: f64 = cross_axis.main_of(size) + child.spec.margin_on(cross_axis)
            if in_line > 0 && self.breaks_before(used, along, room) {
                if used > widest { widest = used }
                stacked = stacked + band
                lines = lines + 1
                used = 0.0
                band = 0.0
                in_line = 0
            }
            if in_line > 0 { used = used + self.spacing }
            used = used + along
            if across > band { band = across }
            in_line = in_line + 1
        }
        if in_line > 0 {
            if used > widest { widest = used }
            stacked = stacked + band
            lines = lines + 1
        }
        if lines > 1 {
            stacked = stacked + self.line_gap * ((lines - 1) as f64)
        }
        let pad: geometry.EdgeInsets = self.padding()
        let padded: geometry.Size = axis.size(
            widest + axis.main_of(geometry.Size.of(pad.horizontal(), pad.vertical())),
            stacked + cross_axis.main_of(geometry.Size.of(pad.horizontal(), pad.vertical())))
        return ok(limit.clamp(padded))
    }

    /// Whether a child `along` wide starts a new line after `used`. Never in
    /// unbounded room, and never for the first child of a line.
    fn breaks_before(used: f64, along: f64, room: f64) -> bool {
        if room < 0.0 { return false }
        return used + self.spacing + along > room + 0.0000001
    }

    // ---- wrapping: pass two, a line at a time ----

    fn arrange_lines(node: LayoutNode, content: geometry.Rect,
                     ruler: Measure) -> Result<bool> {
        // `index` below is a slot among the shown children, not a child index.
        let members: List<int> = members_of(node, content.width)
        let count: int = members.len()
        if count == 0 {
            return ok(true)
        }
        let axis: Direction = self.direction()
        let cross_axis: Direction = axis.cross()
        let room_main: f64 = axis.main_extent(content)

        // Break into lines by natural size, exactly as `measure_lines` did.
        var starts: List<int> = []
        var used: f64 = 0.0
        var in_line: int = 0
        var mains: List<f64> = []
        for index: int in 0..count {
            let child: LayoutNode = node.at(members[index])
            let offer: Constraint = Constraint.loose(
                geometry.Size.of(content.width, content.height))
                .deflate(child.spec.margin).unbound(axis)
            let measured: geometry.Size = child.measure(offer, ruler)?
            var base: f64 = axis.main_of(measured)
            if child.spec.basis >= 0.0 { base = child.spec.basis }
            let share: f64 = child.spec.percent_size(axis, room_main - child.spec.margin_on(axis))
            if share >= 0.0 {
                if child.spec.basis >= 0.0 {
                    return err("\"{child.name}\" asks for a basis of {child.spec.basis} and a share of {child.spec.percent_on(axis)}% along the same axis — write one",
                               "basis_and_percent")
                }
                base = share
            }
            mains.push(base)
            let along: f64 = base + child.spec.margin_on(axis)
            if in_line > 0 && self.breaks_before(used, along, room_main) {
                used = 0.0
                in_line = 0
            }
            if in_line == 0 { starts.push(index) }
            if in_line > 0 { used = used + self.spacing }
            used = used + along
            in_line = in_line + 1
        }

        var spilled: f64 = 0.0
        var cross_cursor: f64 = axis.cross_start(content)
        for line: int in 0..starts.len() {
            let first: int = starts[line]
            var last: int = count
            if line + 1 < starts.len() { last = starts[line + 1] }

            // Distribute this line's leftover by grow and shrink.
            var reserved: f64 = self.spacing * ((last - first - 1) as f64)
            for index: int in first..last {
                reserved = reserved + node.at(members[index]).spec.margin_on(axis)
            }
            var run: AxisRun = new AxisRun(room_main - reserved)
            for index: int in first..last {
                let child: LayoutNode = node.at(members[index])
                run.add(mains[index], child.spec.min_on(axis), child.spec.max_on(axis),
                        child.spec.grow, child.spec.shrink)
            }
            self.distribute(run)
            let over: f64 = run.total() - run.room
            if over > spilled { spilled = over }

            // The line's band is the tallest child once its main size is settled.
            var band: f64 = 0.0
            var crosses: List<f64> = []
            for index: int in first..last {
                let child: LayoutNode = node.at(members[index])
                let settled: Constraint = axis.pin(run.main_at(index - first), -1.0)
                let final_size: geometry.Size = child.measure(settled, ruler)?
                let across: f64 = cross_axis.main_of(final_size)
                crosses.push(across)
                let reach: f64 = across + child.spec.margin_on(cross_axis)
                if reach > band { band = reach }
            }

            let free: f64 = run.room - run.total()
            let on_line: int = last - first
            var cursor: f64 = axis.main_start(content) + self.justify.lead(free, on_line)
            let gap: f64 = self.justify.gap(free, on_line)
            for index: int in first..last {
                let child: LayoutNode = node.at(members[index])
                let main_size: f64 = run.main_at(index - first)
                cursor = cursor + child.spec.margin_lead(axis)
                var room_across: f64 = band - child.spec.margin_on(cross_axis)
                if room_across < 0.0 { room_across = 0.0 }
                let placement: geometry.Align = child.spec.align.resolve(self.cross_default())
                var cross_size: f64 = room_across
                if placement != geometry.Align.stretch {
                    cross_size = crosses[index - first]
                }
                cross_size = clamp_cross(cross_size, child.spec, cross_axis, room_across)
                let cross_at: f64 = cross_cursor + child.spec.margin_lead(cross_axis) +
                                    placement.offset(cross_size, room_across)
                child.place(axis.rect(cursor, cross_at, main_size, cross_size), ruler)?
                let trail: f64 = child.spec.margin_on(axis) - child.spec.margin_lead(axis)
                cursor = cursor + main_size + trail + self.spacing + gap
            }
            cross_cursor = cross_cursor + band + self.line_gap
        }
        if spilled > 0.0000001 { node.overflow = spilled }
        return ok(true)
    }
}
