package compose

import latte.controls
import latte.geometry
import latte.platform
import latte.scene

/// One materialized row: the logical row it stands for, where it sits in the
/// body strip, and only the cells of the columns on screen.
pub class TableVisibleRow {
    /// The row in the source, not the position in `rows`.
    pub index: int
    /// Its top, measured from the top of the table and never from row zero:
    /// `header + (index - first visible row) * row_height`. See `TableRender`.
    pub top: f64
    /// The visible column slice, in column order, starting at `first_column`.
    pub cells: List<string>
    pub selected: bool
    pub fn init(index: int, top: f64, move cells: List<string>, selected: bool) {
        self.index = index; self.top = top; self.selected = selected
        self.cells = move cells
    }
}

/// The shape a `.bx` table template is handed.
///
/// **Both axes are virtual.** A template is given the rows on screen and, of
/// each of those rows, only the columns on screen — so what it costs to draw a
/// table is the size of the window and not the size of the data. Two indexes
/// are therefore not the same number and must not be confused: `row.index` and
/// `first_column + i` are the *logical* ones, which keys, callbacks, selection
/// and editing all use, while the position in `rows` and in `cells` is where
/// it happens to sit in the slice this frame.
///
/// **A scroll of less than one row does not come through here at all.** The
/// rows and the header carry a paint-time shift, and moving it is the whole of
/// a fractional scroll: no render, no diff, no layout, no reshaping. A render
/// is asked for only when the visible rectangle changes, which is when there
/// is something new to show.
pub abstract class TableControlTemplate extends ControlTemplate {
    /// The titles of the visible columns, starting at `first_column`.
    pub titles: List<string> = []
    /// Their widths, in the same order.
    pub widths: List<f64> = []
    pub rows: List<TableVisibleRow> = []
    /// The logical column `titles[0]`, `widths[0]` and `cells[0]` stand for.
    pub first_column: int = 0
    pub total_rows: int = 0
    pub total_columns: int = 0
    /// The content width: every column, or the box if that is wider.
    pub total_width: f64 = 0.0
    /// Where the visible column strip starts, and how much room it has.
    pub strip_x: f64 = 0.0
    pub strip_width: f64 = 0.0
    /// The gap before the first column, the table's own number so a click and
    /// a cell agree about where a column begins.
    pub column_inset: f64 = 6.0
    /// The two overlay scrollbars. A thumb's length is its share of the
    /// content and changes only with the shape; where it sits changes on every
    /// wheel notch, and so travels as a shift like the rows do — not as an
    /// attribute, which would mean a render for a scroll of one point.
    pub bar_thickness: f64 = 9.0
    pub row_bar_x: f64 = 0.0
    pub row_bar_y: f64 = 0.0
    pub row_bar_height: f64 = 0.0
    pub row_thumb_height: f64 = 0.0
    pub column_bar_x: f64 = 0.0
    pub column_bar_y: f64 = 0.0
    pub column_bar_width: f64 = 0.0
    pub column_thumb_width: f64 = 0.0
    pub revision: int = -1
    pub editing_row: int = -1
    /// Logical, like every other column number a template reads.
    pub editing_column: int = -1
    pub selected_column: int = -1
    data_revision: int = -1
    first_row: int = -1
    last_row: int = -1
    held_first_column: int = -1
    held_last_column: int = -1
    viewport_height: f64 = -1.0
    viewport_width: f64 = -1.0
    /// The two theme measurements the row positions were worked out from.
    /// `ControlTemplate.update` has already copied the new ones into
    /// `row_height` and `header_height` by the time this class looks, so a
    /// tighter or looser appearance is only visible by keeping the old pair.
    held_row_height: f64 = -1.0
    held_header_height: f64 = -1.0
    /// The two bands the scroll moves: the rows, and the column strip inside
    /// the header. Found once by key — see `adopt_bands`.
    body: Option<scene.RenderObject> = none
    header: Option<scene.RenderObject> = none
    row_bar: Option<scene.RenderObject> = none
    column_bar: Option<scene.RenderObject> = none
    /// Set when a rebuild happened, so the controls it made are told which
    /// logical cell they stand for once they exist.
    stamp_wanted: bool = false

    pub fn init() { super.init() }

    /// How far past the viewport cells are kept, so a wheel notch has
    /// something to show before the next render catches up.
    pub static fn row_overscan() -> int { return 2 }
    pub static fn column_overscan() -> int { return 1 }

