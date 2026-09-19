package scene

import latte.geometry
import latte.paint
import latte.input
import latte.platform

pub class BoxRender extends RenderObject {
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) { super.init(renderer, theme, dirty) }
    pub override fn accepts_children() -> bool { return true }
}

pub class TextRender extends RenderObject {
    paragraph_value: Option<paint.Paragraph> = none
    measured_text: string = ""
    measured_style: paint.TextStyle = paint.TextStyle { size: -1.0 }
    measured_width: f64 = -2.0
    measured_color: int = -1
    measured_valid: bool = false
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) { super.init(renderer, theme, dirty) }
    pub override fn role() -> string { return "text" }
    pub fn shaped(width: f64) -> Result<paint.Paragraph> {
        let text: string = self.visible_text()
        let style: paint.TextStyle = self.text_style()
        let color: int = self.text_color()
        if self.measured_valid && self.measured_text == text && self.measured_style.same(style) &&
           self.measured_width == width && self.measured_color == color {
            match self.paragraph_value { some(value) => { return ok(value) } none => {} }
        }
        let paragraph: paint.Paragraph = self.renderer.styled_paragraph(text, style, width, color)?
        self.paragraph_value = some(paragraph)
        self.measured_text = text; self.measured_style = style
        self.measured_width = width; self.measured_color = color
        self.measured_valid = true
        return ok(paragraph)
    }
    pub fn visible_text() -> string { return self.words }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        self.demand_alive()?
        // Label is single-line. Measure and paint the same unwrapped paragraph.
        let paragraph: paint.Paragraph = self.shaped(-1.0)?
        let size: geometry.Size = paragraph.size()
        // A run reports the height its face needs; a macOS line box is what the
        // system layout manager gives that point size. Reporting the smaller of
        // the two is what pushes a control's text off its native baseline.
        let line: f64 = Theme.line_height(self.font_size())
        return ok(geometry.Size.of(size.width, if line > size.height { line } else { size.height }))
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> {
        super.paint_self(canvas)?
        let paragraph: paint.Paragraph = self.shaped(-1.0)?
        let size: geometry.Size = paragraph.size()
        let y: f64 = self.text_top(paragraph, size.height)
        let spare_x: f64 = self.bounds.width - size.width
        var x: f64 = 0.0
        if spare_x > 0.0 {
            if self.alignment == 1 { x = spare_x / 2.0 }
            if self.alignment == 2 { x = spare_x }
        }
        return canvas.paragraph(paragraph, x, y)
    }
    /// Where the line box goes. With a baseline target the box is placed so the
    /// baseline lands exactly there; otherwise the line is centred.
    fn text_top(paragraph: paint.Paragraph, height: f64) -> f64 {
        if self.baseline_target >= 0.0 {
            return self.baseline_target - paragraph.metrics().baseline
        }
        let spare: f64 = self.bounds.height - height
        return if spare > 0.0 { spare / 2.0 } else { 0.0 }
    }
}

