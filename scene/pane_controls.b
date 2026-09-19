package scene

import latte.geometry
import latte.paint
import latte.input
import latte.platform

pub class TabViewRender extends BoxRender {
    titles: List<string> = []
    chosen: int = 0
    borderless_value: bool = false
    revision: int = 0
    tracking: bool = false
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.focusable = true
    }
    pub override fn role() -> string { return "tablist" }
    pub override fn needs_template() -> bool { return true }
    /// The band the tab row takes above the content, which moves with the
    /// control size the way the row itself does.
    fn tab_band() -> f64 {
        if self.borderless_value { return 0.0 }
        return self.theme.control_height() + self.theme.spacing()
    }
    pub override fn content_inset() -> geometry.EdgeInsets {
        return geometry.EdgeInsets { left: 0.0, top: self.tab_band(), right: 0.0, bottom: 0.0 }
    }
    pub override fn child_offset() -> geometry.Point {
        return geometry.Point.at(0.0, self.tab_band())
    }
    pub override fn shows_child(index: int) -> bool { return index == self.chosen }
    pub fn selected() -> int { return self.chosen }
    pub fn borderless() -> bool { return self.borderless_value }
    pub fn labels_version() -> int { return self.revision }
    /// The tab row is the segmented control AppKit draws there, so its tabs are
    /// sized the same way: each title plus the measured padding, centred as a
    /// group above the box.
    pub fn tab_widths() -> List<f64> {
        var widths: List<f64> = []
        let padding: f64 = self.theme.segment_padding()
        for title: string in self.titles {
            var run: f64 = 0.0
            match self.renderer.styled_paragraph(title, self.text_style(), -1.0, self.text_color()) {
                ok(paragraph) => { run = paragraph.size().width }
                err(problem) => {}
            }
            widths.push(run + padding)
        }
        return move widths
    }
    pub fn labels() -> List<string> {
        var copy: List<string> = []
        for title: string in self.titles { copy.push(title) }
        return move copy
    }
    pub fn label(index: int) -> Result<string> {
        self.demand_alive()?
        if index < 0 || index >= self.titles.len() { return err("tab label index is outside the list", "out_of_range") }
        return ok(self.titles[index])
    }
    pub fn set_labels(labels: List<string>) -> Result<bool> {
        self.demand_alive()?
        var copy: List<string> = []
        for label: string in labels { copy.push(label) }
        self.titles = move copy
        self.revision += 1
        self.dirty.layout(); self.dirty.semantics()
        return ok(true)
    }
    pub fn set_label(index: int, label: string) -> Result<bool> {
        self.demand_alive()?
        if index < 0 || index >= self.child_count() { return err("tab label index is outside the pages", "out_of_range") }
        for self.titles.len() <= index { self.titles.push("") }
        self.titles[index] = label
        self.revision += 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub override fn set_integer(key: int, value: int) -> Result<bool> {
        if key == platform.P_BORDERLESS {
            self.demand_alive()?
            if value != 0 && value != 1 { return err("invalid borderless flag", "out_of_range") }
            if self.borderless_value == (value == 1) { return ok(false) }
            self.borderless_value = value == 1
            self.dirty.layout()
            return ok(true)
        }
        if key == platform.P_SELECTED {
            self.demand_alive()?
            if value < 0 || value > 100000 { return err("invalid tab index", "out_of_range") }
            if self.chosen == value { return ok(false) }
            self.chosen = value
            self.dirty.paint(); self.dirty.semantics()
            return ok(true)
        }
        return super.set_integer(key, value)
    }
    pub override fn integer(key: int) -> Result<int> {
        self.demand_alive()?
        if key == platform.P_BORDERLESS { return ok(if self.borderless_value { 1 } else { 0 }) }
        if key == platform.P_SELECTED { return ok(self.chosen) }
        return super.integer(key)
    }
    pub override fn set_value_as_user(index: int, value: f64) -> Result<bool> {
        self.demand_alive()?
        if index < 0 || index >= self.child_count() { return err("tab index is outside the pages", "out_of_range") }
        return self.set_integer(platform.P_SELECTED, index)
    }
    pub override fn semantics() -> SemanticsNode {
        let label: string = if self.a11y_name == "" { self.words } else { self.a11y_name }
        let value: string = if self.chosen >= 0 && self.chosen < self.titles.len() { self.titles[self.chosen] } else { "" }
        return new SemanticsNode(self.identity, self.role(), label, value, self.bounds, self.enabled)
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> { super.paint_self(canvas)?; return self.paint_template(canvas) }
    fn select_as_user(index: int) -> Option<input.UiEvent> {
        if index < 0 || index >= self.child_count() || index == self.chosen { return none }
        self.chosen = index
        self.dirty.paint(); self.dirty.semantics()
        let change: input.UiEvent = input.UiEvent.of(input.EventKind.value_changed, platform.Handle.of(self.identity))
        change.index = index
        return some(change)
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT && event.position.y < 30.0 { self.tracking = true; return none }
        if event.kind == input.EventKind.pointer_up {
            let was_tracking: bool = self.tracking
            self.tracking = false
            if was_tracking && event.position.y < 30.0 && self.child_count() > 0 && self.bounds.width > 0.0 {
                let index: int = (event.position.x * self.child_count() as f64 / self.bounds.width) as int
                return self.select_as_user(index)
            }
        }
        if event.kind == input.EventKind.key_down && self.child_count() > 0 {
            if event.key() == input.Key.right { return self.select_as_user((self.chosen + 1) % self.child_count()) }
            if event.key() == input.Key.left { return self.select_as_user((self.chosen + self.child_count() - 1) % self.child_count()) }
        }
        return none
    }
    pub override fn focus_changed(focused: bool) {
        super.focus_changed(focused)
        if !focused { self.tracking = false }
    }
}

pub class SplitViewRender extends BoxRender {
    stacked_value: bool = false
    divider_value: f64 = 160.0
    tracking: bool = false
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) { super.init(renderer, theme, dirty) }
    pub override fn role() -> string { return "separator" }
    pub override fn needs_template() -> bool { return true }
    pub fn stacked() -> bool { return self.stacked_value }
    pub fn divider() -> f64 { return self.divider_value }
    pub override fn content_inset() -> geometry.EdgeInsets {
        return if self.stacked_value {
            geometry.EdgeInsets { left: 0.0, top: 0.0, right: 0.0, bottom: 6.0 }
        } else {
            geometry.EdgeInsets { left: 0.0, top: 0.0, right: 6.0, bottom: 0.0 }
        }
    }
    pub override fn set_integer(key: int, value: int) -> Result<bool> {
        if key != platform.P_AXIS { return super.set_integer(key, value) }
        self.demand_alive()?
        if value != 0 && value != 1 { return err("invalid split axis", "out_of_range") }
        if self.stacked_value == (value == 1) { return ok(false) }
        self.stacked_value = value == 1
        self.dirty.layout()
        return ok(true)
    }
    pub override fn integer(key: int) -> Result<int> {
        if key == platform.P_AXIS { self.demand_alive()?; return ok(if self.stacked_value { 1 } else { 0 }) }
        return super.integer(key)
    }
    pub override fn set_real(key: int, value: f64) -> Result<bool> {
        if key != platform.P_DIVIDER { return super.set_real(key, value) }
        self.demand_alive()?
        if !(value >= 0.0 && value < 10000000.0) { return err("invalid split divider", "out_of_range") }
        if self.divider_value == value { return ok(false) }
        self.divider_value = value
        self.dirty.layout(); self.dirty.semantics()
        return ok(true)
    }
    pub override fn real(key: int) -> Result<f64> {
        if key == platform.P_DIVIDER { self.demand_alive()?; return ok(self.divider_value) }
        return super.real(key)
    }
    pub override fn set_value_as_user(index: int, value: f64) -> Result<bool> { return self.set_real(platform.P_DIVIDER, value) }
    pub override fn value_event_index(index: int, value: f64) -> int { return self.divider_value as int }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> { super.paint_self(canvas)?; return self.paint_template(canvas) }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        let position: f64 = if self.stacked_value { event.position.y } else { event.position.x }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT {
            self.tracking = position >= self.divider_value - 4.0 && position <= self.divider_value + 10.0
            return none
        }
        if event.kind == input.EventKind.pointer_up { self.tracking = false }
        if event.kind == input.EventKind.pointer_move && self.tracking {
            let along: f64 = if self.stacked_value { self.bounds.height } else { self.bounds.width }
            var next: f64 = position
            if next < 0.0 { next = 0.0 }
            if next > along - 6.0 { next = along - 6.0 }
            if next == self.divider_value { return none }
            self.divider_value = next
            self.dirty.layout()
            let change: input.UiEvent = input.UiEvent.of(input.EventKind.value_changed, platform.Handle.of(self.identity))
            change.index = next as int
            return some(change)
        }
        return none
    }
}