    /// The two nodes a scroll moves, taken from the template's own render by
    /// the keys `body` and `header`.
    ///
    /// A template calls this from `on_mount`. Without it a table still draws
    /// correctly — every scroll simply costs a render, which is what this
    /// exists to avoid — so a template that does not is slow and never wrong.
    pub fn adopt_bands(body: Option<controls.Widget>, header: Option<controls.Widget>,
                       row_bar: Option<controls.Widget>, column_bar: Option<controls.Widget>) {
        self.body = TableControlTemplate.object_of(body)
        self.header = TableControlTemplate.object_of(header)
        self.row_bar = TableControlTemplate.object_of(row_bar)
        self.column_bar = TableControlTemplate.object_of(column_bar)
    }

    static fn object_of(widget: Option<controls.Widget>) -> Option<scene.RenderObject> {
        match widget {
            some(control) => {
                match control.render_object() {
                    ok(node) => { return some(node) }
                    err(_) => { return none }
                }
            }
            none => { return none }
        }
    }

    /// Tells the cells a render just made where they are in the table.
    ///
    /// A reader is given the rows on screen, so without this it would count
    /// them and say "row 3 of 12" in the middle of ten million. The numbers
    /// are one-based, because that is what `aria-rowindex` and
    /// `aria-colindex` are; `TableRender` supplies the two totals.
    pub override fn after_render(root: scene.RenderObject) {
        if !self.stamp_wanted { return }
        self.stamp_wanted = false
        match self.body { some(band) => { self.stamp_rows(band) } none => {} }
        match self.header { some(band) => { self.stamp_header(band) } none => {} }
    }

    fn stamp_rows(band: scene.RenderObject) {
        if !band.is_alive() { return }
        for index: int in 0..band.child_count() {
            if index >= self.rows.len() { return }
            match band.child_at(index) {
                some(row) => {
                    let held: TableVisibleRow = self.rows[index]
                    row.set_grid_place("row", held.index + 1, 0)
                    for slot: int in 0..row.child_count() {
                        match row.child_at(slot) {
                            some(cell) => {
                                cell.set_grid_place("cell", held.index + 1,
                                                    self.first_column + slot + 1)
                            }
                            none => {}
                        }
                    }
                }
                none => {}
            }
        }
    }

