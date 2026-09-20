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
    return 0
}

fn main() { run() }
