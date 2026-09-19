package compose

import latte.scene

/// One materialized row in a much larger source.
pub class TableVisibleRow {
    pub index: int
    pub top: f64
    pub cells: List<string>
    pub selected: bool
    pub fn init(index: int, top: f64, cells: List<string>, selected: bool) {
        self.index = index; self.top = top; self.selected = selected
        self.cells = []
        for cell: string in cells { self.cells.push(cell) }
    }
}

pub abstract class TableControlTemplate extends ControlTemplate {
    pub titles: List<string> = []
    pub widths: List<f64> = []
    pub rows: List<TableVisibleRow> = []
    pub total_rows: int = 0
    pub total_width: f64 = 0.0
    pub revision: int = -1
    pub editing_row: int = -1
    pub editing_column: int = -1
    pub selected_column: int = -1
    data_revision: int = -1
    first_row: int = -1
    last_row: int = -1
    offset_y: f64 = -1.0
    viewport_height: f64 = -1.0
    viewport_width: f64 = -1.0
    pub fn init() { super.init() }
    pub override fn update(control: scene.RenderObject, theme: scene.Theme) {
        super.update(control, theme)
        match control as? scene.TableRender {
            some(table) => {
                let scroll_y: f64 = table.scroll_offset()
                let height: f64 = table.frame().height
                let width: f64 = table.frame().width
                if self.revision == table.version() && self.offset_y == scroll_y &&
                   self.viewport_width == width && self.viewport_height == height { return }
                let data_changed: bool = self.data_revision != table.data_version()
                let chrome_changed: bool = self.revision != table.version() ||
                                           self.viewport_width != width || self.viewport_height != height
                self.revision = table.version()
                self.data_revision = table.data_version()
                self.offset_y = scroll_y
                self.viewport_height = height
                self.viewport_width = width
                self.editing_row = table.editing_row()
                self.editing_column = table.editing_column()
                self.selected_column = table.selected_column()
                if chrome_changed {
                    self.total_rows = table.row_count()
                    self.row_height = table.row_height()
                    self.header_height = table.header_height()
                    self.titles = table.titles_copy()
                    self.widths = table.widths_copy()
                    self.total_width = width
                    var columns_width: f64 = 0.0
                    for column_width: f64 in self.widths { columns_width += column_width }
                    if columns_width > self.total_width { self.total_width = columns_width }
                }
                var visible: List<TableVisibleRow> = []
                // Keep the partly visible row; the opaque header covers its
                // portion above the table body.
                var first: int = (scroll_y / self.row_height) as int
                if first < 0 { first = 0 }
                var last: int = first + ((height - self.header_height) / self.row_height) as int + 2
                if last > self.total_rows { last = self.total_rows }
                if last < first { last = first }
                if !data_changed && first == self.first_row && last == self.last_row {
                    for held: TableVisibleRow in self.rows {
                        held.top = self.header_height + held.index as f64 * self.row_height - scroll_y
                        held.selected = table.selected() == held.index
                    }
                    self.request_render()
                    return
                }
                for row: int in first..last {
                    var retained: Option<TableVisibleRow> = none
                    if !data_changed {
                        for held: TableVisibleRow in self.rows {
                            if held.index == row { retained = some(held); break }
                        }
                    }
                    match retained {
                        some(held) => {
                            held.top = self.header_height + row as f64 * self.row_height - scroll_y
                            held.selected = table.selected() == row
                            visible.push(held)
                        }
                        none => {
                            var cells: List<string> = []
                            for column: int in 0..self.titles.len() {
                                cells.push(table.cell(row, column).expect("visible table cell"))
                            }
                            visible.push(new TableVisibleRow(row, self.header_height + row as f64 * self.row_height - scroll_y,
                                                             move cells, table.selected() == row))
                        }
                    }
                }
                self.first_row = first
                self.last_row = last
                self.rows = move visible
                self.request_render()
            }
            none => {}
        }
    }
}
