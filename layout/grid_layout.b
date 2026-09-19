// Children in rows and columns.
package layout

import latte.geometry

/// A fixed set of columns, filled row by row.
///
/// Children are placed in order: across the first row until the columns run
/// out, then down to the next. Each child occupies one cell and is aligned
/// inside it.
///
/// ### What this does not do yet, and why that is a choice
///
/// There is no explicit cell placement and no spanning. Both need per-child
/// column and row indices and a collision policy for the cells they skip, and
/// neither is needed by the layouts latte's own examples and widgets are
/// built from. Adding them means two more `LayoutSpec` fields and an
/// occupancy map, and it is a change to this file alone — `arrange` computes
/// the cell rectangle in one place. When a real screen needs a spanning cell,
/// that is the moment to add it, with the test that screen justifies.
pub class GridLayout extends Layout {
    columns: List<Track> = []
    rows: List<Track> = []
    column_gap: f64 = 0.0
    row_gap: f64 = 0.0
    pad: geometry.EdgeInsets = geometry.EdgeInsets {}
    cell_align: geometry.Align = geometry.Align.start
    /// The narrowest a column may be before the grid uses one fewer of them —
    /// the web's `repeat(auto-fit, minmax(min, 1fr))`. Zero means declared.
    fit_min: f64 = 0.0
    /// The widest a share of the room may make a column. Zero is no ceiling.
    fit_max: f64 = 0.0
    /// What to do with the room a row's columns do not use.
    spread: Justify = Justify.start

    pub fn init() {}

    /// A grid of `count` equal columns.
    pub static fn uniform(count: int, gap: f64) -> GridLayout {
        var grid: GridLayout = new GridLayout()
        var index: int = 0
        for index: int in 0..count {
            grid.add_column(Track.fraction(1.0))
        }
        grid.set_gaps(gap, gap)
        return grid
    }

    pub fn add_column(track: Track) {
        self.columns.push(track)
    }

    /// Drops the declared columns, so a second `columns` replaces the first
    /// rather than adding to it.
    pub fn clear_columns() {
        self.columns = []
    }

    /// Declares an explicit row. Rows beyond the declared ones size
    /// themselves to their content, which is what makes a grid with a fixed
    /// column set and a growing list of items work without declaring rows.
    pub fn add_row(track: Track) {
        self.rows.push(track)
    }

    /// As many equal columns as fit, each at least `points` wide. The count
    /// is not known here: it is worked out against the room, every pass.
    pub fn set_min_column(points: f64) {
        self.fit_min = points
    }

    pub fn has_min_column() -> bool {
        return self.fit_min > 0.0
    }

    /// A ceiling on a share of the room, so five tiles in a very wide window
    /// stay five tiles rather than becoming five posters.
    pub fn set_max_column(points: f64) {
        self.fit_max = points
    }

    pub fn max_column() -> f64 {
        return self.fit_max
    }

    pub fn min_column() -> f64 {
        return self.fit_min
    }

    /// Where a row sits in the room its columns leave over. Only a ceiling or
    /// a fixed track can leave any, so on a grid of shares alone this is inert.
    pub fn set_justify(mode: Justify) {
        self.spread = mode
    }

    pub fn set_gaps(column_gap: f64, row_gap: f64) {
        self.column_gap = column_gap
        self.row_gap = row_gap
    }

    /// One axis at a time, because markup writes them one at a time.
    pub fn set_column_gap(value: f64) {
        self.column_gap = value
    }

    pub fn set_row_gap(value: f64) {
        self.row_gap = value
    }

    pub fn set_padding(insets: geometry.EdgeInsets) {
        self.pad = insets
    }

    /// How a child sits in its cell when it does not fill it.
    pub fn set_align(mode: geometry.Align) {
        self.cell_align = mode
    }

    /// How many columns were *declared*. An auto-fit grid declares none: its
    /// count is a function of the room and is answered by `columns_for`.
    pub fn column_count() -> int {
        return self.columns.len()
    }