    fn stamp_header(band: scene.RenderObject) {
        if !band.is_alive() { return }
        match band.child_at(0) {
            some(strip) => {
                for slot: int in 0..strip.child_count() {
                    match strip.child_at(slot) {
                        some(title) => {
                            title.set_grid_place("columnheader", 0,
                                                 self.first_column + slot + 1)
                        }
                        none => {}
                    }
                }
            }
            none => {}
        }
    }

    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        platform.Probe.instance.enter(platform.PHASE_SOURCE)
        defer platform.Probe.instance.leave(platform.PHASE_SOURCE)
        match control as? scene.TableRender {
            some(table) => { self.follow(table) }
            none => {}
        }
    }

    /// Moves the two bands. This is a scroll that stays inside the rows and
    /// columns already on screen: a transform and a repaint, nothing else.
    fn move_bands(table: scene.TableRender, left: f64, fraction: f64) {
        TableControlTemplate.shift(self.body, -left, -fraction)
        TableControlTemplate.shift(self.header, -left, 0.0)
        TableControlTemplate.shift(self.row_bar, 0.0, table.row_thumb_at())
        TableControlTemplate.shift(self.column_bar, table.column_thumb_at(), 0.0)
    }

    static fn shift(node: Option<scene.RenderObject>, x: f64, y: f64) {
        match node {
            some(found) => {
                if found.is_alive() { found.set_shift(geometry.Point.at(x, y)) }
            }
            none => {}
        }
    }

    fn follow(table: scene.TableRender) {
        let box: geometry.Rect = table.frame()
        let row_height: f64 = table.row_height()
        let header_height: f64 = table.header_height()
        if row_height <= 0.0 { return }
        let first_row: int = table.first_visible_row()
        let fraction: f64 = table.row_fraction()
        let left: f64 = table.scroll_x()

        self.move_bands(table, left, fraction)
        platform.Probe.instance.note(platform.TALLY_LIVE_CELLS,
                                     self.rows.len() * (self.held_last_column - self.held_first_column))

        // Not from the fraction: a range that grew mid-row would make a
        // scroll of less than a row rebuild the cells after all.
        var last_row: int = first_row +
            ((box.height - header_height) / row_height) as int + 1 +
            TableControlTemplate.row_overscan()
        if last_row > table.row_count() { last_row = table.row_count() }
        if last_row < first_row { last_row = first_row }

        let columns: int = table.column_count()
        var first_column: int = table.column_reaching(left) - TableControlTemplate.column_overscan()
        if first_column < 0 { first_column = 0 }
        var last_column: int = table.column_reaching(left + box.width) + 1 +
            TableControlTemplate.column_overscan()
        if last_column > columns { last_column = columns }
        if last_column < first_column { last_column = first_column }

        let data_changed: bool = self.data_revision != table.data_version()
        let chrome_changed: bool = self.revision != table.version() ||
                                   self.viewport_width != box.width ||
                                   self.viewport_height != box.height ||
                                   self.held_row_height != row_height ||
                                   self.held_header_height != header_height
        if !data_changed && !chrome_changed &&
           first_row == self.first_row && last_row == self.last_row &&
           first_column == self.held_first_column && last_column == self.held_last_column {
            return
        }

        self.revision = table.version()
        self.data_revision = table.data_version()
        self.viewport_width = box.width
        self.viewport_height = box.height
        self.editing_row = table.editing_row()
        self.editing_column = table.editing_column()
        self.selected_column = table.selected_column()
        self.total_rows = table.row_count()
        self.total_columns = columns
        self.row_height = row_height
        self.header_height = header_height
        self.held_row_height = row_height
        self.held_header_height = header_height
        self.column_inset = table.column_inset()
        self.total_width = box.width
        let content_width: f64 = table.columns_width() + self.column_inset
        if content_width > self.total_width { self.total_width = content_width }
        self.strip_x = table.column_left(first_column) - self.column_inset
        self.strip_width = self.total_width - self.strip_x
        self.bar_thickness = table.scrollbar_thickness()
        let row_track: geometry.Rect = table.row_bar_track()
        self.row_bar_x = row_track.x
        self.row_bar_y = row_track.y
        self.row_bar_height = row_track.height
        self.row_thumb_height = table.row_thumb_length()
        let column_track: geometry.Rect = table.column_bar_track()
        self.column_bar_x = column_track.x
        self.column_bar_y = column_track.y
        self.column_bar_width = column_track.width
        self.column_thumb_width = table.column_thumb_length()
        self.titles = table.titles_between(first_column, last_column)
        self.widths = table.widths_between(first_column, last_column)

        self.rows = self.gather(table, first_row, last_row, first_column, last_column,
                                data_changed, header_height, row_height)
        self.first_row = first_row
        self.last_row = last_row
        self.held_first_column = first_column
        self.held_last_column = last_column
        self.first_column = first_column
        platform.Probe.instance.note(platform.TALLY_LIVE_CELLS,
                                     self.rows.len() * (last_column - first_column))
        table.note_rebuild()
        self.stamp_wanted = true
        self.request_render()
    }

    /// The rows the next render draws, reusing every cell that was on screen
    /// before and reading only the ones that were not.
    fn gather(table: scene.TableRender, first_row: int, last_row: int,
              first_column: int, last_column: int, data_changed: bool,
              header_height: f64, row_height: f64) -> List<TableVisibleRow> {
        var built: List<TableVisibleRow> = []
        let selected: int = table.selected()
        var reads: int = 0
        for row: int in first_row..last_row {
            let top: f64 = header_height + (row - first_row) as f64 * row_height
            var cells: List<string> = []
            // Where this row sat a frame ago, by arithmetic: searching the
            // held list was a scan per row per frame.
            let was: int = row - self.first_row
            var reused: bool = false
            if !data_changed && was >= 0 && was < self.rows.len() &&
               self.rows[was].index == row {
                let held: TableVisibleRow = self.rows[was]
                for column: int in first_column..last_column {
                    let inside: int = column - self.held_first_column
                    if inside >= 0 && inside < held.cells.len() {
                        cells.push(held.cells[inside])
                    } else {
                        cells.push(table.cell(row, column).expect("visible table cell"))
                        reads += 1
                    }
                }
                reused = true
            }
            if !reused {
                for column: int in first_column..last_column {
                    cells.push(table.cell(row, column).expect("visible table cell"))
                    reads += 1
                }
            }
            built.push(new TableVisibleRow(row, top, move cells, selected == row))
        }
        platform.Probe.instance.count(platform.TALLY_CELL_READS, reads)
        return move built
    }
}