/// Shared behavior; the optional visual is built from a .bx control template.
/// A template never receives pointer/keyboard ownership from its control.
pub class ButtonRender extends RenderObject {
    prominent_value: bool = false
    checked_value: bool = false
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        super.init(renderer, theme, dirty)
        self.focusable = true
    }
    pub override fn role() -> string { return "button" }
    pub override fn needs_template() -> bool { return true }
    /// Filled with the accent: the button a screen leads with, and the menu
    /// row the pointer or keyboard is on.
    pub fn prominent() -> bool { return self.prominent_value }
    /// A button that is on. A menu row uses it for its mark.
    pub fn checked() -> bool { return self.checked_value }
    pub override fn set_integer(key: int, value: int) -> Result<bool> {
        if key == platform.P_CHECKED {
            self.demand_alive()?
            if value != 0 && value != 1 { return err("a button is on or off", "out_of_range") }
            if self.checked_value == (value == 1) { return ok(false) }
            self.checked_value = value == 1
            self.dirty.paint(); self.dirty.semantics()
            return ok(true)
        }
        if key != platform.P_PROMINENT { return super.set_integer(key, value) }
        self.demand_alive()?
        if value != 0 && value != 1 { return err("prominent is on or off", "out_of_range") }
        self.prominent_value = value == 1
        self.dirty.paint()
        return ok(true)
    }
    pub override fn integer(key: int) -> Result<int> {
        if key == platform.P_CHECKED { self.demand_alive()?; return ok(if self.checked_value { 1 } else { 0 }) }
        if key == platform.P_PROMINENT { self.demand_alive()?; return ok(if self.prominent_value { 1 } else { 0 }) }
        return super.integer(key)
    }
    pub override fn measure(available: geometry.Size) -> Result<geometry.Size> {
        self.demand_alive()?
        let paragraph: paint.Paragraph = self.renderer.styled_paragraph(self.words, self.text_style(), -1.0, self.text_color())?
        let padding: f64 = self.theme.control_padding()
        return ok(geometry.Size.of(paragraph.size().width + padding * 2.0, self.theme.control_height()))
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> {
        super.paint_self(canvas)?
        return self.paint_template(canvas)
    }
    pub override fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> {
        if !self.enabled || self.hidden || !self.alive { return none }
        if event.kind == input.EventKind.pointer_down && event.index == platform.BTN_LEFT {
            self.pressed = true; self.dirty.paint()
        }
        if event.kind == input.EventKind.pointer_up {
            let was_pressed: bool = self.pressed
            self.pressed = false; self.dirty.paint()
            if was_pressed && geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height).contains(event.position) {
                return some(input.UiEvent.of(input.EventKind.activate, platform.Handle.of(self.identity)))
            }
        }
        if event.kind == input.EventKind.key_down &&
           (event.key() == input.Key.ret || event.key() == input.Key.space) {
            return some(input.UiEvent.of(input.EventKind.activate, platform.Handle.of(self.identity)))
        }
        return none
    }
    pub override fn focus_changed(focused: bool) {
        super.focus_changed(focused)
        if !focused { self.pressed = false }
    }
}

pub class ScrollRender extends BoxRender {
    offset: geometry.Point = geometry.Point.zero()
    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) { super.init(renderer, theme, dirty) }
    pub override fn role() -> string { return "scrollarea" }
    pub override fn clips_children() -> bool { return true }
    pub override fn child_offset() -> geometry.Point { return geometry.Point.at(-self.offset.x, -self.offset.y) }
    pub override fn set_content_size(size: geometry.Size) -> Result<bool> {
        self.demand_alive()?
        if !(size.width >= 0.0 && size.width < 10000000.0 && size.height >= 0.0 && size.height < 10000000.0) {
            return err("invalid scroll content size", "out_of_range")
        }
        self.content = size
        return self.scroll_to(self.offset)
    }
    pub fn scroll_to(offset: geometry.Point) -> Result<bool> {
        self.demand_alive()?
        if !(offset.x > -10000000.0 && offset.x < 10000000.0 && offset.y > -10000000.0 && offset.y < 10000000.0) {
            return err("invalid scroll offset", "out_of_range")
        }
        var x: f64 = offset.x; var y: f64 = offset.y
        let right: f64 = self.content.width - self.bounds.width
        let bottom: f64 = self.content.height - self.bounds.height
        if x > right { x = right }
        if y > bottom { y = bottom }
        if x < 0.0 { x = 0.0 }
        if y < 0.0 { y = 0.0 }
        if self.offset.x == x && self.offset.y == y { return ok(false) }
        self.offset = geometry.Point.at(x, y)
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub override fn scroll_by(dx: f64, dy: f64) -> Result<bool> {
        return self.scroll_to(geometry.Point.at(self.offset.x + dx, self.offset.y + dy))
    }
}
