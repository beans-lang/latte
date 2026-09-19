package scene

import latte.geometry
import latte.paint
import latte.input
import latte.platform

/// The shared table asks only for rows it is about to show.
pub interface TableData {
    fn row_count() -> int
    fn cell(row: int, column: int) -> string
}

pub class TableRender extends ScrollRender {
    source: Option<TableData> = none
    edit_policy: Option<fn(int, int) -> bool> = none
    titles: List<string> = []
    widths: List<f64> = []
    rows_value: int = 0
    selected_value: int = -1
    selected_column_value: int = -1
    revision: int = 0
    data_revision: int = 0
    editing_row_value: int = -1
    editing_column_value: int = -1
    focus_editor: bool = false
    tracking: bool = false
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.focusable = true
    }
    pub override fn role() -> string { return "table" }
    pub override fn needs_template() -> bool { return true }
    pub override fn interactive_visual() -> bool { return true }
    pub override fn visual_offset() -> geometry.Point { return geometry.Point.at(-self.scroll_x(), 0.0) }
    pub override fn template_size() -> geometry.Size {
        var width: f64 = self.bounds.width
        var columns: f64 = 0.0
        for value: f64 in self.widths { columns += value }
        if columns > width { width = columns }
        return geometry.Size.of(width, self.bounds.height)
    }
    /// A list row and its header, from the theme rather than a constant, so
    /// the whole window tightens or loosens together.
    pub fn row_height() -> f64 { return self.theme.row_height() }
    pub fn header_height() -> f64 { return self.theme.header_height() }
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
    pub fn scroll_offset() -> f64 { return -self.child_offset().y }
    pub fn scroll_x() -> f64 { return -self.child_offset().x }
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
    pub fn set_columns(count: int) -> Result<bool> {
        self.demand_alive()?
        if count < 0 || count > 64 { return err("invalid table column count", "out_of_range") }
        self.clear_editor()
        self.titles = []
        self.widths = []
        for index: int in 0..count { self.titles.push(""); self.widths.push(120.0) }
        if self.selected_column_value >= count { self.selected_column_value = -1 }
        self.revision += 1
        self.data_revision += 1
        self.update_content()?
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
        self.revision += 1
        self.update_content()?
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
        self.revision += 1
        self.update_content()?
        self.dirty.layout()
        return ok(true)
    }
    pub fn reset_widths() -> Result<bool> {
        self.demand_alive()?
        for index: int in 0..self.widths.len() { self.widths[index] = 120.0 }
        self.revision += 1
        self.update_content()?
        self.dirty.layout()
        return ok(true)
    }
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
    fn validate_rows(count: int) -> Result<bool> {
        if count < 0 || !(self.header_height() + count as f64 * self.row_height() < 10000000.0) {
            return err("table rows exceed content height", "out_of_range")
        }
        return ok(true)
    }
    fn apply_rows(count: int) -> Result<bool> {
        self.rows_value = count
        if self.selected_value >= count { self.selected_value = -1 }
        if self.editing_row_value >= count { self.clear_editor() }
        self.revision += 1
        self.data_revision += 1
        self.update_content()?
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    fn update_content() -> Result<bool> {
        var width: f64 = 0.0
        for value: f64 in self.widths { width += value }
        return self.set_content_size(geometry.Size.of(width, self.header_height() + self.rows_value as f64 * self.row_height()))
    }
    pub fn cell(row: int, column: int) -> Result<string> {
        self.demand_alive()?
        if row < 0 || row >= self.rows_value || column < 0 || column >= self.titles.len() {
            return err("table cell is outside the source", "out_of_range")
        }
        return match self.source { some(data) => ok(data.cell(row, column)) none => err("table has no source", "empty_source") }
    }
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
        let view_bottom: f64 = view_top + self.bounds.height - self.header_height()
        var left: f64 = 0.0
        for column: int in 0..self.editing_column_value { left += self.widths[column] }
        let right: f64 = left + self.widths[self.editing_column_value]
        let view_left: f64 = self.scroll_x()
        let view_right: f64 = view_left + self.bounds.width
        if bottom <= view_top || top >= view_bottom || right <= view_left || left >= view_right {
            self.cancel_edit()
        }
    }
    pub override fn scroll_by(dx: f64, dy: f64) -> Result<bool> {
        let changed: bool = super.scroll_by(dx, dy)?
        if changed { self.cancel_editor_if_outside() }
        return ok(changed)
    }
    pub override fn on_dispose() {
        self.source = none
        self.edit_policy = none
        self.clear_editor()
    }
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
        var left: f64 = 0.0
        for index: int in 0..column { left += self.widths[index] }
        let right: f64 = left + self.widths[column]
        var next_x: f64 = self.scroll_x()
        if left < next_x { next_x = left }
        else if right > next_x + self.bounds.width { next_x = right - self.bounds.width }
        self.scroll_to(geometry.Point.at(next_x, self.scroll_offset()))?
        self.cancel_editor_if_outside()
        self.revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    fn ensure_visible(row: int) -> Result<bool> {
        if row < 0 || self.bounds.height <= self.header_height() { return ok(false) }
        let body: f64 = self.bounds.height - self.header_height()
        let top: f64 = row as f64 * self.row_height()
        let bottom: f64 = top + self.row_height()
        var next: f64 = self.scroll_offset()
        if top < next { next = top }
        else if bottom > next + body { next = bottom - body }
        return self.scroll_to(geometry.Point.at(self.scroll_x(), next))
    }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        var width: f64 = 0.0
        for value: f64 in self.widths { width += value }
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
    fn column_at(x: f64) -> int {
        var left: f64 = -self.scroll_x()
        for column: int in 0..self.widths.len() {
            let right: f64 = left + self.widths[column]
            if x >= left && x < right { return column }
            left = right
        }
        return -1
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT { self.tracking = true; return none }
        if event.kind == input.EventKind.pointer_up {
            let was_tracking: bool = self.tracking
            self.tracking = false
            if was_tracking && event.index == platform.BTN_LEFT &&
               geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height).contains(event.position) &&
               event.position.y >= self.header_height() {
                let row: int = ((event.position.y + self.scroll_offset() - self.header_height()) / self.row_height()) as int
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
        if !focused { self.tracking = false }
    }
}
