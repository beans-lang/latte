package scene

import latte.geometry
import latte.paint
import latte.visual
import std.math

/// A retained, typed drawing node. Its state and placement stay in Beans.
pub class VisualRender extends RenderObject {
    kind_value: visual.Kind
    fill_value: int = 0
    stroke_value: int = 0
    stroke_width_value: f64 = 0.0
    rotation_value: f64 = 0.0
    scale_x_value: f64 = 1.0
    scale_y_value: f64 = 1.0
    gradient_start_value: int = 0
    gradient_end_value: int = 0
    gradient_start_set: bool = false
    gradient_end_set: bool = false
    shadow_color_value: int = 0
    shadow_blur_value: f64 = 0.0
    shadow_dx_value: f64 = 0.0
    shadow_dy_value: f64 = 0.0
    clip_radius_value: f64 = 0.0
    image_value: Option<paint.ImageResource> = none
    transition_seconds_value: f64 = 0.0
    transition_easing_value: int = 0
    stroke_cap_value: int = 0
    stroke_join_value: int = 0
    offset_x_value: f64 = 0.0
    offset_y_value: f64 = 0.0
    transitions_armed: bool = false
    scalar_tweens: Map<int, ScalarTween> = {}
    color_tweens: Map<int, ColorTween> = {}

    pub fn init(renderer: paint.Renderer, theme: Theme, dirty: Invalidation, kind: visual.Kind) {
        self.kind_value = kind
        super.init(renderer, theme, dirty)
    }
    pub override fn role() -> string { return "image" }