    /// The columns for a grid this wide, holding `children`. The declared
    /// ones, unless a minimum was given — then as many equal columns as fit.
    ///
    /// **A column nobody fills is collapsed, not left empty.** That is the
    /// difference between the web's `auto-fit` and its `auto-fill`, and it is
    /// the whole reason to have this: five tiles in a window with room for
    /// eleven columns are five columns filling the width, not five tiles
    /// huddled at the left with six empty tracks beside them.
    fn columns_for(room: f64, children: int) -> List<Track> {
        var out: List<Track> = []
        var index: int = 0
        if self.fit_min <= 0.0 {
            // A grid nobody gave columns to is one column, which is what
            // filling row by row means when there is only ever one cell.
            if self.columns.len() == 0 { out.push(Track.fraction(1.0)); return move out }
            for index: int in 0..self.columns.len() { out.push(self.columns[index]) }
            return move out
        }
        // n columns and n-1 gaps fit when n*(min+gap) - gap <= room, so add
        // one gap to both sides and divide.
        var count: int = 1
        let step: f64 = self.fit_min + self.column_gap
        if step > 0.0 {
            count = ((room + self.column_gap) / step) as int
        }
        if count > children { count = children }
        if count < 1 { count = 1 }
        for index: int in 0..count { out.push(Track.fraction(1.0)) }
        return move out
    }

    pub override fn padding() -> geometry.EdgeInsets {
        return self.pad
    }

