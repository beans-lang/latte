package scene

import latte.geometry
import latte.paint
import latte.input
import latte.platform

/// Where along a track a thumb sits, as a share of the room it has.
fn room_share(at: f64, room: f64) -> f64 {
    if room <= 0.0 { return 0.0 }
    return at / room
}

/// The shared table asks only for rows it is about to show.
pub interface TableData {
    fn row_count() -> int
    fn cell(row: int, column: int) -> string
}

/// Rows and columns, both virtual, with a logical scroll position.
///
/// ### Why the vertical scroll is a row index and not a coordinate
///
/// A scene's coordinates stop at 10,000,000 points, and they reach Skia, which
/// is float32 and exact only to 16,777,216. A table that reported its whole
/// extent as a scroll offset therefore capped at about 416,000 rows at the
/// default row height, and there is no bound to raise that makes ten million
/// rows land on the right pixel.
///
/// So the scroll position here is **the first visible row and how far it is
/// scrolled under the header**, and every coordinate that leaves this class is
/// measured from that row rather than from row zero. A cell's painted top is
/// `(row - first) * row_height - fraction`, which is a number between minus one
/// row and the height of the viewport whatever the row index is. The absolute
/// offset is still available — `scroll_offset()` — because keyboard paging and
/// a scrollbar need it, and it is arithmetic in `f64` that nothing draws with.
///
/// The bound that remains is the one that bound has: a double's step at the
/// extent must stay far below a pixel, which `validate_rows` states in the
/// refusal it writes.
pub class TableRender extends ScrollRender {
    source: Option<TableData> = none
    edit_policy: Option<fn(int, int) -> bool> = none
    titles: List<string> = []
    widths: List<f64> = []
    /// Cumulative column left edges: `lefts[i]` is column `i`'s left edge and
    /// `lefts[count]` is the whole content width. Rebuilt when a width moves,
    /// which is what makes finding a column a binary search instead of a walk.
    lefts: List<f64> = []
    rows_value: int = 0
    /// The first row whose band meets the top of the body, and how far it has
    /// moved under the header — as a share of a row, `0 <= top_part < 1`,
    /// rather than as points. A denser appearance changes the row height under
    /// a table that is already scrolled, and a share stays a share: the same
    /// row stays at the top, in the same place within itself, and the value
    /// cannot end up larger than the row it is measured against.
    top_row: int = 0
    top_part: f64 = 0.0
    left_value: f64 = 0.0
    selected_value: int = -1
    selected_column_value: int = -1
    revision: int = 0
    data_revision: int = 0
    editing_row_value: int = -1
    editing_column_value: int = -1
    focus_editor: bool = false
    tracking: bool = false
    /// Which thumb the pointer is dragging: 0 none, 1 the rows', 2 the
    /// columns'. `grab` is where inside the thumb it was taken hold of.
    dragging: int = 0
    grab: f64 = 0.0
    /// How many times a template has rebuilt this table's visible cells. A
    /// scroll inside the rows and columns already on screen must not move it,
    /// and that is a claim a test can only check if somebody counts.
    rebuilds: int = 0
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.focusable = true
        self.lefts = [0.0]
    }
    pub override fn role() -> string { return "table" }
    /// The size a reader is told, which is the source's and not the dozen rows
    /// on screen. Without it a virtual table announces "row 3 of 12" in the
    /// middle of ten million.
    pub override fn semantics_at(bounds: geometry.Rect) -> SemanticsNode {
        var node: SemanticsNode = super.semantics_at(bounds)
        node.set_grid(0, 0, self.rows_value, self.titles.len())
        return node
    }
    pub override fn needs_template() -> bool { return true }
    pub override fn interactive_visual() -> bool { return true }
    /// The box the template is laid out in: the whole content when it is wider
    /// than the table, the table's own box when it is not. The inset before
    /// the first column is part of the content, so it is in this number too —
    /// without it the last column's right edge lands outside the template.
    pub override fn template_size() -> geometry.Size {
        var width: f64 = self.bounds.width
        let columns: f64 = self.columns_width() + self.column_inset()
        if columns > width { width = columns }
        return geometry.Size.of(width, self.bounds.height)
    }
    /// A list row and its header, from the theme rather than a constant, so
    /// the whole window tightens or loosens together.
    pub fn row_height() -> f64 { return self.theme.row_height() }
    pub fn header_height() -> f64 { return self.theme.header_height() }
    /// The gap before the first column. One number for the drawing and the hit
    /// test: a template that inset its cells and a hit test that did not is a
    /// click that lands on the column to the left near an edge.
    pub fn column_inset() -> f64 { return 6.0 }
    pub fn row_count() -> int { return self.rows_value }
    pub fn column_count() -> int { return self.titles.len() }
    pub fn selected() -> int { return self.selected_value }
    pub fn selected_column() -> int { return self.selected_column_value }
    pub fn version() -> int { return self.revision }
    pub fn data_version() -> int { return self.data_revision }
    pub fn editing_row() -> int { return self.editing_row_value }
    pub fn editing_column() -> int { return self.editing_column_value }
    pub override fn visual_focus_requested() -> bool { return self.focus_editor }
    pub override fn acknowledge_visual_focus() { self.focus_editor = false }
    pub fn has_source() -> bool { return self.source != none }
    pub fn has_edit_policy() -> bool { return self.edit_policy != none }
    pub fn rebuild_count() -> int { return self.rebuilds }
    /// Called by the template when it rebuilds the visible cells.
    pub fn note_rebuild() { self.rebuilds += 1 }

    // ---- where the viewport is ----

    /// The first row on screen, and how far it has slid under the header.
    pub fn first_visible_row() -> int { return self.top_row }
    pub fn row_fraction() -> f64 { return self.top_part * self.row_height() }
    /// The same position as one number, for paging and for a scrollbar. Never
    /// a coordinate: see the note on the class.
    pub fn scroll_offset() -> f64 {
        return (self.top_row as f64 + self.top_part) * self.row_height()
    }
    pub fn scroll_x() -> f64 { return self.left_value }
    /// How tall the rows are allowed to be — the box less the header.
    pub fn body_height() -> f64 {
        let body: f64 = self.bounds.height - self.header_height()
        return if body > 0.0 { body } else { 0.0 }
    }
    /// The whole extent, as information rather than as a place to draw. The
    /// height is why this is not `ScrollRender`'s content size: ten million
    /// rows is 240,000,000 points, and `set_content_size` refuses that.
    pub override fn content_size() -> geometry.Size {
        return geometry.Size.of(self.columns_width(),
                                self.header_height() + self.rows_value as f64 * self.row_height())
    }
    pub override fn set_content_size(size: geometry.Size) -> Result<bool> {
        return err("a table's extent comes from its rows and columns", "wrong_kind")
    }

    // ---- columns ----

    pub fn columns_width() -> f64 { return self.lefts[self.lefts.len() - 1] }
    /// Column `column`'s left edge in content coordinates, the inset included.
    pub fn column_left(column: int) -> f64 {
        if column < 0 { return self.column_inset() }
        if column >= self.lefts.len() { return self.column_inset() + self.columns_width() }
        return self.column_inset() + self.lefts[column]
    }
    fn rebuild_lefts() {
        var running: f64 = 0.0
        var built: List<f64> = [0.0]
        for value: f64 in self.widths { running += value; built.push(running) }
        self.lefts = move built
    }
    /// The column `x` lands in, `x` measured from the left of the content with
    /// the inset already taken off. Binary search: a wheel event on a table of
    /// a thousand columns must not walk a thousand widths.
    fn column_containing(x: f64) -> int {
        let count: int = self.widths.len()
        if count == 0 || x < 0.0 { return -1 }
        if x >= self.columns_width() { return -1 }
        var low: int = 0
        var high: int = count
        for low < high {
            let mid: int = low + (high - low) / 2
            if self.lefts[mid + 1] <= x { low = mid + 1 } else { high = mid }
        }
        return low
    }
    /// The first column whose right edge is past `x`, clamped into range. What
    /// a template asks for the left end of the visible strip.
    pub fn column_reaching(x: f64) -> int {
        let count: int = self.widths.len()
        if count == 0 { return 0 }
        var want: f64 = x - self.column_inset()
        if want < 0.0 { want = 0.0 }
        if want >= self.columns_width() { return count - 1 }
        let found: int = self.column_containing(want)
        return if found < 0 { 0 } else { found }
    }
    pub fn title(column: int) -> Result<string> {
        self.demand_alive()?
        if column < 0 || column >= self.titles.len() { return err("table column is outside the list", "out_of_range") }
        return ok(self.titles[column])
    }
    pub fn width(column: int) -> Result<f64> {
        self.demand_alive()?
        if column < 0 || column >= self.widths.len() { return err("table column is outside the list", "out_of_range") }
        return ok(self.widths[column])
    }
    pub fn titles_copy() -> List<string> {
        var copy: List<string> = []
        for value: string in self.titles { copy.push(value) }
        return move copy
    }
    pub fn widths_copy() -> List<f64> {
        var copy: List<f64> = []
        for value: f64 in self.widths { copy.push(value) }
        return move copy
    }
    /// The titles of one column range, in order. Only the visible slice is
    /// built: a table of a thousand columns copies the dozen it shows.
    pub fn titles_between(first: int, last: int) -> List<string> {
        var copy: List<string> = []
        for index: int in first..last {
            if index >= 0 && index < self.titles.len() { copy.push(self.titles[index]) }
        }
        return move copy
    }
    pub fn widths_between(first: int, last: int) -> List<f64> {
        var copy: List<f64> = []
        for index: int in first..last {
            if index >= 0 && index < self.widths.len() { copy.push(self.widths[index]) }
        }
        return move copy
    }
    pub fn set_columns(count: int) -> Result<bool> {
        self.demand_alive()?
        // A bound so a wrong number does not allocate forever. It is the count
        // and not a cost: only the columns on screen are read or drawn.
        if count < 0 || count > 4096 {
            return err("a table takes up to 4096 columns, not {count}", "out_of_range")
        }
        self.clear_editor()
        self.titles = []
        self.widths = []
        for index: int in 0..count { self.titles.push(""); self.widths.push(120.0) }
        self.rebuild_lefts()
        if self.selected_column_value >= count { self.selected_column_value = -1 }
        self.revision += 1
        self.data_revision += 1
        self.clamp_scroll()
        self.dirty.layout(); self.dirty.semantics()
        return ok(true)
    }
    pub fn set_titles(values: List<string>) -> Result<bool> {
        self.set_columns(values.len())?
        for index: int in 0..values.len() { self.titles[index] = values[index] }
        self.revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn set_title(column: int, title: string) -> Result<bool> {
        self.demand_alive()?
        if column < 0 || column >= self.titles.len() { return err("table column is outside the list", "out_of_range") }
        if self.titles[column] == title { return ok(false) }
        self.titles[column] = title
        self.revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn set_width(column: int, points: f64) -> Result<bool> {
        self.demand_alive()?
        if column < 0 || column >= self.widths.len() { return err("table column is outside the list", "out_of_range") }
        if !(points > 0.0 && points < 10000000.0) { return err("invalid table column width", "out_of_range") }
        if self.widths[column] == points { return ok(false) }
        var total: f64 = points
        for index: int in 0..self.widths.len() { if index != column { total += self.widths[index] } }
        if !(total < 10000000.0) { return err("table columns exceed content width", "out_of_range") }
        self.widths[column] = points
        self.rebuild_lefts()
        self.revision += 1
        self.clamp_scroll()
        self.dirty.layout()
        return ok(true)
    }
    pub fn set_widths(values: List<f64>) -> Result<bool> {
        self.demand_alive()?
        if values.len() != self.widths.len() { return err("table widths must match columns", "out_of_range") }
        var total: f64 = 0.0
        for value: f64 in values {
            if !(value > 0.0 && value < 10000000.0) { return err("invalid table column width", "out_of_range") }
            total += value
        }
        if !(total < 10000000.0) { return err("table columns exceed content width", "out_of_range") }
        var copy: List<f64> = []
        for value: f64 in values { copy.push(value) }
        self.widths = move copy
        self.rebuild_lefts()
        self.revision += 1
        self.clamp_scroll()
        self.dirty.layout()
        return ok(true)
    }
    pub fn reset_widths() -> Result<bool> {
        self.demand_alive()?
        for index: int in 0..self.widths.len() { self.widths[index] = 120.0 }
        self.rebuild_lefts()
        self.revision += 1
        self.clamp_scroll()
        self.dirty.layout()
        return ok(true)
    }

    // ---- rows ----

    pub fn set_source(data: TableData) -> Result<bool> {
        self.demand_alive()?
        let count: int = data.row_count()
        self.validate_rows(count)?
        self.source = some(data)
        return self.apply_rows(count)
    }
    pub fn clear_source() -> Result<bool> {
        self.demand_alive()?
        self.source = none
        return self.reload()
    }
    pub fn reload() -> Result<bool> {
        self.demand_alive()?
        let count: int = match self.source { some(data) => data.row_count() none => 0 }
        self.validate_rows(count)?
        return self.apply_rows(count)
    }
    /// The bound on how many rows a table can hold.
    ///
    /// Nothing multiplies a row index by the row height to draw with any more,
    /// so the ceiling is not a coordinate limit. What is left is the scroll
    /// position, which is `rows * row_height` at the bottom and is added to in
    /// `f64`: past 4.5e14 points a double's step reaches a sixteenth of a
    /// point, and a wheel notch smaller than that would not move at all.
    fn validate_rows(count: int) -> Result<bool> {
        let extent: f64 = count as f64 * self.row_height()
        if count < 0 || !(extent < 450000000000000.0) {
            return err("{count} rows of {self.row_height() as int} points come to {extent} points of scrolling, and past 450000000000000 a scroll position stops being exact to a sixteenth of a point — about {(450000000000000.0 / self.row_height()) as int} rows at this row height",
                       "out_of_range")
        }
        return ok(true)
    }
    fn apply_rows(count: int) -> Result<bool> {
        self.rows_value = count
        if self.selected_value >= count { self.selected_value = -1 }
        if self.editing_row_value >= count { self.clear_editor() }
        self.revision += 1
        self.data_revision += 1
        self.clamp_scroll()
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn cell(row: int, column: int) -> Result<string> {
        self.demand_alive()?
        if row < 0 || row >= self.rows_value || column < 0 || column >= self.titles.len() {
            return err("table cell is outside the source", "out_of_range")
        }
        return match self.source { some(data) => ok(data.cell(row, column)) none => err("table has no source", "empty_source") }
    }

    // ---- scrolling ----

    /// How far down the rows may go before the last one sits on the bottom.
    fn max_scroll_y() -> f64 {
        let reach: f64 = self.rows_value as f64 * self.row_height() - self.body_height()
        return if reach > 0.0 { reach } else { 0.0 }
    }
    fn max_scroll_x() -> f64 {
        let reach: f64 = self.columns_width() + self.column_inset() - self.bounds.width
        return if reach > 0.0 { reach } else { 0.0 }
    }
    /// Puts the position back inside the content after its shape changed.
    fn clamp_scroll() {
        self.scroll_rows_to(self.scroll_offset())
        self.scroll_columns_to(self.left_value)
    }
    /// Moves the rows to an absolute offset, and answers whether it moved.
    fn scroll_rows_to(offset: f64) -> bool {
        let height: f64 = self.row_height()
        var next: f64 = offset
        let ceiling: f64 = self.max_scroll_y()
        if next > ceiling { next = ceiling }
        if next < 0.0 { next = 0.0 }
        var row: int = (next / height) as int
        if row < 0 { row = 0 }
        if row > self.rows_value { row = self.rows_value }
        var part: f64 = (next - row as f64 * height) / height
        // A division that landed a hair either side of the boundary would
        // otherwise show a whole row's worth of offset, which reads as a jump.
        if part < 0.0 { part = 0.0 }
        if part >= 1.0 { part = 0.0; row += 1 }
        if self.top_row == row && self.top_part == part { return false }
        self.top_row = row
        self.top_part = part
        return true
    }
    fn scroll_columns_to(offset: f64) -> bool {
        var next: f64 = offset
        let ceiling: f64 = self.max_scroll_x()
        if next > ceiling { next = ceiling }
        if next < 0.0 { next = 0.0 }
        if self.left_value == next { return false }
        self.left_value = next
        return true
    }
    /// Both axes at once, in absolute content coordinates.
    pub override fn scroll_to(offset: geometry.Point) -> Result<bool> {
        self.demand_alive()?
        if !(offset.x > -450000000000000.0 && offset.x < 450000000000000.0 &&
             offset.y > -450000000000000.0 && offset.y < 450000000000000.0) {
            return err("invalid scroll offset", "out_of_range")
        }
        var moved: bool = self.scroll_columns_to(offset.x)
        if self.scroll_rows_to(offset.y) { moved = true }
        if moved { self.dirty.paint(); self.dirty.semantics() }
        return ok(moved)
    }
    pub override fn scroll_by(dx: f64, dy: f64) -> Result<bool> {
        self.demand_alive()?
        let changed: bool = self.scroll_to(
            geometry.Point.at(self.left_value + dx, self.scroll_offset() + dy))?
        if changed { self.cancel_editor_if_outside() }
        return ok(changed)
    }

    // ---- editing ----

    pub fn set_editable_when(policy: fn(int, int) -> bool) -> Result<bool> {
        self.demand_alive()?
        self.edit_policy = some(policy)
        self.revision += 1
        self.data_revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn clear_editable() -> Result<bool> {
        self.demand_alive()?
        self.edit_policy = none
        self.clear_editor()
        self.revision += 1
        self.data_revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn editable(row: int, column: int) -> Result<bool> {
        self.demand_alive()?
        if row < 0 || row >= self.rows_value || column < 0 || column >= self.titles.len() {
            return err("table cell is outside the source", "out_of_range")
        }
        return match self.edit_policy { some(policy) => ok(policy(row, column)) none => ok(false) }
    }
    pub override fn on_cell_commit(row: int, column: int, text: string) -> Result<bool> {
        if !self.editable(row, column)? {
            self.clear_editor()
            self.revision += 1
            self.dirty.paint(); self.dirty.semantics()
            return ok(false)
        }
        self.clear_editor()
        // The source owns the value. The event handler may save `text`;
        // rereading it after the event reverts an unsaved proposal.
        self.revision += 1
        self.data_revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub override fn on_cell_cancel() -> Result<bool> { return self.cancel_edit() }
    pub fn cancel_edit() -> Result<bool> {
        self.demand_alive()?
        if self.editing_row_value < 0 { return ok(false) }
        self.clear_editor()
        self.revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    fn clear_editor() {
        self.editing_row_value = -1
        self.editing_column_value = -1
        self.focus_editor = false
    }
    pub fn begin_edit(row: int, column: int) -> Result<bool> {
        self.demand_alive()?
        if !self.editable(row, column)? { return ok(false) }
        if self.editing_row_value == row && self.editing_column_value == column { return ok(false) }
        self.editing_row_value = row
        self.editing_column_value = column
        self.selected_column_value = column
        self.focus_editor = true
        self.revision += 1
        self.ensure_visible(row)?
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    fn cancel_editor_if_outside() {
        if self.editing_row_value < 0 { return }
        let top: f64 = self.editing_row_value as f64 * self.row_height()
        let bottom: f64 = top + self.row_height()
        let view_top: f64 = self.scroll_offset()
        let view_bottom: f64 = view_top + self.body_height()
        let left: f64 = self.lefts[self.editing_column_value]
        let right: f64 = left + self.widths[self.editing_column_value]
        let view_left: f64 = self.left_value
        let view_right: f64 = view_left + self.bounds.width
        if bottom <= view_top || top >= view_bottom || right <= view_left || left >= view_right {
            self.cancel_edit()
        }
    }
    pub override fn on_dispose() {
        self.source = none
        self.edit_policy = none
        self.clear_editor()
    }

    // ---- selection ----

    pub fn select(row: int) -> Result<bool> {
        self.demand_alive()?
        if row < -1 || row >= self.rows_value { return err("table selection is outside the rows", "out_of_range") }
        if self.editing_row_value >= 0 && self.editing_row_value != row { self.cancel_edit()? }
        if self.selected_value == row { return self.ensure_visible(row) }
        self.selected_value = row
        self.revision += 1
        self.ensure_visible(row)?
        self.cancel_editor_if_outside()
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn select_column(column: int) -> Result<bool> {
        self.demand_alive()?
        if column < 0 || column >= self.titles.len() { return err("table column is outside the list", "out_of_range") }
        if self.selected_column_value == column { return ok(false) }
        self.selected_column_value = column
        let left: f64 = self.lefts[column]
        let right: f64 = left + self.widths[column]
        var next_x: f64 = self.left_value
        if left < next_x { next_x = left }
        else if right > next_x + self.bounds.width { next_x = right - self.bounds.width }
        self.scroll_to(geometry.Point.at(next_x, self.scroll_offset()))?
        self.cancel_editor_if_outside()
        self.revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    fn ensure_visible(row: int) -> Result<bool> {
        if row < 0 || self.body_height() <= 0.0 { return ok(false) }
        let body: f64 = self.body_height()
        let top: f64 = row as f64 * self.row_height()
        let bottom: f64 = top + self.row_height()
        var next: f64 = self.scroll_offset()
        if top < next { next = top }
        else if bottom > next + body { next = bottom - body }
        return self.scroll_to(geometry.Point.at(self.left_value, next))
    }

    // ---- the scrollbars ----
    //
    // Overlay, the shape macOS draws: a thumb over the content, no track under
    // it, and no room taken from the rows. The template draws it; everything
    // below is where, which is arithmetic on the logical position.

    pub fn scrollbar_thickness() -> f64 { return 9.0 }
    pub fn scrollbar_inset() -> f64 { return 2.0 }
    /// A thumb shorter than this is too small to take hold of.
    fn scrollbar_least() -> f64 { return 28.0 }

    fn rows_extent() -> f64 { return self.rows_value as f64 * self.row_height() }
    fn columns_extent() -> f64 { return self.columns_width() + self.column_inset() }

    pub fn shows_row_bar() -> bool {
        return self.body_height() > 0.0 && self.rows_extent() > self.body_height()
    }
    pub fn shows_column_bar() -> bool {
        return self.bounds.width > 0.0 && self.columns_extent() > self.bounds.width
    }

    /// The band the rows' thumb slides in, in this table's own coordinates.
    pub fn row_bar_track() -> geometry.Rect {
        let inset: f64 = self.scrollbar_inset()
        var height: f64 = self.body_height() - inset * 2.0
        if height < 0.0 { height = 0.0 }
        return geometry.Rect.of(self.bounds.width - self.scrollbar_thickness() - inset,
                                self.header_height() + inset,
                                self.scrollbar_thickness(), height)
    }
    pub fn column_bar_track() -> geometry.Rect {
        let inset: f64 = self.scrollbar_inset()
        var width: f64 = self.bounds.width - inset * 2.0
        if self.shows_row_bar() { width -= self.scrollbar_thickness() + inset }
        if width < 0.0 { width = 0.0 }
        return geometry.Rect.of(inset,
                                self.bounds.height - self.scrollbar_thickness() - inset,
                                width, self.scrollbar_thickness())
    }
    /// How long a thumb is: the share of the content on screen, never shorter
    /// than something a pointer can land on.
    fn thumb_length(track: f64, shown: f64, whole: f64) -> f64 {
        if whole <= 0.0 || shown <= 0.0 || track <= 0.0 { return 0.0 }
        var length: f64 = track * shown / whole
        if length < TableRender.least_of(track) { length = TableRender.least_of(track) }
        if length > track { length = track }
        return length
    }
    static fn least_of(track: f64) -> f64 { return if track < 28.0 { track } else { 28.0 } }

    pub fn row_thumb_length() -> f64 {
        if !self.shows_row_bar() { return 0.0 }
        return self.thumb_length(self.row_bar_track().height, self.body_height(), self.rows_extent())
    }
    pub fn column_thumb_length() -> f64 {
        if !self.shows_column_bar() { return 0.0 }
        return self.thumb_length(self.column_bar_track().width, self.bounds.width, self.columns_extent())
    }
    /// How far along its track a thumb sits. The one number that moves on every
    /// wheel notch, which is why the template carries it as a shift.
    pub fn row_thumb_at() -> f64 {
        let room: f64 = self.row_bar_track().height - self.row_thumb_length()
        let reach: f64 = self.max_scroll_y()
        if room <= 0.0 || reach <= 0.0 { return 0.0 }
        var at: f64 = room * self.scroll_offset() / reach
        if at < 0.0 { at = 0.0 }
        if at > room { at = room }
        return at
    }
    pub fn column_thumb_at() -> f64 {
        let room: f64 = self.column_bar_track().width - self.column_thumb_length()
        let reach: f64 = self.max_scroll_x()
        if room <= 0.0 || reach <= 0.0 { return 0.0 }
        var at: f64 = room * self.left_value / reach
        if at < 0.0 { at = 0.0 }
        if at > room { at = room }
        return at
    }
    /// Which thumb's track a point is in, or 0.
    fn bar_at(point: geometry.Point) -> int {
        if self.shows_row_bar() && self.row_bar_track().contains(point) { return 1 }
        if self.shows_column_bar() && self.column_bar_track().contains(point) { return 2 }
        return 0
    }
    /// Takes hold of a thumb. A press in the track away from it moves the
    /// thumb under the pointer first, which is what makes one click on a bar
    /// worth ten thousand wheel notches.
    fn take_thumb(bar: int, point: geometry.Point) {
        self.dragging = bar
        if bar == 1 {
            let track: geometry.Rect = self.row_bar_track()
            let length: f64 = self.row_thumb_length()
            let at: f64 = track.y + self.row_thumb_at()
            if point.y >= at && point.y < at + length { self.grab = point.y - at }
            else { self.grab = length / 2.0; self.drag_to(point) }
            return
        }
        let track: geometry.Rect = self.column_bar_track()
        let length: f64 = self.column_thumb_length()
        let at: f64 = track.x + self.column_thumb_at()
        if point.x >= at && point.x < at + length { self.grab = point.x - at }
        else { self.grab = length / 2.0; self.drag_to(point) }
    }
    fn drag_to(point: geometry.Point) {
        if self.dragging == 1 {
            let track: geometry.Rect = self.row_bar_track()
            let room: f64 = track.height - self.row_thumb_length()
            if room <= 0.0 { return }
            var at: f64 = point.y - self.grab - track.y
            if at < 0.0 { at = 0.0 }
            if at > room { at = room }
            self.scroll_to(geometry.Point.at(self.left_value, room_share(at, room) * self.max_scroll_y()))
            return
        }
        if self.dragging != 2 { return }
        let track: geometry.Rect = self.column_bar_track()
        let room: f64 = track.width - self.column_thumb_length()
        if room <= 0.0 { return }
        var at: f64 = point.x - self.grab - track.x
        if at < 0.0 { at = 0.0 }
        if at > room { at = room }
        self.scroll_to(geometry.Point.at(room_share(at, room) * self.max_scroll_x(), self.scroll_offset()))
    }

    // ---- drawing, hit testing, events ----

    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        var width: f64 = self.columns_width() + self.column_inset()
        if width < 120.0 { width = 120.0 }
        return ok(geometry.Size.of(width, 180.0))
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> {
        super.paint_self(canvas)?
        canvas.save()?
        canvas.clip(geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height), 0.0)?
        self.paint_template(canvas)?
        canvas.restore()?
        return ok(true)
    }
    /// A click on a table is arithmetic, not a search.
    ///
    /// The template is a band of labels — a thousand of them on a wide table —
    /// and walking them to find which one the pointer is over cost more than
    /// drawing the frame. Nothing in a table's template takes focus except the
    /// one open cell editor, so that is the only thing worth looking for, and
    /// everything else is the table itself answering for its own box.
    pub override fn hit_test(point: geometry.Point) -> Option<RenderObject> {
        if !self.alive || self.hidden || !self.enabled { return none }
        let local: geometry.Point = geometry.Point.at(point.x - self.bounds.x, point.y - self.bounds.y)
        if !geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height).contains(local) { return none }
        // A scrollbar is over the content, so it is asked about first: an open
        // editor in the last visible column would otherwise take a press meant
        // for the thumb sitting on top of it.
        if self.bar_at(local) != 0 { return some(self) }
        if self.editing_row_value >= 0 {
            match self.template_visual {
                some(visual) => {
                    let offset: geometry.Point = self.visual_offset()
                    match visual.hit_test(geometry.Point.at(local.x - offset.x, local.y - offset.y)) {
                        some(part) => { if part.is_focusable() { return some(part) } }
                        none => {}
                    }
                }
                none => {}
            }
        }
        return some(self)
    }
    fn select_as_user(row: int) -> Option<input.UiEvent> {
        if row == self.selected_value {
            if self.editing_row_value >= 0 && self.editing_row_value != row { self.cancel_edit() }
            return none
        }
        match self.select(row) {
            ok(changed) => {
                if !changed { return none }
                let event: input.UiEvent = input.UiEvent.of(input.EventKind.selection, platform.Handle.of(self.identity))
                event.index = row
                return some(event)
            }
            err(_) => { return none }
        }
    }
    /// The logical column under a point in this table's own coordinates.
    fn column_at(x: f64) -> int {
        return self.column_containing(x + self.left_value - self.column_inset())
    }
    /// The logical row under a point in this table's own coordinates, or -1
    /// above the first row or past the last.
    fn row_at(y: f64) -> int {
        let height: f64 = self.row_height()
        let down: f64 = y - self.header_height() + self.row_fraction()
        if down < 0.0 { return -1 }
        let row: int = self.top_row + (down / height) as int
        if row < 0 || row >= self.rows_value { return -1 }
        return row
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT {
            let bar: int = self.bar_at(event.position)
            if bar != 0 { self.take_thumb(bar, event.position); return none }
            self.tracking = true
            return none
        }
        if event.kind == input.EventKind.pointer_move && self.dragging != 0 {
            self.drag_to(event.position)
            return none
        }
        if event.kind == input.EventKind.pointer_up {
            if self.dragging != 0 { self.dragging = 0; self.tracking = false; return none }
            let was_tracking: bool = self.tracking
            self.tracking = false
            if was_tracking && event.index == platform.BTN_LEFT &&
               geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height).contains(event.position) &&
               event.position.y >= self.header_height() {
                let row: int = self.row_at(event.position.y)
                if row < 0 { return none }
                let column: int = self.column_at(event.position.x)
                if column >= 0 { self.select_column(column) }
                let selection: Option<input.UiEvent> = self.select_as_user(row)
                if event.click_count() >= 2 {
                    if column >= 0 { self.begin_edit(row, column) }
                }
                return selection
            }
        }
        if event.kind == input.EventKind.key_down && self.rows_value > 0 {
            if event.key() == input.Key.down { return self.select_as_user(if self.selected_value + 1 < self.rows_value { self.selected_value + 1 } else { self.selected_value }) }
            if event.key() == input.Key.up { return self.select_as_user(if self.selected_value > 0 { self.selected_value - 1 } else { 0 }) }
            if event.key() == input.Key.right && self.titles.len() > 0 {
                let column: int = if self.selected_column_value < 0 { 0 }
                                    else if self.selected_column_value + 1 < self.titles.len() { self.selected_column_value + 1 }
                                    else { self.selected_column_value }
                self.select_column(column)
                return none
            }
            if event.key() == input.Key.left && self.titles.len() > 0 {
                let column: int = if self.selected_column_value < 0 { self.titles.len() - 1 }
                                    else if self.selected_column_value > 0 { self.selected_column_value - 1 }
                                    else { 0 }
                self.select_column(column)
                return none
            }
            if event.key() == input.Key.ret {
                let row: int = if self.selected_value >= 0 { self.selected_value } else { 0 }
                if self.selected_column_value >= 0 {
                    match self.editable(row, self.selected_column_value) {
                        ok(yes) => { if yes { self.begin_edit(row, self.selected_column_value); return self.select_as_user(row) } }
                        err(_) => {}
                    }
                } else {
                    for column: int in 0..self.titles.len() {
                        match self.editable(row, column) {
                            ok(yes) => { if yes { self.begin_edit(row, column); return self.select_as_user(row) } }
                            err(_) => {}
                        }
                    }
                }
            }
        }
        return none
    }
    pub override fn focus_changed(focused: bool) {
        super.focus_changed(focused)
        if !focused { self.tracking = false; self.dragging = 0 }
    }
}
