// Generated from examples/showcase/site/table_page.bx by latte-bx. Do not edit.
//
// The <beans> block below is table_page.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change table_page.bx and regenerate:
//
//     latte-bx build examples/showcase/site/table_page.bx
package site

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//          

import latte.compose
import latte.controls
import {view} from latte.annotations

/// Ten thousand rows that are not in memory.
///
/// `cell` is the whole source: a row is a string built when it is asked for,
/// and nothing holds the ten thousand. `reads` counts the calls, which is what
/// `tests/canvas/table.b` asserts against — a table that read every row to
/// draw twenty would show it as a number in the thousands.
pub class OrderRows implements controls.TableRows {
    pub reads: int = 0
    pub total: int = 10000
    edits: Map<int, string> = {}

    pub fn init() {}

    pub fn row_count() -> int { return self.total }

    pub fn cell(row: int, column: int) -> string {
        self.reads = self.reads + 1
        if column == 0 { return "Order {row}" }
        return match self.edits.get(row) {
            some(value) => value,
            none => "Cup {row % 3}",
        }
    }

    pub fn save(row: int, column: int, text: string) {
        if column == 1 { self.edits[row] = text }
    }

    pub fn forget() { self.edits = {} }
}

@view
pub partial class TablePage extends compose.Component {
    pub rows: OrderRows
    pub titles: List<string> = ["Order", "Cup"]
    pub widths: List<f64> = [220.0, 200.0]
    pub selected: int = -1
    pub last_edit: string = "none"
    pub policy: compose.TableEditRule

    pub fn init() {
        self.rows = new OrderRows()
        // Only the second column. A policy rather than a flag on the table:
        // which cells may be edited is a question about the data, and a table
        // that asked its own columns would have to be told again for every
        // source it is given.
        self.policy = new compose.TableEditRule(fn(row: int, column: int) -> bool {
            return column == 1
        })
        super.init()
    }

    pub fn choose(index: int) { self.selected = index; self.request_render() }

    pub fn commit(row: int, column: int, text: string) {
        self.rows.save(row, column, text)
        self.last_edit = "row {row}, column {column}: {text}"
        self.request_render()
    }

    pub fn state() -> string {
        return "selected row {self.selected}, last edit {self.last_edit}, {self.rows.reads} cell reads"
    }
}

partial class TablePage {
    pub override fn render(b: Builder) {
        b.open("VStack")  // table_page.bx:1
        b.number("padding", (20) as f64)
        b.number("spacing", (10) as f64)
        b.word("align", "stretch")
        b.open("Label")  // table_page.bx:2
        b.text("Virtual table")
        b.number("font_size", (23) as f64)
        b.close()
        b.open("Label")  // table_page.bx:3
        b.text("10,000 rows. Cells are read only as they scroll into view.")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("Label")  // table_page.bx:4
        b.text("Double-click a Cup cell to edit it, or select a row, choose a column with Left and Right and press Return. Return commits, Escape cancels.")
        b.word("text_color", "#555b6b")
        b.close()
        b.open("Table")  // table_page.bx:5
        b.key("{"orders"}")
        b.columns(self.titles)
        b.column_widths(self.widths)
        b.table_source(self.rows)
        b.editable_when(self.policy)
        b.number("height", (380) as f64)
        b.on("select", fn(e: UiEvent) { self.choose(e.index) })
        b.on("commit", fn(e: UiEvent) { self.commit(e.index, e.token, e.text) })
        b.close()
        b.open("Label")  // table_page.bx:9
        b.key("{"state"}")
        b.text("{self.state()}")
        b.word("text_color", "#555b6b")
        b.close()
        b.close()
    }
}
