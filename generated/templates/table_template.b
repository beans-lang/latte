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
    /// The two bands a scroll moves. Named here rather than found by position:
    /// which node scrolls is a fact about this markup, and a template that
    /// rearranged its boxes should not quietly stop scrolling.
    pub override fn on_mount(stage: compose.Stage) {
        self.adopt_bands(stage.widget("body"), stage.widget("header"),
                         stage.widget("rowbar"), stage.widget("columnbar"))
    }
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
        b.number("height", (self.height) as f64)
        b.word("background", self.card)
        b.word("border_color", self.separator)
        b.number("border_width", (1) as f64)
        b.open("Box")  // table_template.bx:2
        b.key("{"body"}")
        b.number("x", (0) as f64)
        b.number("y", (0) as f64)
        b.number("width", (self.total_width) as f64)
        b.number("height", (self.height) as f64)
        if self.total_rows == 0 {  // table_template.bx:3
            b.open("Label")  // table_template.bx:4
            b.number("x", (self.column_inset) as f64)
            b.number("y", (self.header_height + 6.0) as f64)
            b.text("No rows")
            b.word("text_color", self.muted)
            b.number("font_size", (self.font_size) as f64)
            b.close()
        }
        var _latte_row_0: int = 0
        for row in self.rows {  // table_template.bx:6
            b.open("HStack")  // table_template.bx:7
            b.key("{"r{row.index}"}")
            b.number("x", (self.strip_x) as f64)
            b.number("y", (row.top) as f64)
            b.number("height", (self.row_height) as f64)
            b.number("width", (self.strip_width) as f64)
            b.number("spacing", (0) as f64)
            b.word("align", "center")
            b.number("padding_x", (self.column_inset) as f64)
            b.word("background", if row.selected { self.selection } else if row.index % 2 == 1 { self.stripe } else { "#00000000" })
            var _latte_row_1: int = 0
            for column in 0..row.cells.len() {  // table_template.bx:10
                if row.index == self.editing_row && self.first_column + column == self.editing_column {  // table_template.bx:11
                    b.open("TextField")  // table_template.bx:12
                    b.key("{"e{self.first_column + column}"}")
                    b.text("{row.cells[column]}")
                    b.number("width", (self.widths[column]) as f64)
                    b.number("height", (self.row_height) as f64)
                    b.on("commit", fn(e: UiEvent) { self.commit(row.index, self.editing_column, e.text) })
                    b.on("key_down", fn(e: UiEvent) { self.editor_key(e) })
                    b.close()
                } else {  // table_template.bx:16
                    b.open("Label")  // table_template.bx:17
                    b.key("{"c{self.first_column + column}"}")
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
        b.close()
        b.open("Box")  // table_template.bx:26
        b.key("{"header"}")
        b.number("x", (0) as f64)
        b.number("y", (0) as f64)
        b.number("width", (self.total_width) as f64)
        b.number("height", (self.header_height) as f64)
        b.word("background", self.grouped)
        b.open("HStack")  // table_template.bx:27
        b.number("x", (self.strip_x) as f64)
        b.number("y", (0) as f64)
        b.number("height", (self.header_height) as f64)
        b.number("width", (self.strip_width) as f64)
        b.number("spacing", (0) as f64)
        b.word("align", "center")
        b.number("padding_x", (self.column_inset) as f64)
        var _latte_row_2: int = 0
        for column in 0..self.titles.len() {  // table_template.bx:29
            b.open("Label")  // table_template.bx:30
            b.key("{"h{self.first_column + column}"}")
            b.text("{self.titles[column]}")
            b.number("width", (self.widths[column]) as f64)
            b.number("font_size", (self.footnote) as f64)
            b.word("text_color", self.muted)
            b.close()
            _latte_row_2 += 1
        }
        b.close()
        b.close()
        b.open("Box")  // table_template.bx:35
        b.key("{"rowbar"}")
        b.number("x", (self.row_bar_x) as f64)
        b.number("y", (self.row_bar_y) as f64)
        b.number("width", (self.bar_thickness) as f64)
        b.number("height", (self.row_bar_height) as f64)
        b.open("Rectangle")  // table_template.bx:37
        b.number("x", (0) as f64)
        b.number("y", (0) as f64)
        b.number("width", (self.bar_thickness) as f64)
        b.number("height", (self.row_thumb_height) as f64)
        b.word("fill", self.faint)
        b.number("corner_radius", (self.bar_thickness / 2.0) as f64)
        b.close()
        b.close()
        b.open("Box")  // table_template.bx:40
        b.key("{"columnbar"}")
        b.number("x", (self.column_bar_x) as f64)
        b.number("y", (self.column_bar_y) as f64)
        b.number("width", (self.column_bar_width) as f64)
        b.number("height", (self.bar_thickness) as f64)
        b.open("Rectangle")  // table_template.bx:42
        b.number("x", (0) as f64)
        b.number("y", (0) as f64)
        b.number("width", (self.column_thumb_width) as f64)
        b.number("height", (self.bar_thickness) as f64)
        b.word("fill", self.faint)
        b.number("corner_radius", (self.bar_thickness / 2.0) as f64)
        b.close()
        b.close()
        b.close()
    }
}