    pub override fn label() -> string {
        return "grid"
    }

    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        let inner: Constraint = limit.deflate(self.pad)
        var width: f64 = 0.0
        if inner.has_max_width() {
            width = inner.max_width
        } else {
            // With no width offered there is nothing for a fraction track to
            // take a share of, so the grid asks for the width its content
            // needs and lets the parent decide.
            width = self.intrinsic_width(node, inner, ruler)?
        }
        let base: List<Track> = self.columns_for(width, shown_count(node, inner.max_width))
        let tracks: List<Track> = self.measured_columns(node, base, inner, ruler)?
        var widths: List<f64> = self.capped(tracks, self.solve_tracks(tracks, width, self.column_gap))
        var heights: List<f64> = self.solve_rows(node, tracks.len(), widths, inner, ruler)?
        var total_height: f64 = 0.0
        var index: int = 0
        for index: int in 0..heights.len() {
            total_height = total_height + heights[index]
        }
        if heights.len() > 1 {
            total_height = total_height + self.row_gap * ((heights.len() - 1) as f64)
        }
        return ok(limit.clamp(geometry.Size.of(width + self.pad.horizontal(),
                                               total_height + self.pad.vertical())))
    }

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        // Cells are numbered over the shown children; a hidden one is culled.
        let members: List<int> = members_of(node, content.width)
        let count: int = members.len()
        let base: List<Track> = self.columns_for(content.width, count)
        if count == 0 || base.len() == 0 {
            return ok(true)
        }
        let inner: Constraint = Constraint.loose(
            geometry.Size.of(content.width, content.height))
        let tracks: List<Track> = self.measured_columns(node, base, inner, ruler)?
        var widths: List<f64> = self.capped(tracks, self.solve_tracks(tracks, content.width, self.column_gap))
        var heights: List<f64> = self.solve_rows(node, tracks.len(), widths, inner, ruler)?

        let columns: int = tracks.len()
        let rows: int = (count + columns - 1) / columns
        var spilled: f64 = 0.0
        for index: int in 0..count {
            let child: LayoutNode = node.at(members[index])
            let column: int = index % columns
            let row: int = index / columns
            // The last row may be short, and it is justified by what is in it
            // rather than by what a full row would have been.
            var filled: int = columns
            if row + 1 == rows { filled = count - row * columns }
            let past: f64 = self.used_for(filled, widths) - content.width
            if past > spilled { spilled = past }
            let lead: f64 = self.lead_for(filled, widths, content.width)
            let extra: f64 = self.extra_for(filled, widths, content.width)
            var x: f64 = content.x + lead
            var step: int = 0
            for step: int in 0..column {
                x = x + widths[step] + self.column_gap + extra
            }
            var y: f64 = content.y
            for step: int in 0..row {
                y = y + heights[step] + self.row_gap
            }
            let cell: geometry.Rect = geometry.Rect.of(x, y, widths[column], heights[row])
            self.place_in_cell(child, cell, ruler)?
        }
        if spilled > 0.0000001 { node.overflow = spilled }
        return ok(true)
    }

    // ---- track sizing ----

    /// Splits `room` across `tracks`, honouring fixed sizes first and sharing
    /// what is left among the fraction tracks by weight.
    ///
    /// `auto` tracks are resolved by the caller before this runs, which is why
    /// they are passed in already carrying a fixed size: the width of an auto
    /// column depends on the children in it, and this function knows nothing
    /// about children.
    fn solve_tracks(tracks: List<Track>, room: f64, gap: f64) -> List<f64> {
        var sizes: List<f64> = []
        let count: int = tracks.len()
        if count == 0 {
            return move sizes
        }
        var used: f64 = gap * ((count - 1) as f64)
        var weight: f64 = 0.0
        var index: int = 0
        for index: int in 0..count {
            let track: Track = tracks[index]
            match track.kind {
                fixed => { sizes.push(track.value); used = used + track.value }
                auto => { sizes.push(track.value); used = used + track.value }
                fraction => { sizes.push(0.0); weight = weight + track.value }
            }
        }
        var spare: f64 = room - used
        if spare < 0.0 { spare = 0.0 }
        if weight > 0.0 {
            for index: int in 0..count {
                let track: Track = tracks[index]
                if track.kind == TrackKind.fraction {
                    sizes[index] = spare * track.value / weight
                }
            }
        }
        return move sizes
    }

    /// Fraction columns held to the ceiling, if there is one.
    ///
    /// Shares only. `columns="300 1fr"` with a ceiling of 100 keeps the 300:
    /// a ceiling on what the room hands out is not a ceiling on a number
    /// somebody wrote, and silently shrinking one would be the worse answer.
    fn capped(tracks: List<Track>, widths: List<f64>) -> List<f64> {
        var out: List<f64> = []
        var index: int = 0
        for index: int in 0..widths.len() {
            var width: f64 = widths[index]
            if self.fit_max > 0.0 && width > self.fit_max &&
               index < tracks.len() && tracks[index].kind == TrackKind.fraction {
                width = self.fit_max
            }
            out.push(width)
        }
        return move out
    }

    /// What a row of `filled` columns takes, gaps included.
    fn used_for(filled: int, widths: List<f64>) -> f64 {
        var used: f64 = 0.0
        var index: int = 0
        for index: int in 0..filled {
            if index < widths.len() { used = used + widths[index] }
        }
        if filled > 1 { used = used + self.column_gap * ((filled - 1) as f64) }
        return used
    }

    /// What a row of `filled` columns leaves unused.
    fn spare_for(filled: int, widths: List<f64>, room: f64) -> f64 {
        var spare: f64 = room - self.used_for(filled, widths)
        if spare < 0.0 { spare = 0.0 }
        return spare
    }

    /// Where such a row starts.
    fn lead_for(filled: int, widths: List<f64>, room: f64) -> f64 {
        let spare: f64 = self.spare_for(filled, widths, room)
        if spare <= 0.0 { return 0.0 }
        match self.spread {
            start => { return 0.0 }
            center => { return spare / 2.0 }
            end => { return spare }
            space_between => { return 0.0 }
            space_around => { return spare / ((filled * 2) as f64) }
            space_evenly => { return spare / ((filled + 1) as f64) }
        }
    }

    /// And what it adds to every gap inside it.
    fn extra_for(filled: int, widths: List<f64>, room: f64) -> f64 {
        let spare: f64 = self.spare_for(filled, widths, room)
        if spare <= 0.0 || filled < 2 { return 0.0 }
        match self.spread {
            start => { return 0.0 }
            center => { return 0.0 }
            end => { return 0.0 }
            space_between => { return spare / ((filled - 1) as f64) }
            space_around => { return spare / (filled as f64) }
            space_evenly => { return spare / ((filled + 1) as f64) }
        }
    }

    /// The column widths with every `auto` column resolved to the widest
    /// child in it.
    fn measured_columns(node: LayoutNode, base: List<Track>, limit: Constraint,
                        ruler: Measure) -> Result<List<Track>> {
        var out: List<Track> = []
        let columns: int = base.len()
        var index: int = 0
        for index: int in 0..columns {
            out.push(base[index])
        }
        if columns == 0 {
            return ok(move out)
        }
        var position: int = 0
        for index: int in 0..node.count() {
            let child: LayoutNode = node.at(index)
            if !child.spec.shown_in(limit.max_width) { continue }
            let column: int = position % columns
            position = position + 1
            if out[column].kind != TrackKind.auto {
                continue
            }
            let size: geometry.Size = child.measure(limit.loosen().unbound(Direction.horizontal), ruler)?
            let wanted: f64 = size.width + child.spec.margin.horizontal()
            if wanted > out[column].value {
                out[column] = Track { kind: TrackKind.auto, value: wanted }
            }
        }
        return ok(move out)
    }

    /// The width this grid needs when nobody has offered it one.
    fn intrinsic_width(node: LayoutNode, limit: Constraint,
                       ruler: Measure) -> Result<f64> {
        // Nobody offered a width, so an auto-fit grid asks for one column of
        // its own minimum and lets the parent decide.
        if self.fit_min > 0.0 { return ok(self.fit_min) }
        let tracks: List<Track> = self.measured_columns(node, self.columns_for(0.0, shown_count(node, limit.max_width)), limit, ruler)?
        var total: f64 = 0.0
        var index: int = 0
        for index: int in 0..tracks.len() {
            total = total + tracks[index].value
        }
        if tracks.len() > 1 {
            total = total + self.column_gap * ((tracks.len() - 1) as f64)
        }
        return ok(total)
    }

    /// The height of every row, with declared tracks honoured and the rest
    /// sized to the tallest child in the row.
    fn solve_rows(node: LayoutNode, columns: int, widths: List<f64>,
                  limit: Constraint, ruler: Measure) -> Result<List<f64>> {
        var heights: List<f64> = []
        var pinned: List<bool> = []
        if columns == 0 {
            return ok(move heights)
        }
        let row_count: int = (shown_count(node, limit.max_width) + columns - 1) / columns
        var index: int = 0
        for index: int in 0..row_count {
            var height: f64 = 0.0
            var fixed: bool = false
            if index < self.rows.len() && self.rows[index].kind == TrackKind.fixed {
                height = self.rows[index].value
                fixed = true
            }
            heights.push(height)
            pinned.push(fixed)
        }
        var position: int = 0
        for index: int in 0..node.count() {
            let child: LayoutNode = node.at(index)
            if !child.spec.shown_in(limit.max_width) { continue }
            let column: int = position % columns
            let row: int = position / columns
            position = position + 1
            if pinned[row] {
                continue
            }
            // The child is measured at the width its column ended up with, so
            // a wrapping label in a narrow column reports the height it will
            // really need rather than the one it wanted when unconstrained.
            var band: f64 = 0.0
            if column < widths.len() {
                band = widths[column] - child.spec.margin.horizontal()
            }
            if band < 0.0 { band = 0.0 }
            // A stretched cell is measured at the width it will get, so a
            // shape inside it answers for the real box.
            var offer: Constraint = Constraint.of(0.0, band, 0.0, -1.0)
            if child.spec.align.resolve(self.cell_align) == geometry.Align.stretch {
                offer = Constraint.of(band, band, 0.0, -1.0)
            }
            let size: geometry.Size = child.measure(offer, ruler)?
            let wanted: f64 = size.height + child.spec.margin.vertical()
            if wanted > heights[row] {
                heights[row] = wanted
            }
        }
        return ok(move heights)
    }

    /// Sizes one child inside its cell and places it there.
    fn place_in_cell(child: LayoutNode, cell: geometry.Rect,
                     ruler: Measure) -> Result<bool> {
        var room: geometry.Rect = child.spec.margin.deflate(cell)
        let placement: geometry.Align = child.spec.align.resolve(self.cell_align)
        var size: geometry.Size = geometry.Size.of(room.width, room.height)
        if placement != geometry.Align.stretch {
            size = child.measure(Constraint.loose(size), ruler)?
        }
        let x: f64 = room.x + placement.offset(size.width, room.width)
        let y: f64 = room.y + placement.offset(size.height, room.height)
        return child.place(geometry.Rect.of(x, y, size.width, size.height), ruler)
    }
}
