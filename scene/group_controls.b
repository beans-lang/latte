package scene

import latte.geometry
import latte.paint
import latte.input
import latte.platform

pub class GroupBoxRender extends BoxRender {
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) { super.init(renderer, theme, dirty) }
    pub override fn role() -> string { return "group" }
    pub override fn needs_template() -> bool { return true }
    pub override fn content_inset() -> geometry.EdgeInsets {
        return geometry.EdgeInsets { left: 8.0, top: 28.0, right: 8.0, bottom: 8.0 }
    }
    pub override fn child_offset() -> geometry.Point { return geometry.Point.at(8.0, 28.0) }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        let paragraph: paint.Paragraph = self.renderer.paragraph(self.words, self.font_size(), -1.0, self.text_color())?
        return ok(geometry.Size.of(paragraph.size().width + 14.0, 24.0))
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> { super.paint_self(canvas)?; return self.paint_template(canvas) }
}

pub class DisclosureRender extends BoxRender {
    expanded: bool = false
    tracking: bool = false
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.focusable = true
    }
    pub override fn role() -> string { return "group" }
    pub override fn needs_template() -> bool { return true }
    pub fn is_expanded() -> bool { return self.expanded }
    pub override fn shows_children() -> bool { return self.expanded }
    pub override fn content_inset() -> geometry.EdgeInsets {
        return geometry.EdgeInsets { left: 8.0, top: 30.0, right: 8.0, bottom: 8.0 }
    }
    pub override fn child_offset() -> geometry.Point { return geometry.Point.at(8.0, 30.0) }
    pub override fn semantics_at(bounds: geometry.Rect) -> SemanticsNode {
        let label: string = if self.a11y_name == "" { self.words } else { self.a11y_name }
        return new SemanticsNode(self.identity, self.role(), label, if self.expanded { "open" } else { "closed" }, bounds, self.enabled)
    }
    pub override fn set_integer(key: int, value: int) -> Result<bool> {
        if key != platform.P_EXPANDED { return super.set_integer(key, value) }
        self.demand_alive()?
        if value != 0 && value != 1 { return err("invalid disclosure state", "out_of_range") }
        if self.expanded == (value == 1) { return ok(false) }
        self.expanded = value == 1
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub override fn integer(key: int) -> Result<int> {
        if key == platform.P_EXPANDED { self.demand_alive()?; return ok(if self.expanded { 1 } else { 0 }) }
        return super.integer(key)
    }
    pub override fn set_value_as_user(index: int, value: f64) -> Result<bool> {
        return self.set_integer(platform.P_EXPANDED, index)
    }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        let paragraph: paint.Paragraph = self.renderer.paragraph(self.words, self.font_size(), -1.0, self.text_color())?
        return ok(geometry.Size.of(paragraph.size().width + 22.0, 24.0))
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> { super.paint_self(canvas)?; return self.paint_template(canvas) }
    fn toggle() -> Option<input.UiEvent> {
        self.expanded = !self.expanded
        self.dirty.paint(); self.dirty.semantics()
        let change: input.UiEvent = input.UiEvent.of(input.EventKind.value_changed, platform.Handle.of(self.identity))
        change.index = if self.expanded { 1 } else { 0 }
        return some(change)
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT && event.position.y < 30.0 {
            self.tracking = true; return none
        }
        if event.kind == input.EventKind.pointer_up {
            let was_tracking: bool = self.tracking
            self.tracking = false
            if was_tracking && event.position.y < 30.0 { return self.toggle() }
        }
        if event.kind == input.EventKind.key_down && (event.key() == input.Key.space || event.key() == input.Key.ret) { return self.toggle() }
        return none
    }
}
