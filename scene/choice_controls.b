package scene

import latte.geometry
import latte.paint
import latte.input
import latte.platform

/// A string list owned by one shared selection control.
pub abstract class ChoiceRender extends RenderObject {
    items: List<string> = []
    chosen: int = -1
    revision: int = 0
    tracking: bool = false
    fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.focusable = true
    }
    pub override fn needs_template() -> bool { return true }
    pub fn count() -> int { return self.items.len() }
    pub fn version() -> int { return self.revision }
    pub fn selected() -> int { return self.chosen }
    pub fn highlighted() -> int { return self.chosen }
    pub fn selected_text() -> string { return if self.chosen >= 0 && self.chosen < self.items.len() { self.items[self.chosen] } else { "" } }
    pub fn choices() -> List<string> {
        var copy: List<string> = []
        for item: string in self.items { copy.push(item) }
        return move copy
    }
    pub fn item_at(index: int) -> Result<string> {
        self.demand_alive()?
        if index < 0 || index >= self.items.len() { return err("choice index is outside the list", "out_of_range") }
        return ok(self.items[index])
    }
    pub fn replace_items(items: List<string>) -> Result<bool> {
        self.demand_alive()?
        self.dismiss_popup()
        var copy: List<string> = []
        for item: string in items { copy.push(item) }
        self.items = move copy
        self.chosen = if self.items.len() == 0 { -1 } else { 0 }
        self.revision += 1
        self.dirty.layout(); self.dirty.semantics()
        return ok(true)
    }
    pub fn add_item(item: string) -> Result<bool> {
        self.demand_alive()?
        self.items.push(item)
        if self.chosen == -1 { self.chosen = 0 }
        self.revision += 1
        self.dirty.layout(); self.dirty.semantics()
        return ok(true)
    }
    pub override fn set_text(text: string) -> Result<bool> { self.demand_alive()?; return err("use items to set a choice list", "unsupported") }
    pub override fn set_integer(key: int, value: int) -> Result<bool> {
        if key != platform.P_SELECTED { return super.set_integer(key, value) }
        self.demand_alive()?
        if value < -1 || value >= self.items.len() { return err("choice selection is outside the list", "out_of_range") }
        if self.chosen == value { return ok(false) }
        self.chosen = value
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub override fn integer(key: int) -> Result<int> {
        if key == platform.P_SELECTED { self.demand_alive()?; return ok(self.chosen) }
        return super.integer(key)
    }
    pub override fn set_value_as_user(index: int, value: f64) -> Result<bool> { return self.set_integer(platform.P_SELECTED, index) }
    pub override fn value_event_text(index: int, value: f64) -> string { return self.selected_text() }
    pub override fn semantics() -> SemanticsNode {
        let label: string = if self.a11y_name == "" { self.words } else { self.a11y_name }
        return new SemanticsNode(self.identity, self.role(), label, self.selected_text(), self.bounds, self.enabled)
    }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        let padding: f64 = self.theme.control_padding()
        // A popup button is its widest title, the leading inset, and the column
        // it keeps for the chevrons — which is wider than the chevrons alone.
        let column: f64 = self.theme.chevron_column()
        var width: f64 = padding + column
        for item: string in self.items {
            let paragraph: paint.Paragraph = self.renderer.styled_paragraph(item, self.text_style(), -1.0, self.text_color())?
            let wanted: f64 = paragraph.size().width + padding + column
            if wanted > width { width = wanted }
        }
        return ok(geometry.Size.of(width, self.theme.control_height()))
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> { super.paint_self(canvas)?; return self.paint_template(canvas) }
    fn select_as_user(index: int) -> Option<input.UiEvent> {
        if index < 0 || index >= self.items.len() || index == self.chosen { return none }
        self.chosen = index
        self.dismiss_popup()
        self.dirty.paint(); self.dirty.semantics()
        let change: input.UiEvent = input.UiEvent.of(input.EventKind.value_changed, platform.Handle.of(self.identity))
        change.index = index; change.position = geometry.Point.at(index as f64, 0.0); change.text = self.items[index]
        return some(change)
    }
}

