// The virtual table: does it really only read what it shows? Twenty rows is
// twenty cell reads, a part-row scroll is none, and one editor is open.
package main

import std.io
import latte.compose
import latte.controls
import latte.geometry
import latte.headless
import latte.input
import latte.scene
import latte.stage

/// Ten thousand rows that are not in memory, counting every read.
pub class CountedRows implements controls.TableRows {
    pub reads: int = 0
    edits: Map<int, string> = {}

    pub fn init() {}

    pub fn row_count() -> int { return 10000 }

    pub fn cell(row: int, column: int) -> string {
        self.reads = self.reads + 1
        if column == 0 { return "Order {row}" }
        return match self.edits.get(row) {
            some(value) => value,
            none => "Cup {row % 3}",
        }
    }

    pub fn save(row: int, text: string) { self.edits[row] = text }
}

pub class Orders extends compose.Component {
    pub rows: CountedRows
    pub titles: List<string> = ["Order", "Cup"]
    pub widths: List<f64> = [200.0, 180.0]
    pub policy: compose.TableEditRule
    pub committed: string = "none"

    pub fn init() {
        self.rows = new CountedRows()
        self.policy = new compose.TableEditRule(fn(row: int, column: int) -> bool {
            return column == 1
        })
        super.init()
    }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 0.0)
        b.open("Table")
        b.key("orders")
        b.columns(self.titles)
        b.column_widths(self.widths)
        b.table_source(self.rows)
        b.editable_when(self.policy)
        b.number("height", 300.0)
        b.on("commit", fn(e: input.UiEvent) {
            self.rows.save(e.index, e.text)
            self.committed = "row {e.index} column {e.token}: {e.text}"
        })
        b.close()
        b.close()
    }
}


/// Two hundred columns and ten million rows, none of it in memory. `reads`
/// counts every cell the table asks for, which is the only honest measure of
/// what a virtual table costs: a table that is virtual in one axis only still
/// reads two hundred cells to draw a row of a dozen.
pub class WideRows implements controls.TableRows {
    pub reads: int = 0
    pub fn init() {}
    pub fn row_count() -> int { return 10000000 }
    pub fn cell(row: int, column: int) -> string {
        self.reads = self.reads + 1
        if column == 0 { return "Order {row}" }
        return "{(row + column * 7) % 1000}"
    }
}

pub class WideOrders extends compose.Component {
    pub rows: WideRows
    pub titles: List<string> = []
    pub widths: List<f64> = []
    pub policy: compose.TableEditRule
    pub committed: string = "none"

    pub fn init() {
        self.rows = new WideRows()
        for index: int in 0..200 {
            self.titles.push("C{index}")
            self.widths.push(60.0)
        }
        self.policy = new compose.TableEditRule(fn(row: int, column: int) -> bool {
            return column == 1
        })
        super.init()
    }

    pub override fn render(b: compose.Builder) {
        b.open("VStack")
        b.number("padding", 0.0)
        b.open("Table")
        b.key("wide")
        b.columns(self.titles)
        b.column_widths(self.widths)
        b.table_source(self.rows)
        b.editable_when(self.policy)
        b.number("height", 300.0)
        b.on("commit", fn(e: input.UiEvent) {
            self.committed = "row {e.index} column {e.token}: {e.text}"
        })
        b.close()
        b.close()
    }
}

/// The largest distance from the table's own origin that any node in its
/// template is laid out at. It is what says the coordinates a scrolled table
/// hands layout and Skia are the viewport's and not the data's.
fn deepest_y(node: scene.RenderObject, above: f64) -> f64 {
    var reach: f64 = above + node.frame().y
    var worst: f64 = if reach < 0.0 { -reach } else { reach }
    let inside: geometry.Point = node.child_offset()
    for index: int in 0..node.child_count() {
        match node.child_at(index) {
            some(child) => {
                let below: f64 = deepest_y(child, reach + inside.y)
                if below > worst { worst = below }
            }
            none => {}
        }
    }
    return worst
}

fn template_reach(table: scene.TableRender) -> f64 {
    match table.visual() {
        some(root) => { return deepest_y(root, 0.0) }
        none => { return -1.0 }
    }
}

fn wide_table_of(page: stage.Scene) -> scene.TableRender {
    match find_table(page.root().render_object().expect("root")) {
        some(table) => { return table }
        none => { panic("no table in the scene") }
    }
}