    /// A drawing has no words, so it offers no accessible name of its own.
    ///
    /// The base class uses a node's text as its name, which is right for a
    /// label and a button and wrong here: this node's text is the shape's SVG
    /// path data, and a screen reader read "M8 32 L32 8 L56 32 Z" aloud. A
    /// drawing that means something says so with `a11y_label`; one that does
    /// not is decoration and is better left silent.
    pub override fn semantics_at(bounds: geometry.Rect) -> SemanticsNode {
        return new SemanticsNode(self.identity,
            if self.a11y_role == "" { self.role() } else { self.a11y_role },
            self.a11y_name, self.a11y_value, bounds, self.enabled)
    }
    pub fn arm_transitions() { self.transitions_armed = true }
    pub override fn animating() -> bool {
        return self.scalar_tweens.len() > 0 || self.color_tweens.len() > 0
    }
    pub override fn advance(seconds: f64) -> Result<bool> {
        self.demand_alive()?
        if !(seconds >= 0.0 && seconds < 10000000.0) { return err("invalid frame delta", "out_of_range") }
        if seconds == 0.0 { return ok(false) }
        let before: geometry.Rect = self.visual_frame()
        var changed: bool = false
        for key: int in self.scalar_tweens.keys() {
            match self.scalar_tweens.get(key) {
                some(tween) => {
                    self.apply_real(key, tween.advance(seconds))
                    if tween.done() { self.scalar_tweens.remove(key) }
                    changed = true
                }
                none => {}
            }
        }
        for key: int in self.color_tweens.keys() {
            match self.color_tweens.get(key) {
                some(tween) => {
                    self.apply_color(key, tween.advance(seconds))
                    if tween.done() { self.color_tweens.remove(key) }
                    changed = true
                }
                none => {}
            }
        }
        if changed {
            self.dirty.paint()
            let after: geometry.Rect = self.visual_frame()
            if before.x != after.x || before.y != after.y ||
               before.width != after.width || before.height != after.height {
                self.dirty.semantics()
            }
        }
        return ok(changed)
    }
    pub override fn set_text(value: string) -> Result<bool> {
        self.demand_alive()?
        if self.kind_value != visual.Kind.path && self.kind_value != visual.Kind.resource_image {
            return err("only a Path or ResourceImage has source text", "wrong_kind")
        }
        if self.text() == value { return ok(false) }
        if self.kind_value == visual.Kind.resource_image { self.image_value = none }
        return super.set_text(value)
    }
    fn color_at(key: int) -> int {
        if key == visual.FILL { return self.fill_value }
        if key == visual.STROKE { return self.stroke_value }
        if key == visual.GRADIENT_START { return self.gradient_start_value }
        if key == visual.GRADIENT_END { return self.gradient_end_value }
        return self.shadow_color_value
    }
    fn apply_color(key: int, value: int) {
        if key == visual.FILL { self.fill_value = value }
        else if key == visual.STROKE { self.stroke_value = value }
        else if key == visual.GRADIENT_START { self.gradient_start_value = value }
        else if key == visual.GRADIENT_END { self.gradient_end_value = value }
        else if key == visual.SHADOW_COLOR { self.shadow_color_value = value }
    }
    fn change_color(key: int, value: int) -> Result<bool> {
        let current: int = self.color_at(key)
        match self.color_tweens.get(key) {
            some(tween) => { if tween.destination() == value { return ok(false) } }
            none => { if current == value { return ok(false) } }
        }
        self.color_tweens.remove(key)
        if self.transitions_armed && self.transition_seconds_value > 0.0 && current != value {
            self.color_tweens[key] = new ColorTween(current, value,
                self.transition_seconds_value, self.transition_easing_value)
            self.dirty.request_animation(self.handle())
        } else { self.apply_color(key, value) }
        self.dirty.paint()
        if key == visual.SHADOW_COLOR { self.dirty.semantics() }
        return ok(true)
    }
    fn real_at(key: int) -> f64 {
        if key == visual.OFFSET_X { return self.offset_x_value }
        if key == visual.OFFSET_Y { return self.offset_y_value }
        if key == visual.STROKE_WIDTH { return self.stroke_width_value }
        if key == visual.ROTATION { return self.rotation_value }
        if key == visual.SCALE_X { return self.scale_x_value }
        if key == visual.SCALE_Y { return self.scale_y_value }
        if key == visual.SHADOW_BLUR { return self.shadow_blur_value }
        if key == visual.SHADOW_DX { return self.shadow_dx_value }
        if key == visual.SHADOW_DY { return self.shadow_dy_value }
        return self.clip_radius_value
    }
    fn apply_real(key: int, value: f64) {
        if key == visual.OFFSET_X { self.offset_x_value = value }
        else if key == visual.OFFSET_Y { self.offset_y_value = value }
        else if key == visual.STROKE_WIDTH { self.stroke_width_value = value }
        else if key == visual.ROTATION { self.rotation_value = value }
        else if key == visual.SCALE_X { self.scale_x_value = value }
        else if key == visual.SCALE_Y { self.scale_y_value = value }
        else if key == visual.SHADOW_BLUR { self.shadow_blur_value = value }
        else if key == visual.SHADOW_DX { self.shadow_dx_value = value }
        else if key == visual.SHADOW_DY { self.shadow_dy_value = value }
        else if key == visual.CLIP_RADIUS { self.clip_radius_value = value }
    }
    fn change_real(key: int, value: f64) -> Result<bool> {
        let current: f64 = self.real_at(key)
        match self.scalar_tweens.get(key) {
            some(tween) => { if tween.destination() == value { return ok(false) } }
            none => { if current == value { return ok(false) } }
        }
        self.scalar_tweens.remove(key)
        if self.transitions_armed && self.transition_seconds_value > 0.0 && current != value {
            self.scalar_tweens[key] = new ScalarTween(current, value,
                self.transition_seconds_value, self.transition_easing_value)
            self.dirty.request_animation(self.handle())
        } else { self.apply_real(key, value) }
        self.dirty.paint()
        self.dirty.semantics()
        return ok(true)
    }
    pub override fn set_integer(key: int, value: int) -> Result<bool> {
        self.demand_alive()?
        if key == visual.TRANSITION_EASING {
            if value < 0 || value > 1 { return err("transition_easing must be linear or ease_in_out", "out_of_range") }
            if self.transition_easing_value == value { return ok(false) }
            self.transition_easing_value = value
            return ok(true)
        }
        if key == visual.STROKE_CAP || key == visual.STROKE_JOIN {
            if value < 0 || value > 2 { return err("stroke cap and join run from 0 to 2", "out_of_range") }
            if key == visual.STROKE_CAP {
                if self.stroke_cap_value == value { return ok(false) }
                self.stroke_cap_value = value
            } else {
                if self.stroke_join_value == value { return ok(false) }
                self.stroke_join_value = value
            }
            self.dirty.paint()
            return ok(true)
        }
        if key == visual.FILL || key == visual.STROKE || key == visual.SHADOW_COLOR {
            return self.change_color(key, value)
        }
        if key == visual.GRADIENT_START {
            let was_set: bool = self.gradient_start_set
            self.gradient_start_set = true
            let changed: bool = self.change_color(key, value)?
            if !was_set { self.dirty.paint() }
            return ok(changed || !was_set)
        }
        if key == visual.GRADIENT_END {
            let was_set: bool = self.gradient_end_set
            self.gradient_end_set = true
            let changed: bool = self.change_color(key, value)?
            if !was_set { self.dirty.paint() }
            return ok(changed || !was_set)
        }
        return super.set_integer(key, value)
    }
    pub override fn integer(key: int) -> Result<int> {
        self.demand_alive()?
        if key == visual.FILL { return ok(self.fill_value) }
        if key == visual.STROKE { return ok(self.stroke_value) }
        if key == visual.GRADIENT_START { return ok(self.gradient_start_value) }
        if key == visual.GRADIENT_END { return ok(self.gradient_end_value) }
        if key == visual.SHADOW_COLOR { return ok(self.shadow_color_value) }
        if key == visual.STROKE_CAP { return ok(self.stroke_cap_value) }
        if key == visual.STROKE_JOIN { return ok(self.stroke_join_value) }
        if key == visual.TRANSITION_EASING { return ok(self.transition_easing_value) }
        return super.integer(key)
    }
    pub fn reset_gradient(key: int) -> Result<bool> {
        self.demand_alive()?
        self.color_tweens.remove(key)
        if key == visual.GRADIENT_START {
            self.gradient_start_value = 0; self.gradient_start_set = false
        } else if key == visual.GRADIENT_END {
            self.gradient_end_value = 0; self.gradient_end_set = false
        } else { return err("not a gradient property", "wrong_kind") }
        self.dirty.paint()
        return ok(true)
    }
    pub override fn set_real(key: int, value: f64) -> Result<bool> {
        self.demand_alive()?
        if key == visual.TRANSITION_SECONDS {
            if !(value >= 0.0 && value <= 60.0) { return err("transition_seconds must be 0 to 60", "out_of_range") }
            if self.transition_seconds_value == value { return ok(false) }
            self.transition_seconds_value = value
            return ok(true)
        }
        if key == visual.STROKE_WIDTH || key == visual.ROTATION ||
           key == visual.SCALE_X || key == visual.SCALE_Y ||
           key == visual.SHADOW_BLUR || key == visual.SHADOW_DX ||
           key == visual.SHADOW_DY || key == visual.CLIP_RADIUS ||
           key == visual.OFFSET_X || key == visual.OFFSET_Y {
            if !(value > -100000.0 && value < 100000.0) {
                return err("invalid drawing transform or stroke width", "out_of_range")
            }
            if key == visual.STROKE_WIDTH {
                if value < 0.0 { return err("stroke_width cannot be negative", "out_of_range") }
            } else if key == visual.SCALE_X {
                if value <= 0.0 { return err("scale_x must be positive", "out_of_range") }
            } else if key == visual.SCALE_Y {
                if value <= 0.0 { return err("scale_y must be positive", "out_of_range") }
            } else if key == visual.SHADOW_BLUR {
                if value < 0.0 { return err("shadow_blur cannot be negative", "out_of_range") }
            } else if key == visual.CLIP_RADIUS {
                if value < 0.0 { return err("clip_radius cannot be negative", "out_of_range") }
            }
            return self.change_real(key, value)
        }
        return super.set_real(key, value)
    }
    pub override fn real(key: int) -> Result<f64> {
        self.demand_alive()?
        if key == visual.OFFSET_X { return ok(self.offset_x_value) }
        if key == visual.OFFSET_Y { return ok(self.offset_y_value) }
        if key == visual.STROKE_WIDTH { return ok(self.stroke_width_value) }
        if key == visual.ROTATION { return ok(self.rotation_value) }
        if key == visual.SCALE_X { return ok(self.scale_x_value) }
        if key == visual.SCALE_Y { return ok(self.scale_y_value) }
        if key == visual.SHADOW_BLUR { return ok(self.shadow_blur_value) }
        if key == visual.SHADOW_DX { return ok(self.shadow_dx_value) }
        if key == visual.SHADOW_DY { return ok(self.shadow_dy_value) }
        if key == visual.CLIP_RADIUS { return ok(self.clip_radius_value) }
        if key == visual.TRANSITION_SECONDS { return ok(self.transition_seconds_value) }
        return super.real(key)
    }
    pub override fn paint_self(canvas: paint.Canvas) -> Result<bool> {
        canvas.save()?
        let width: f64 = self.frame().width
        let height: f64 = self.frame().height
        // The offset moves the whole drawing, so it goes outside the rotation
        // and the scale: a knob that slides must not also swing.
        canvas.translate(self.offset_x_value, self.offset_y_value)?
        canvas.translate(width / 2.0, height / 2.0)?
        canvas.rotate(self.rotation_value)?
        canvas.scale(self.scale_x_value, self.scale_y_value)?
        canvas.translate(-width / 2.0, -height / 2.0)?
        let rect: geometry.Rect = self.painted_box()
        if self.kind_value == visual.Kind.resource_image {
            if self.text() == "" { canvas.restore()?; return ok(true) }
            match self.image_value {
                some(decoded) => {
                    if self.clip_radius_value > 0.0 { canvas.clip(rect, self.clip_radius_value)? }
                    canvas.image(decoded, rect)?
                }
                none => {
                    let decoded: paint.ImageResource = self.renderer.image(self.text())?
                    self.image_value = some(decoded)
                    if self.clip_radius_value > 0.0 { canvas.clip(rect, self.clip_radius_value)? }
                    canvas.image(decoded, rect)?
                }
            }
            canvas.restore()?
            return ok(true)
        }
        let style: paint.VisualStyle = paint.VisualStyle {
            fill: self.fill_value, outline: self.stroke_value, stroke_width: self.stroke_width_value,
            gradient_start: self.gradient_start_value, gradient_end: self.gradient_end_value,
            gradient_enabled: self.gradient_start_set && self.gradient_end_set,
            shadow_color: self.shadow_color_value, shadow_blur: self.shadow_blur_value,
            shadow_dx: self.shadow_dx_value, shadow_dy: self.shadow_dy_value,
            // A rounded rectangle carries its corner radius in the same field;
            // for every other kind the value is the clip it always was.
            clip_radius: if self.kind_value == visual.Kind.rectangle && self.radius > 0.0 {
                self.radius
            } else { self.clip_radius_value },
            stroke_cap: self.stroke_cap_value, stroke_join: self.stroke_join_value
        }
        match self.kind_value {
            // A rounded drawn rectangle is one clip radius away from a plain
            // one, and it is what a knob with a shadow needs.
            rectangle => {
                if self.radius > 0.0 {
                    canvas.visual(3, rect, "", style)?
                } else {
                    canvas.visual(0, rect, "", style)?
                }
            }
            ellipse => { canvas.visual(1, rect, "", style)? }
            path => { canvas.visual(2, rect, self.text(), style)? }
            resource_image => {}
        }
        canvas.restore()?
        return ok(true)
    }
    /// Decorative drawings do not take pointer focus from controls behind them.
    pub override fn hit_test(point: geometry.Point) -> Option<RenderObject> { return none }

