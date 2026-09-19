package scene

import latte.geometry
import latte.paint
import latte.platform
import latte.input

/// Retained UI state in Beans. Parents own children; a child stores only its
/// parent's handle. Resources and invalidation have no reference back here.
pub abstract class RenderObject {
    identity: u64 = 0
    parent_id: u64 = 0
    visual_parent_id: u64 = 0
    alive: bool = true
    bounds: geometry.Rect = geometry.Rect.zero()
    contents: List<RenderObject> = []
    renderer: paint.Renderer
    theme: Theme
    dirty: Invalidation
    words: string = ""
    enabled: bool = true
    hidden: bool = false
    focusable: bool = false
    has_focus: bool = false
    has_hover: bool = false
    pressed: bool = false
    background: int = 0
    foreground: int = -1
    border_color: int = 0
    border_width: f64 = 0.0
    radius: f64 = 0.0
    /// 0 leading, 1 center, 2 trailing — the same three the hosts take.
    alignment: int = 0
    font: f64 = 0.0
    /// 0 the kind's own weight, then light, regular, medium, semibold, bold, heavy.
    weight: int = 0
    /// Where this control's text baseline must land, from the top of its box.
    /// Below zero centres the line, which is what a plain label does.
    baseline_target: f64 = -1.0
    /// How far this node's own drawing reaches past its layout box.
    overhang: f64 = 0.0
    a11y_name: string = ""
    a11y_role: string = ""
    a11y_value: string = ""
    content: geometry.Size = geometry.Size.zero()
    template_visual: Option<RenderObject> = none

    fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation) {
        self.renderer = renderer
        self.theme = theme
        self.dirty = dirty
    }
    pub fn handle() -> u64 { return self.identity }
    pub fn parent() -> u64 { return if self.parent_id != 0 { self.parent_id } else { self.visual_parent_id } }
    pub fn is_alive() -> bool { return self.alive }
    pub fn is_hidden() -> bool { return self.hidden }
    pub fn is_enabled() -> bool { return self.enabled }
    pub fn is_focusable() -> bool { return self.focusable && self.enabled && !self.hidden && self.alive }
    pub fn focused() -> bool { return self.has_focus }
    pub fn hovered() -> bool { return self.has_hover }
    pub fn hover_changed(hovered: bool) {
        if !self.alive || self.has_hover == hovered { return }
        self.has_hover = hovered; self.dirty.paint()
    }
    pub fn is_pressed() -> bool { return self.pressed }
    pub fn needs_template() -> bool { return false }
    pub fn popup_open() -> bool { return false }
    pub fn dismiss_popup() {}
    pub fn popup_bounds() -> geometry.Rect { return geometry.Rect.zero() }
    pub fn animating() -> bool { return false }
    pub fn advance(seconds: f64) -> Result<bool> { return ok(false) }
    pub fn interactive_visual() -> bool { return false }
    pub fn visual_focus_requested() -> bool { return false }
    pub fn acknowledge_visual_focus() {}
    pub fn on_cell_cancel() -> Result<bool> {
        self.demand_alive()?
        return err("this control does not accept a cell edit", "unsupported")
    }
    pub fn visual_offset() -> geometry.Point { return geometry.Point.zero() }
    pub fn template_size() -> geometry.Size { return self.bounds.size() }
    pub fn visual() -> Option<RenderObject> { return self.template_visual }
    pub fn is_visual_child(handle: u64) -> bool {
        match self.template_visual { some(visual) => { return visual.handle() == handle } none => {} }
        return false
    }
    pub fn set_visual(visual: Option<RenderObject>) -> Result<bool> {
        self.demand_alive()?
        match visual {
            some(root) => {
                root.demand_alive()?
                if self.is_visual_child(root.handle()) { return ok(false) }
                if !root.belongs_to(self.dirty) { return err("template belongs to another window", "bad_owner") }
                if root.parent_id != 0 || (root.visual_parent_id != 0 && root.visual_parent_id != self.identity) || root.contains_handle(self.identity) {
                    return err("template already has an owner or creates a cycle", "bad_parent")
                }
            }
            none => {}
        }
        match self.template_visual {
            some(previous) => { previous.enabled = false; previous.visual_parent_id = 0 }
            none => {}
        }
        self.template_visual = visual
        match visual { some(root) => { root.visual_parent_id = self.identity } none => {} }
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn paint_template(canvas: paint.Canvas) -> Result<bool> {
        match self.template_visual {
            some(visual) => {
                let offset: geometry.Point = self.visual_offset()
                canvas.save()?
                canvas.translate(offset.x, offset.y)?
                visual.record(canvas)?
                canvas.restore()?
                return ok(true)
            }
            none => {}
        }
        return err("shared control requires a .bx template", "missing_template")
    }
    pub fn frame() -> geometry.Rect { return self.bounds }
    /// The painted box: the layout box grown by the overhang. Layout never
    /// reads this, which is the whole point of having the two.
    pub fn visual_frame() -> geometry.Rect {
        if self.overhang <= 0.0 { return self.bounds }
        return geometry.Rect.of(self.bounds.x - self.overhang, self.bounds.y - self.overhang,
            self.bounds.width + self.overhang * 2.0, self.bounds.height + self.overhang * 2.0)
    }
    /// The same box in this node's own coordinates, for painting.
    pub fn painted_box() -> geometry.Rect {
        return geometry.Rect.of(0.0 - self.overhang, 0.0 - self.overhang,
            self.bounds.width + self.overhang * 2.0, self.bounds.height + self.overhang * 2.0)
    }
    pub fn child_count() -> int { return self.contents.len() }
    pub fn child_at(index: int) -> Option<RenderObject> {
        if index < 0 || index >= self.contents.len() { return none }
        return some(self.contents[index])
    }
    pub fn demand_alive() -> Result<bool> {
        if !self.alive { return err("render object was released", "stale") }
        return ok(true)
    }
    pub fn belongs_to(invalidation: Invalidation) -> bool { return self.dirty == invalidation }
    pub fn set_frame(rect: geometry.Rect) -> Result<bool> {
        self.demand_alive()?
        if !(rect.x > -10000000.0 && rect.x < 10000000.0 && rect.y > -10000000.0 && rect.y < 10000000.0 &&
             rect.width >= 0.0 && rect.height >= 0.0 && rect.width < 10000000.0 && rect.height < 10000000.0) {
            return err("invalid render bounds", "out_of_range")
        }
        if self.bounds.x == rect.x && self.bounds.y == rect.y &&
           self.bounds.width == rect.width && self.bounds.height == rect.height { return ok(false) }
        self.bounds = rect
        self.dirty.paint()
        self.dirty.semantics()
        return ok(true)
    }
    pub fn text() -> string { return self.words }
    pub fn set_text(text: string) -> Result<bool> {
        self.demand_alive()?
        if self.words == text { return ok(false) }
        self.words = text
        self.dirty.layout()
        return ok(true)
    }
    pub fn set_string(key: int, value: string) -> Result<bool> {
        self.demand_alive()?
        if key == platform.S_A11Y_LABEL {
            self.a11y_name = value
            self.dirty.semantics()
            return ok(true)
        }
        return err("string property is not supported by this shared control", "unsupported")
    }
    pub fn string_at(key: int) -> Result<string> {
        self.demand_alive()?
        if key == platform.S_A11Y_LABEL { return ok(if self.a11y_name == "" { self.words } else { self.a11y_name }) }
        return err("string property is not supported by this shared control", "unsupported")
    }
    pub fn set_integer(key: int, value: int) -> Result<bool> {
        self.demand_alive()?
        if key == platform.P_ENABLED { self.enabled = value != 0 }
        else if key == platform.P_HIDDEN { self.hidden = value != 0 }
        else if key == platform.P_FOCUSABLE { self.focusable = value != 0 }
        else if key == platform.P_BG_COLOR { self.background = value }
        else if key == platform.P_FG_COLOR { self.foreground = value }
        else if key == platform.P_BORDER_COLOR { self.border_color = value }
        else if key == platform.P_ALIGNMENT {
            if value < 0 || value > 2 { return err("text alignment is leading, center or trailing", "out_of_range") }
            self.alignment = value
        }
        else if key == platform.P_FONT_WEIGHT {
            if value < 0 || value > 6 { return err("font weight runs from 0 to 6", "out_of_range") }
            self.weight = value
            self.dirty.layout()
        }
        else { return err("integer property is not supported by this shared control", "unsupported") }
        self.dirty.paint()
        if key == platform.P_ENABLED || key == platform.P_HIDDEN || key == platform.P_FOCUSABLE { self.dirty.semantics() }
        return ok(true)
    }
    pub fn integer(key: int) -> Result<int> {
        self.demand_alive()?
        if key == platform.P_ENABLED { return ok(if self.enabled { 1 } else { 0 }) }
        if key == platform.P_HIDDEN { return ok(if self.hidden { 1 } else { 0 }) }
        if key == platform.P_FOCUSABLE { return ok(if self.focusable { 1 } else { 0 }) }
        if key == platform.P_BG_COLOR { return ok(self.background) }
        if key == platform.P_FG_COLOR { return ok(self.text_color()) }
        if key == platform.P_BORDER_COLOR { return ok(self.border_color) }
        if key == platform.P_ALIGNMENT { return ok(self.alignment) }
        if key == platform.P_FONT_WEIGHT { return ok(self.weight) }
        return err("integer property is not supported by this shared control", "unsupported")
    }
    pub fn set_real(key: int, value: f64) -> Result<bool> {
        self.demand_alive()?
        if !(value >= 0.0 && value < 10000000.0) { return err("invalid shared control property", "out_of_range") }
        if key == platform.P_FONT_SIZE { self.font = value; self.dirty.layout() }
        else if key == platform.P_BASELINE { self.baseline_target = value }
        else if key == platform.P_OVERHANG { self.overhang = value; self.dirty.semantics() }
        else if key == platform.P_CORNER_RADIUS { self.radius = value }
        else if key == platform.P_BORDER_WIDTH { self.border_width = value }
        else { return err("real property is not supported by this shared control", "unsupported") }
        self.dirty.paint()
        return ok(true)
    }
    pub fn real(key: int) -> Result<f64> {
        self.demand_alive()?
        if key == platform.P_FONT_SIZE { return ok(self.font_size()) }
        if key == platform.P_BASELINE { return ok(self.baseline_target) }
        if key == platform.P_OVERHANG { return ok(self.overhang) }
        if key == platform.P_CORNER_RADIUS { return ok(self.radius) }
        if key == platform.P_BORDER_WIDTH { return ok(self.border_width) }
        return err("real property is not supported by this shared control", "unsupported")
    }
    pub fn font_size() -> f64 { return if self.font > 0.0 { self.font } else { self.theme.font_size() } }
    pub fn font_weight() -> int { return self.weight }
    /// The one place a control's text style is assembled, so size, weight,
    /// tracking and alignment can never be set apart from each other.
    pub fn text_style() -> paint.TextStyle {
        return paint.TextStyle {
            size: self.font_size(), weight: self.weight, tracking: self.theme.tracking()
        }
    }
    pub fn text_color() -> int { return if self.foreground >= 0 { self.foreground } else { self.theme.foreground() } }
    pub fn clear_text_color() -> Result<bool> {
        self.demand_alive()?
        if self.foreground == -1 { return ok(false) }
        self.foreground = -1
        self.dirty.paint()
        return ok(true)
    }
    pub fn measure(available: geometry.Size) -> Result<geometry.Size> { return ok(geometry.Size.zero()) }
    pub fn role() -> string { return "group" }
    pub fn exclusive_choice() -> bool { return false }
    pub fn clear_choice() {}
    pub fn value_event_index(index: int, value: f64) -> int { return index }
    pub fn value_event_value(index: int, value: f64) -> f64 { return value }
    pub fn value_event_text(index: int, value: f64) -> string { return "" }
    pub fn set_value_as_user(index: int, value: f64) -> Result<bool> {
        self.demand_alive()?
        return err("this control does not accept a user value", "unsupported")
    }
    pub fn on_cell_commit(row: int, column: int, text: string) -> Result<bool> {
        self.demand_alive()?
        return err("this control does not accept a cell edit", "unsupported")
    }
    /// Release subclass-owned callbacks and sources even if an external caller
    /// retains the now-stale render object.
    pub fn on_dispose() {}
    pub fn scroll_by(dx: f64, dy: f64) -> Result<bool> { return ok(false) }
    pub fn accepts_children() -> bool { return false }
    pub fn shows_children() -> bool { return true }
    pub fn shows_child(index: int) -> bool { return true }
    pub fn content_inset() -> geometry.EdgeInsets { return geometry.EdgeInsets.all(0.0) }
    pub fn set_content_size(size: geometry.Size) -> Result<bool> {
        return err("this control does not scroll", "wrong_kind")
    }
    pub fn content_size() -> geometry.Size { return self.content }
    pub fn child_offset() -> geometry.Point { return geometry.Point.zero() }
    pub fn child_offset_for(handle: u64) -> geometry.Point {
        return if self.is_visual_child(handle) { self.visual_offset() } else { self.child_offset() }
    }
    pub fn clips_children() -> bool { return false }

    pub fn semantics() -> SemanticsNode {
        return new SemanticsNode(self.identity, if self.a11y_role == "" { self.role() } else { self.a11y_role },
            if self.a11y_name == "" { self.words } else { self.a11y_name }, self.a11y_value, self.visual_frame(), self.enabled)
    }
    pub fn set_semantics(role: string, label: string, value: string) -> Result<bool> {
        self.demand_alive()?
        if self.a11y_role == role && self.a11y_name == label && self.a11y_value == value { return ok(false) }
        self.a11y_role = role; self.a11y_name = label; self.a11y_value = value
        self.dirty.semantics()
        return ok(true)
    }
    pub fn paint_self(canvas: paint.Canvas) -> Result<bool> {
        let box: geometry.Rect = self.painted_box()
        if self.background != 0 { canvas.rectangle(box, self.radius, self.background, 0.0)? }
        if self.border_width > 0.0 { canvas.rectangle(box, self.radius, self.border_color, self.border_width)? }
        return ok(true)
    }
    pub fn record(canvas: paint.Canvas) -> Result<bool> {
        self.demand_alive()?
        if self.hidden || self.bounds.width <= 0.0 || self.bounds.height <= 0.0 { return ok(false) }
        canvas.save()?
        canvas.translate(self.bounds.x, self.bounds.y)?
        self.paint_self(canvas)?
        if self.clips_children() {
            canvas.clip(geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height), self.radius)?
        }
        let offset: geometry.Point = self.child_offset()
        canvas.translate(offset.x, offset.y)?
        if self.shows_children() {
            for index: int in 0..self.contents.len() {
                if self.shows_child(index) { self.contents[index].record(canvas)? }
            }
        }
        canvas.restore()?
        return ok(true)
    }
    pub fn hit_test(point: geometry.Point) -> Option<RenderObject> {
        if !self.alive || self.hidden || !self.enabled { return none }
        let local: geometry.Point = geometry.Point.at(point.x - self.bounds.x, point.y - self.bounds.y)
        let inside: bool = geometry.Rect.of(0.0, 0.0, self.bounds.width, self.bounds.height).contains(local)
        if !inside && self.clips_children() { return none }
        if inside && self.interactive_visual() {
            match self.template_visual {
                some(visual) => {
                    let offset: geometry.Point = self.visual_offset()
                    match visual.hit_test(geometry.Point.at(local.x - offset.x, local.y - offset.y)) {
                        some(part) => { if part.is_focusable() { return some(part) } }
                        none => {}
                    }
                }
                none => {}
            }
        }
        let offset: geometry.Point = self.child_offset()
        let child_point: geometry.Point = geometry.Point.at(local.x - offset.x, local.y - offset.y)
        var index: int = if self.shows_children() { self.contents.len() } else { 0 }
        for index > 0 {
            index -= 1
            if !self.shows_child(index) { continue }
            match self.contents[index].hit_test(child_point) { some(found) => { return some(found) } none => {} }
        }
        if inside { return some(self) }
        return none
    }
    pub fn handle_event(event: input.UiEvent) -> Option<input.UiEvent> { return none }
    pub fn focus_changed(focused: bool) { self.has_focus = focused; self.dirty.paint(); self.dirty.semantics() }
    fn contains_handle(handle: u64) -> bool {
        if self.identity == handle { return true }
        for child: RenderObject in self.contents { if child.contains_handle(handle) { return true } }
        match self.template_visual { some(visual) => { if visual.contains_handle(handle) { return true } } none => {} }
        return false
    }
    pub fn insert(child: RenderObject, index: int) -> Result<bool> {
        self.demand_alive()?; child.demand_alive()?
        if !self.accepts_children() { return err("render object cannot hold children", "not_a_container") }
        if self.identity == 0 || child.identity == 0 || self.dirty != child.dirty {
            return err("render objects must belong to the same UI context", "bad_owner")
        }
        if index < 0 || index > self.contents.len() { return err("cannot insert child {index}: render object has {self.contents.len()} children", "out_of_range") }
        if child.parent_id != 0 || child.visual_parent_id != 0 || child.contains_handle(self.identity) {
            return err("render child already has a parent or creates a cycle", "bad_parent")
        }
        child.parent_id = self.identity
        self.contents.insert(index, child)
        self.dirty.layout()
        return ok(true)
    }
    pub fn remove(child: RenderObject) -> Result<bool> {
        self.demand_alive()?
        for index: int in 0..self.contents.len() {
            if self.contents[index].identity == child.identity {
                self.contents.remove(index)
                child.parent_id = 0
                self.dirty.layout()
                return ok(true)
            }
        }
        return err("render child is not attached", "bad_parent")
    }
    pub fn move_child(from: int, to: int) -> Result<bool> {
        self.demand_alive()?
        if from < 0 || to < 0 || from >= self.contents.len() || to >= self.contents.len() {
            return err("cannot move child {from} to {to}: render object has {self.contents.len()} children", "out_of_range")
        }
        let child: RenderObject = self.contents[from]
        self.contents.remove(from)
        self.contents.insert(to, child)
        self.dirty.layout()
        return ok(true)
    }
    fn dispose() {
        if !self.alive { return }
        self.alive = false
        self.on_dispose()
        self.dirty.animations().cancel(self.identity)
        self.has_focus = false
        self.has_hover = false
        match self.template_visual {
            some(visual) => { visual.enabled = false; visual.visual_parent_id = 0 }
            none => {}
        }
        self.template_visual = none
        self.visual_parent_id = 0
        for child: RenderObject in self.contents { child.parent_id = 0 }
        self.contents.clear()
        self.dirty.layout()
    }
}