fn table_of(page: stage.Scene) -> scene.TableRender {
    for node: scene.RenderObject in [page.root().render_object().expect("root")] {
        let found: Option<scene.TableRender> = find_table(node)
        match found {
            some(table) => { return table }
            none => {}
        }
    }
    panic("no table in the scene")
}

fn find_table(node: scene.RenderObject) -> Option<scene.TableRender> {
    match node as? scene.TableRender {
        some(table) => { return some(table) }
        none => {}
    }
    for index: int in 0..node.child_count() {
        match node.child_at(index) {
            some(child) => {
                match find_table(child) {
                    some(table) => { return some(table) }
                    none => {}
                }
            }
            none => {}
        }
    }
    return none
}

fn rule(title: string) {
    io.println("")
    io.println("== {title} ==")
}

pub extern "C" fn run() -> i32 as "latte_table_run" {
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(500.0, 400.0))
    let orders: Orders = new Orders()
    page.show(orders).expect("show the table")
    let table: scene.TableRender = table_of(page)

    rule("1 — drawing twenty rows costs twenty rows, not ten thousand")

    io.println("rows in the source: {table.row_count()}")
    // Two columns times the rows that fit in 300 points, plus the overscan a
    // scroll needs. The number that matters is that it is in the tens.
    let first: int = orders.rows.reads
    io.println("cell reads under a hundred: {first < 100}")
    io.println("cell reads over zero: {first > 0}")

    rule("2 — a second frame with nothing changed reads nothing")

    // The visible-row cache: re-reading the source every frame is 60 reads a
    // second per visible cell, which a database-backed source would feel.
    page.refresh().expect("refresh")
    io.println("reads after an idle frame: {orders.rows.reads - first}")

    rule("3 — scrolling by less than a row reads nothing new")

    let before_fraction: int = orders.rows.reads
    page.scroll(geometry.Point.at(100.0, 100.0), 0.0, 4.0).expect("scroll")
    let table_offset: f64 = table.scroll_offset()
    // It really moved — a scroll that clamped to where it already was would
    // read nothing for the uninteresting reason.
    io.println("offset moved to {table_offset}")
    io.println("reads after a four-point scroll: {orders.rows.reads - before_fraction}")

    rule("4 — scrolling a whole page reads about a page")

    let before_page: int = orders.rows.reads
    // Down the content is a positive delta, which is what `deltaY` already is.
    // Negating it scrolls backwards, and a list at the top just sits still.
    page.scroll(geometry.Point.at(100.0, 100.0), 0.0, 600.0).expect("scroll")
    io.println("offset after scrolling down 600: {table.scroll_offset()}")
    let paged: int = orders.rows.reads - before_page
    io.println("reads after a 600-point scroll are under two hundred: {paged < 200}")
    io.println("and over zero: {paged > 0}")

    rule("4b — and scrolling back up is the other sign")

    page.scroll(geometry.Point.at(100.0, 100.0), 0.0, -600.0).expect("scroll")
    io.println("offset after scrolling back: {table.scroll_offset()}")

    rule("5 — one editor at a time")

    table.select(0).expect("select a row")
    table.begin_edit(0, 1).expect("edit the first row")
    io.println("editing row {table.editing_row()} column {table.editing_column()}")
    // A second begin_edit moves the editor rather than opening another.
    table.begin_edit(3, 1).expect("edit another row")
    io.println("after a second edit: row {table.editing_row()} column {table.editing_column()}")

    rule("6 — Return commits and Escape cancels")

    table.begin_edit(5, 1).expect("edit row five")
    page.context().actions(table.handle()).commit_cell(5, 1, "Espresso").expect("commit")
    io.println("committed: {orders.committed}")
    io.println("the source kept it: {orders.rows.cell(5, 1)}")
    io.println("editor after commit: row {table.editing_row()}")

    table.begin_edit(6, 1).expect("edit row six")
    table.cancel_edit().expect("cancel")
    io.println("editor after cancel: row {table.editing_row()}")
    io.println("row six is unchanged: {orders.rows.cell(6, 1)}")

    rule("7 — a column the policy refuses cannot be edited")

    io.println("column 0 editable: {table.editable(2, 0).expect("ask")}")
    io.println("column 1 editable: {table.editable(2, 1).expect("ask")}")

    page.close()
    wide()
    return 0
}