    /// Axis-aligned outer bounds of the transformed drawing, for semantics.
    pub override fn visual_frame() -> geometry.Rect {
        let frame: geometry.Rect = self.frame()
        let radians: f64 = self.rotation_value * 3.141592653589793 / 180.0
        let cosine: f64 = math.cos(radians)
        let sine: f64 = math.sin(radians)
        let half_w: f64 = frame.width * self.scale_x_value / 2.0
        let half_h: f64 = frame.height * self.scale_y_value / 2.0
        let outer_w: f64 = (if cosine < 0.0 { -cosine } else { cosine }) * half_w +
                           (if sine < 0.0 { -sine } else { sine }) * half_h
        let outer_h: f64 = (if sine < 0.0 { -sine } else { sine }) * half_w +
                           (if cosine < 0.0 { -cosine } else { cosine }) * half_h
        var left: f64 = frame.x + self.offset_x_value + frame.width / 2.0 - outer_w
        var top: f64 = frame.y + self.offset_y_value + frame.height / 2.0 - outer_h
        var right: f64 = left + outer_w * 2.0
        var bottom: f64 = top + outer_h * 2.0
        if (self.shadow_color_value & 255) != 0 {
            let shift_x: f64 = cosine * self.shadow_dx_value * self.scale_x_value -
                               sine * self.shadow_dy_value * self.scale_y_value
            let shift_y: f64 = sine * self.shadow_dx_value * self.scale_x_value +
                               cosine * self.shadow_dy_value * self.scale_y_value
            let bigger_scale: f64 = if self.scale_x_value > self.scale_y_value {
                self.scale_x_value
            } else { self.scale_y_value }
            let spread: f64 = self.shadow_blur_value * bigger_scale * 3.0
            if left + shift_x - spread < left { left = left + shift_x - spread }
            if top + shift_y - spread < top { top = top + shift_y - spread }
            if right + shift_x + spread > right { right = right + shift_x + spread }
            if bottom + shift_y + spread > bottom { bottom = bottom + shift_y + spread }
        }
        return geometry.Rect.of(left, top, right - left, bottom - top)
    }
}
