// Generated from templates/table_template.bx by latte-bx. Do not edit.
//
// The <beans> block below is table_template.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change table_template.bx and regenerate:
//
//     latte-bx build templates/table_template.bx
package templates

import {Builder, Component} from latte.compose
import {UiEvent} from latte.input


//               
import latte.compose
import latte.scene
import latte.input
import {view} from latte.annotations

@view
pub partial class TableTemplate extends compose.TableControlTemplate {
    actions: Option<scene.ControlActions> = none
    pub fn init() { super.init() }
    pub override fn bind_actions(actions: scene.ControlActions) { self.actions = some(actions) }
    pub fn commit(row: int, column: int, text: string) {
        match self.actions {
            some(actions) => { actions.commit_cell(row, column, text).expect("commit a table cell") }
            none => { panic("table template has no actions") }
        }
    }
    pub fn editor_key(event: input.UiEvent) {
        if event.key() != input.Key.escape { return }
        match self.actions {
            some(actions) => { actions.cancel_cell().expect("cancel a table cell") }
            none => { panic("table template has no actions") }
        }
    }
}

partial class TableTemplate {
    pub override fn render(b: Builder) {
        b.open("Box")  // table_template.bx:1
        b.number("width", (self.total_width) as f64)
        b.word("background", self.card)
        b.word("border_color", self.separator)
        b.number("border_width", (1) as f64)
        if self.total_rows == 0 {  // table_template.bx:2
            b.open("Label")  // table_template.bx:3
            b.number("x", (6) as f64)
            b.number("y", (self.header_height + 6.0) as f64)
            b.text("No rows")
            b.word("text_color", self.muted)
            b.number("font_size", (self.font_size) as f64)
            b.close()
        }
        var _latte_row_0: int = 0
        for row in self.rows {  // table_template.bx:5
            b.open("HStack")  // table_template.bx:6
            b.key("{"row-{row.index}"}")
            b.number("y", (row.top) as f64)
            b.number("height", (self.row_height) as f64)
            b.number("width", (self.total_width) as f64)
            b.number("spacing", (0) as f64)
            b.word("align", "center")
            b.number("padding_x", (6) as f64)
            b.word("background", if row.selected { self.selection } else if row.index % 2 == 1 { self.stripe } else { "#00000000" })
            var _latte_row_1: int = 0
            for column in 0..row.cells.len() {  // table_template.bx:9
                if row.index == self.editing_row && column == self.editing_column {  // table_template.bx:10
                    b.open("TextField")  // table_template.bx:11
                    b.key("{"editor-{row.index}-{column}"}")
                    b.text("{row.cells[column]}")
                    b.number("width", (self.widths[column]) as f64)
                    b.number("height", (self.row_height) as f64)
                    b.on("commit", fn(e: UiEvent) { self.commit(row.index, column, e.text) })
                    b.on("key_down", fn(e: UiEvent) { self.editor_key(e) })
                    b.close()
                } else {  // table_template.bx:15
                    b.open("Label")  // table_template.bx:16
                    b.key("{"cell-{row.index}-{column}"}")
                    b.text("{row.cells[column]}")
                    b.number("width", (self.widths[column]) as f64)
                    b.number("font_size", (self.font_size) as f64)
                    b.word("text_color", if row.selected { self.on_accent } else { self.ink })
                    b.word("background", "#00000000")
                    b.close()
                }
                _latte_row_1 += 1
            }
            b.close()
            _latte_row_0 += 1
        }
        b.open("HStack")  // table_template.bx:24
        b.number("y", (0) as f64)
        b.number("height", (self.header_height) as f64)
        b.number("width", (self.total_width) as f64)
        b.number("spacing", (0) as f64)
        b.word("align", "center")
        b.number("padding_x", (6) as f64)
        b.word("background", self.grouped)
        var _latte_row_2: int = 0
        for column in 0..self.titles.len() {  // table_template.bx:26
            b.open("Label")  // table_template.bx:27
            b.key("{"header-{column}"}")
            b.text("{self.titles[column]}")
            b.number("width", (self.widths[column]) as f64)
            b.number("font_size", (self.footnote) as f64)
            b.word("text_color", self.muted)
            b.close()
            _latte_row_2 += 1
        }
        b.close()
        b.close()
    }
}