/// Two hundred columns and ten million rows: both axes virtual, and the
/// coordinates the scene is given are the viewport's.
fn wide() {
    let page: stage.Scene = new stage.Scene(new headless.MetricRenderer(),
                                            geometry.Size.of(500.0, 400.0))
    let orders: WideOrders = new WideOrders()
    page.show(orders).expect("show a wide table")
    let table: scene.TableRender = wide_table_of(page)

    let row_height: f64 = table.row_height()
    let body_rows: int = (table.body_height() / row_height) as int

    rule("8 — a wide table reads the columns it shows, not the ones it has")

    io.println("columns in the table: {table.column_count()}")
    io.println("rows in the source: {table.row_count()}")
    // Sixty-point columns in a 500-point box is nine of them, plus the
    // overscan. Two hundred would be the whole table's width.
    let first_draw: int = orders.rows.reads
    io.println("cells read to draw it: under a quarter of one row per column: {first_draw < 200 * 4}")
    io.println("and it really drew rows: {first_draw > body_rows}")
    io.println("reads per row are near the columns on screen: {first_draw / (body_rows + 3) < 20}")

    rule("9 — ten million rows, and nothing draws at ten million points")

    io.println("first visible row: {table.first_visible_row()}")
    io.println("template reaches under a viewport and a row: {template_reach(table) < 400.0 + row_height}")

    // The bottom of ten million rows. The scroll position is a big number and
    // the geometry is not, which is the whole of the logical-row design.
    table.scroll_to(geometry.Point.at(0.0, 239999728.0)).expect("scroll to the end")
    page.refresh().expect("refresh")
    io.println("scrolled to {table.scroll_offset() as int}")
    io.println("first visible row is near the last: {table.first_visible_row() > 9999970}")
    io.println("template still reaches under a viewport and a row: {template_reach(table) < 400.0 + row_height}")
    io.println("the last row is the last: {table.cell(table.row_count() - 1, 0).expect("cell")}")

    rule("10 — a scroll of less than a row is a transform, not a render")

    table.scroll_to(geometry.Point.at(0.0, 24000.0)).expect("scroll back")
    page.refresh().expect("refresh")
    let settled_reads: int = orders.rows.reads
    let settled_builds: int = table.rebuild_count()
    var step: int = 0
    // Ten wheel notches of a point each, from a row boundary: every one of
    // them lands inside the row that is already on screen.
    for step: int in 0..10 { page.scroll(geometry.Point.at(100.0, 200.0), 0.0, 1.0).expect("scroll") }
    io.println("offset moved by ten: {table.scroll_offset() - 24000.0}")
    io.println("cells read: {orders.rows.reads - settled_reads}")
    io.println("times the cells were rebuilt: {table.rebuild_count() - settled_builds}")

    rule("11 — crossing a row boundary reads the row that entered, and no more")

    table.scroll_to(geometry.Point.at(0.0, 24000.0)).expect("scroll back")
    page.refresh().expect("refresh")
    let before_row: int = orders.rows.reads
    let before_builds: int = table.rebuild_count()
    page.scroll(geometry.Point.at(100.0, 200.0), 0.0, row_height).expect("scroll one row")
    let crossed: int = orders.rows.reads - before_row
    io.println("rows moved by one: {table.first_visible_row() - 1000}")
    io.println("cells read is one row of what is on screen: {crossed > 0 && crossed < 20}")
    io.println("times the cells were rebuilt: {table.rebuild_count() - before_builds}")

    rule("12 — scrolling sideways reads the columns that entered, and no more")

    let before_column: int = orders.rows.reads
    page.scroll(geometry.Point.at(100.0, 200.0), 60.0, 0.0).expect("scroll one column")
    let entered: int = orders.rows.reads - before_column
    io.println("moved sideways by one column: {table.scroll_x()}")
    io.println("cells read is about one column of rows: {entered > 0 && entered <= (body_rows + 4) * 2}")
    io.println("and not a whole screen of them: {entered < (body_rows + 4) * 6}")

    rule("13 — a click lands on the row and column under it, after both scrolls")

    // Row 1001 is the second one on screen; the pointer is aimed at the middle
    // of its band, and at the third column from the left edge of the content.
    let header: f64 = table.header_height()
    let aim_y: f64 = header + row_height * 1.5 - table.row_fraction()
    page.pointer(input.EventKind.pointer_down, geometry.Point.at(200.0, aim_y), 1, 1, 0).expect("press")
    page.pointer(input.EventKind.pointer_up, geometry.Point.at(200.0, aim_y), 1, 1, 0).expect("release")
    io.println("selected row: {table.selected()}")
    // 200 points across, 60 wide, one column of horizontal scroll and a six
    // point inset: (200 + 60 - 6) / 60 = column 4.
    io.println("selected column: {table.selected_column()}")

    rule("14 — one editor, at the logical cell, however far the table has moved")

    table.select_column(1).expect("column one")
    table.begin_edit(1001, 1).expect("edit a cell")
    io.println("editing row {table.editing_row()} column {table.editing_column()}")
    page.context().actions(table.handle()).commit_cell(table.editing_row(), table.editing_column(), "Latte")
        .expect("commit")
    io.println("committed: {orders.committed}")
    io.println("editor after commit: row {table.editing_row()}")

    rule("15 — the keyboard moves through a million rows")

    table.select(5000000).expect("select the middle")
    page.refresh().expect("refresh")
    io.println("selected row five million is on screen: {table.first_visible_row() <= 5000000 && table.first_visible_row() + body_rows + 2 > 5000000}")
    io.println("template reaches under a viewport and a row: {template_reach(table) < 400.0 + row_height}")
    page.key(input.EventKind.key_down, input.Key.down, "", 0).expect("down")
    io.println("down moved the selection to {table.selected()}")
    page.key(input.EventKind.key_down, input.Key.right, "", 0).expect("right")
    io.println("right moved the column to {table.selected_column()}")

    rule("16 — a click that arrives before the frame the scroll asked for")

    // A wheel is applied without drawing and the frame comes later. A click in
    // between must land where the pixels are about to be, not where they were.
    table.scroll_to(geometry.Point.at(0.0, 24000.0)).expect("scroll back")
    table.select(-1).expect("clear the selection")
    page.refresh().expect("refresh")
    page.apply_scroll(geometry.Point.at(100.0, 200.0), 0.0, row_height * 3.0).expect("wheel")
    let aim_again: f64 = header + row_height * 0.5 - table.row_fraction()
    page.pointer(input.EventKind.pointer_down, geometry.Point.at(200.0, aim_again), 1, 1, 0).expect("press")
    page.pointer(input.EventKind.pointer_up, geometry.Point.at(200.0, aim_again), 1, 1, 0).expect("release")
    io.println("three rows down from row 1000, clicked the top row: {table.selected()}")

    rule("17 — a resize and a denser theme move the rows with them")

    // The table is 300 points tall whatever the window is, so a wider window
    // is what changes what it shows: more columns reach the right edge.
    let wide_builds: int = table.rebuild_count()
    let wide_reads: int = orders.rows.reads
    page.resize(geometry.Size.of(900.0, 400.0), 1.0).expect("resize")
    io.println("a wider window rebuilt the cells: {table.rebuild_count() > wide_builds}")
    io.println("and read the columns that came into view: {orders.rows.reads > wide_reads}")
    io.println("the rows still reach no further than the table: {template_reach(table) < 300.0 + row_height}")

    let dense_builds: int = table.rebuild_count()
    page.context().theme().set_control_size(0).expect("a denser appearance")
    page.refresh().expect("refresh")
    io.println("row height moved to {table.row_height()}")
    io.println("the denser appearance rebuilt the cells: {table.rebuild_count() > dense_builds}")
    io.println("the first row sits at {row_top_of_first(table)} under a {table.header_height()} point header")

    // Short enough that the appearance cannot change how many rows fit, so
    // only the row height itself says the positions are stale.
    table.set_source(new FewRows()).expect("three rows")
    page.refresh().expect("refresh")
    let short_builds: int = table.rebuild_count()
    page.context().theme().set_control_size(2).expect("the regular appearance")
    page.refresh().expect("refresh")
    io.println("three rows, and the header is {table.header_height()} points again")
    io.println("the cells were rebuilt for the row height alone: {table.rebuild_count() > short_builds}")
    io.println("the first of three rows sits at {row_top_of_first(table)}")

    rule("18 — a table that cannot scroll further says so, and the page scrolls")

    // What a nested scroll turns on: `scroll_by` answers false at an edge, and
    // the input manager then offers the wheel to whatever contains the table.
    table.set_source(new TallRows()).expect("ten million rows again")
    table.scroll_to(geometry.Point.at(0.0, 0.0)).expect("to the top")
    io.println("up at the top: {table.scroll_by(0.0, -40.0).expect("wheel")}")
    io.println("down at the top: {table.scroll_by(0.0, 40.0).expect("wheel")}")
    table.scroll_to(geometry.Point.at(0.0, 239999728.0)).expect("to the bottom")
    io.println("down at the bottom: {table.scroll_by(0.0, 40.0).expect("wheel")}")
    table.scroll_to(geometry.Point.at(0.0, 0.0)).expect("to the top")
    io.println("left at the left edge: {table.scroll_by(-40.0, 0.0).expect("wheel")}")
    io.println("and a sideways wheel that can move does: {table.scroll_by(40.0, 0.0).expect("wheel")}")

    rule("19 — a reader is told the whole table, not the dozen rows on screen")

    table.set_source(new TallRows()).expect("ten million rows")
    table.scroll_to(geometry.Point.at(0.0, 120000.0)).expect("five thousand rows down")
    page.refresh().expect("refresh")
    let tree: List<scene.SemanticsNode> = page.semantics()
    var grid_rows: int = 0
    var grid_columns: int = 0
    var cells: int = 0
    var first_cell_row: int = -1
    var first_cell_column: int = -1
    var rows_named: int = 0
    for node: scene.SemanticsNode in tree {
        if node.id() == table.handle() { grid_rows = node.rows(); grid_columns = node.columns() }
        if node.role() == "row" { rows_named += 1 }
        if node.role() == "cell" {
            cells += 1
            if first_cell_row < 0 { first_cell_row = node.row(); first_cell_column = node.column() }
        }
    }
    io.println("the table says it has {grid_rows} rows and {grid_columns} columns")
    io.println("rows in the tree: {rows_named}, and they are not ten million: {rows_named < 40}")
    io.println("cells in the tree: {cells}, which is the window and not the table: {cells > 0 && cells < 400}")
    io.println("the first cell is at row {first_cell_row}, column {first_cell_column}")
    io.println("which is one-based against the first visible row: {first_cell_row == table.first_visible_row() + 1}")

    rule("20 — the scrollbars, and what dragging one does")

    // A table that fits shows neither bar.
    table.set_source(new FewRows()).expect("three rows")
    page.refresh().expect("refresh")
    io.println("three rows show a row bar: {table.shows_row_bar()}")

    table.set_source(new TallRows()).expect("ten million rows")
    table.scroll_to(geometry.Point.at(0.0, 0.0)).expect("to the top")
    table.select(-1).expect("nothing selected")
    page.refresh().expect("refresh")
    io.println("ten million rows show one: {table.shows_row_bar()}")
    io.println("and two hundred columns show the other: {table.shows_column_bar()}")

    let track: geometry.Rect = table.row_bar_track()
    io.println("its track is the body less the inset: {track.height as int}")
    // A thumb whose share of ten million rows is a fraction of a point is
    // still something a pointer can land on.
    io.println("the thumb is short but takeable: {table.row_thumb_length()}")
    io.println("and it starts at the top: {table.row_thumb_at()}")

    let aim_x: f64 = track.x + track.width / 2.0
    let start_y: f64 = track.y + table.row_thumb_length() / 2.0
    page.pointer(input.EventKind.pointer_down, geometry.Point.at(aim_x, start_y), 1, 1, 0).expect("take the thumb")
    page.pointer(input.EventKind.pointer_move, geometry.Point.at(aim_x, start_y + 100.0), 1, 0, 0).expect("drag")
    page.pointer(input.EventKind.pointer_up, geometry.Point.at(aim_x, start_y + 100.0), 1, 1, 0).expect("let go")
    // A hundred points of a 240-point run is five twelfths of ten million.
    let landed: int = table.first_visible_row()
    io.println("a hundred points down a {(track.height - table.row_thumb_length()) as int} point run landed on row {landed}")
    io.println("which is the share of ten million it should be: {landed > 4100000 && landed < 4230000}")
    io.println("the thumb went with it: {table.row_thumb_at() > 90.0 && table.row_thumb_at() < 110.0}")
    io.println("and a press on a bar selects nothing: {table.selected()}")
    io.println("the rows still reach no further than the table: {template_reach(table) < 300.0 + row_height}")

    // A press in the track away from the thumb goes there rather than creeping.
    page.pointer(input.EventKind.pointer_down, geometry.Point.at(aim_x, track.y + track.height - 4.0), 1, 1, 0).expect("press the end of the track")
    page.pointer(input.EventKind.pointer_up, geometry.Point.at(aim_x, track.y + track.height - 4.0), 1, 1, 0).expect("let go")
    io.println("a press at the end of the track lands at the end: {table.first_visible_row() > 9999000}")

    // Sideways.
    let across: geometry.Rect = table.column_bar_track()
    let from_x: f64 = across.x + table.column_thumb_length() / 2.0
    let bar_y: f64 = across.y + across.height / 2.0
    page.pointer(input.EventKind.pointer_down, geometry.Point.at(from_x, bar_y), 1, 1, 0).expect("take it")
    page.pointer(input.EventKind.pointer_move, geometry.Point.at(from_x + 100.0, bar_y), 1, 0, 0).expect("drag")
    page.pointer(input.EventKind.pointer_up, geometry.Point.at(from_x + 100.0, bar_y), 1, 1, 0).expect("let go")
    // The share of the run dragged and the share of the content scrolled are
    // the same number, which is the whole contract of a scrollbar.
    let run: f64 = across.width - table.column_thumb_length()
    let reach: f64 = table.content_size().width + table.column_inset() - table.frame().width
    let dragged: f64 = 100.0 / run
    let scrolled: f64 = table.scroll_x() / reach
    io.println("a {run as int} point run, {reach as int} points of content, {table.scroll_x() as int} scrolled")
    io.println("the share dragged and the share scrolled agree: {scrolled - dragged < 0.02 && dragged - scrolled < 0.02}")
    io.println("and the first visible column went with it: {table.column_reaching(table.scroll_x())}")

    rule("21 — the bounds, said in full")

    io.println("a 4097th column: {column_refusal(table)}")
    io.println("too many rows: {row_refusal(table)}")

    rule("22 — closing a scrolled table lets go of everything")

    let root: scene.RenderObject = page.root().render_object().expect("root")
    page.close()
    io.println("the table is released: {!table.is_alive()}")
    io.println("the tree is released: {!root.is_alive()}")
}