pub class ComboBoxRender extends ChoiceRender {
    open_value: bool = false
    highlighted_value: int = -1
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) { super.init(renderer, theme, dirty) }
    pub override fn role() -> string { return "combobox" }
    pub override fn highlighted() -> int { return self.highlighted_value }
    pub override fn popup_open() -> bool { return self.open_value && self.items.len() > 0 }
    pub override fn dismiss_popup() {
        if !self.open_value { return }
        self.open_value = false
        self.highlighted_value = -1
        self.tracking = false
        self.dirty.paint(); self.dirty.semantics()
    }
    /// The menu NSPopUpButton opens: as wide as its widest title plus the
    /// mark column, and placed so the chosen row sits over the control.
    pub override fn popup_bounds() -> geometry.Rect {
        let row: f64 = self.theme.menu_row_height()
        let pad: f64 = self.theme.menu_padding()
        var widest: f64 = 0.0
        for item: string in self.items {
            match self.renderer.styled_paragraph(item, self.text_style(), -1.0, self.text_color()) {
                ok(paragraph) => { if paragraph.size().width > widest { widest = paragraph.size().width } }
                err(_) => {}
            }
        }
        var width: f64 = widest + self.theme.menu_width_over_text() + self.theme.menu_check_column()
        if width < self.bounds.width { width = self.bounds.width }
        let height: f64 = self.items.len() as f64 * row + pad * 2.0
        let index: f64 = (if self.chosen > 0 { self.chosen } else { 0 }) as f64
        // The chosen row lands on the control, not under it.
        let y: f64 = 0.0 - pad - index * row + (self.bounds.height - row) / 2.0
        let x: f64 = self.theme.control_padding() - self.theme.menu_text_inset()
        return geometry.Rect.of(x, y, width, height)
    }
    pub override fn set_value_as_user(index: int, value: f64) -> Result<bool> {
        let changed: bool = super.set_value_as_user(index, value)?
        self.dismiss_popup()
        return ok(changed)
    }
    pub override fn focus_changed(focused: bool) {
        super.focus_changed(focused)
        if !focused { self.tracking = false }
    }
    fn show_popup() {
        if self.open_value || self.items.len() == 0 { return }
        self.open_value = true
        self.highlighted_value = if self.chosen >= 0 { self.chosen } else { 0 }
        self.dirty.paint(); self.dirty.semantics()
    }
    fn move_highlight(index: int) {
        if index < 0 || index >= self.items.len() || index == self.highlighted_value { return }
        self.highlighted_value = index
        self.dirty.paint(); self.dirty.semantics()
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        if event.kind == input.EventKind.activate { self.show_popup(); return none }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT { self.tracking = true; self.pressed = true; self.dirty.paint(); return none }
        if event.kind == input.EventKind.pointer_up {
            let was_tracking: bool = self.tracking
            self.tracking = false
            if self.pressed { self.pressed = false; self.dirty.paint() }
            if was_tracking && geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height).contains(event.position) && self.items.len() > 0 {
                self.show_popup()
            }
        }
        if event.kind == input.EventKind.key_down && self.items.len() > 0 {
            if !self.open_value && (event.key() == input.Key.space || event.key() == input.Key.ret ||
                                    event.key() == input.Key.down || event.key() == input.Key.up) {
                self.show_popup()
                return none
            }
            if self.open_value {
                if event.key() == input.Key.down { self.move_highlight((self.highlighted_value + 1) % self.items.len()); return none }
                if event.key() == input.Key.up { self.move_highlight((self.highlighted_value + self.items.len() - 1) % self.items.len()); return none }
                if event.key() == input.Key.home { self.move_highlight(0); return none }
                if event.key() == input.Key.end { self.move_highlight(self.items.len() - 1); return none }
                if event.key() == input.Key.space || event.key() == input.Key.ret {
                    let changed: Option<input.UiEvent> = self.select_as_user(self.highlighted_value)
                    self.dismiss_popup()
                    return changed
                }
            }
        }
        return none
    }
}

pub class SegmentedRender extends ChoiceRender {
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) { super.init(renderer, theme, dirty) }
    pub override fn role() -> string { return "radiogroup" }
    /// Each segment's width: its own title plus the measured padding, with any
    /// room left over shared equally. The template places its labels and its
    /// pill from these, and the hit test reads the same list — a segment sized
    /// by its title cannot be found by dividing the control into equal parts.
    pub fn segment_widths() -> List<f64> {
        var widths: List<f64> = []
        let padding: f64 = self.theme.segment_padding()
        var content: f64 = 0.0
        for item: string in self.items {
            var run: f64 = 0.0
            match self.renderer.styled_paragraph(item, self.text_style(), -1.0, self.text_color()) {
                ok(paragraph) => { run = paragraph.size().width }
                err(problem) => {}
            }
            widths.push(run + padding)
            content += run + padding
        }
        if widths.len() == 0 { return move widths }
        let spare: f64 = (self.bounds.width - content) / widths.len() as f64
        if spare > 0.0 {
            for index: int in 0..widths.len() { widths[index] = widths[index] + spare }
        }
        return move widths
    }
    /// Where a segment starts, in the control's own coordinates.
    pub fn segment_x(index: int) -> f64 {
        let widths: List<f64> = self.segment_widths()
        var x: f64 = 0.0
        for step: int in 0..widths.len() {
            if step == index { return x }
            x += widths[step]
        }
        return x
    }
    fn segment_at(x: f64) -> int {
        let widths: List<f64> = self.segment_widths()
        var edge: f64 = 0.0
        for index: int in 0..widths.len() {
            edge += widths[index]
            if x < edge { return index }
        }
        return widths.len() - 1
    }
    pub override fn focus_changed(focused: bool) {
        super.focus_changed(focused)
        if !focused { self.tracking = false }
    }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        // Each segment is its own title plus the measured padding, so a long
        // label makes one segment wider rather than every segment wider.
        let padding: f64 = self.theme.segment_padding()
        var width: f64 = 0.0
        for item: string in self.items {
            let paragraph: paint.Paragraph = self.renderer.styled_paragraph(item, self.text_style(), -1.0, self.text_color())?
            width += paragraph.size().width + padding
        }
        return ok(geometry.Size.of(if width > 48.0 { width } else { 48.0 }, self.theme.control_height()))
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT { self.tracking = true; self.pressed = true; self.dirty.paint(); return none }
        if event.kind == input.EventKind.pointer_up {
            let was_tracking: bool = self.tracking
            self.tracking = false
            if self.pressed { self.pressed = false; self.dirty.paint() }
            if was_tracking && self.items.len() > 0 && geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height).contains(event.position) {
                return self.select_as_user(self.segment_at(event.position.x))
            }
        }
        if event.kind == input.EventKind.key_down && self.items.len() > 0 {
            if event.key() == input.Key.right { return self.select_as_user((self.chosen + 1) % self.items.len()) }
            if event.key() == input.Key.left { return self.select_as_user((self.chosen + self.items.len() - 1) % self.items.len()) }
        }
        return none
    }
}