/// Where the first visible row is painted, from the top of the table.
///
/// Three levels down, and they are all real: a control's visual is the
/// container the template mount fills, the template's own root is the framed
/// <Box>, and the rows live in the <Box key="body"> that carries the scroll.
fn row_top_of_first(table: scene.TableRender) -> f64 {
    match table.visual() {
        some(container) => {
            match container.child_at(0) {
                some(frame) => {
                    match frame.child_at(0) {
                        some(body) => {
                            match body.child_at(0) {
                                some(row) => {
                                    return frame.frame().y + body.frame().y +
                                           body.child_offset().y + row.frame().y
                                }
                                none => {}
                            }
                        }
                        none => {}
                    }
                }
                none => {}
            }
        }
        none => {}
    }
    return -1.0
}

fn column_refusal(table: scene.TableRender) -> string {
    match table.set_columns(4097) {
        ok(_) => { return "accepted" }
        err(problem) => { return problem.msg }
    }
}

fn row_refusal(table: scene.TableRender) -> string {
    match table.set_source(new HugeRows()) {
        ok(_) => { return "accepted" }
        err(problem) => { return problem.kind }
    }
}

/// Ten million rows again, this time straight onto the render object.
pub class TallRows implements scene.TableData {
    pub fn init() {}
    pub fn row_count() -> int { return 10000000 }
    pub fn cell(row: int, column: int) -> string { return "{row}.{column}" }
}

/// Few enough rows that an appearance change cannot change how many fit.
pub class FewRows implements scene.TableData {
    pub fn init() {}
    pub fn row_count() -> int { return 3 }
    pub fn cell(row: int, column: int) -> string { return "{row}.{column}" }
}

/// More rows than a double can step through a sixteenth of a point at a time.
pub class HugeRows implements scene.TableData {
    pub fn init() {}
    pub fn row_count() -> int { return 100000000000000 }
    pub fn cell(row: int, column: int) -> string { return "" }
}

fn main() { run() }
