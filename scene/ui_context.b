package scene

import latte.paint
import latte.geometry
import latte.input
import latte.platform

/// One context per window. The application assigns distinct namespace ids.
/// The context owns objects; objects never keep the context alive.
pub class UiContext {
    renderer_value: paint.Renderer
    theme_value: Theme
    invalidation_value: Invalidation
    registry_value: RenderRegistry
    router_value: input.EventRouter
    focus_value: FocusManager
    input_value: InputManager
    popup_value: PopupManager
    theme_version: int = -1
    closed: bool = false
    pub fn init(renderer: paint.Renderer, namespace: int) {
        self.renderer_value = renderer
        self.theme_value = new Theme()
        self.invalidation_value = new Invalidation()
        self.registry_value = new RenderRegistry(namespace)
        self.router_value = new input.EventRouter(false)
        self.focus_value = new FocusManager(self.registry_value, self.router_value)
        self.input_value = new InputManager(self.registry_value, self.router_value, self.focus_value, self.invalidation_value)
        self.popup_value = new PopupManager(self.registry_value, self.focus_value, self.input_value, self.invalidation_value)
    }
    pub fn renderer() -> paint.Renderer { return self.renderer_value }
    pub fn theme() -> Theme { return self.theme_value }
    pub fn invalidation() -> Invalidation { return self.invalidation_value }
    pub fn registry() -> RenderRegistry { return self.registry_value }
    pub fn router() -> input.EventRouter { return self.router_value }
    pub fn popups() -> PopupManager { return self.popup_value }
    pub fn actions(owner: u64) -> ControlActions {
        return new ControlActions(self.registry_value, self.input_value, self.popup_value, owner)
    }
    pub fn interactive(object: RenderObject) -> bool { return self.focus_value.interactive(object) }
    pub fn validate_input() {
        self.focus_value.validate(); self.input_value.validate_hover(); self.popup_value.validate()
    }
    pub fn has_active_animations() -> bool { return self.invalidation_value.animations().has_work() }
    pub fn advance(seconds: f64) -> Result<bool> {
        if self.closed { return err("UI context is closed", "stale") }
        if !(seconds >= 0.0 && seconds < 10000000.0) { return err("invalid frame delta", "out_of_range") }
        var changed: bool = false
        let queue: AnimationQueue = self.invalidation_value.animations()
        for handle: u64 in queue.handles() {
            match self.registry_value.get(handle) {
                none => { queue.cancel(handle) }
                some(object) => {
                    if object.advance(seconds)? { changed = true }
                    if !object.animating() { queue.cancel(handle) }
                }
            }
        }
        return ok(changed)
    }
    pub fn focused_object() -> Option<RenderObject> {
        self.focus_value.validate()
        return self.registry_value.get(self.focus_value.current())
    }
    pub fn global_frame(object: RenderObject) -> Result<geometry.Rect> {
        if !object.belongs_to(self.invalidation_value) { return err("object belongs to another context", "bad_owner") }
        object.demand_alive()?
        var bounds: geometry.Rect = object.frame()
        var parent: u64 = object.parent()
        var child: u64 = object.handle()
        for parent != 0 {
            match self.registry_value.get(parent) {
                none => { return err("object has a stale parent", "stale") }
                some(node) => {
                    bounds.x += node.frame().x + node.child_offset_for(child).x
                    bounds.y += node.frame().y + node.child_offset_for(child).y
                    child = node.handle()
                    parent = node.parent()
                }
            }
        }
        return ok(bounds)
    }
    pub fn set_value_as_user(handle: u64, index: int, value: f64) -> Result<bool> {
        return self.input_value.set_value_as_user(handle, index, value)
    }
    pub fn global_visual_frame(object: RenderObject) -> Result<geometry.Rect> {
        let positioned: geometry.Rect = self.global_frame(object)?
        let layout: geometry.Rect = object.frame()
        let visual: geometry.Rect = object.visual_frame()
        return ok(geometry.Rect.of(positioned.x + visual.x - layout.x,
            positioned.y + visual.y - layout.y, visual.width, visual.height))
    }
    pub fn scroll(root: RenderObject, point: geometry.Point, dx: f64, dy: f64) -> Result<bool> {
        match self.popup_value.root() {
            some(popup) => { return self.input_value.scroll(popup, point, dx, dy) }
            none => {}
        }
        return self.input_value.scroll(root, point, dx, dy)
    }
    pub fn add(object: RenderObject) -> Result<u64> {
        if self.closed { return err("UI context is closed", "stale") }
        if !object.belongs_to(self.invalidation_value) { return err("render object belongs to another context", "bad_owner") }
        return self.registry_value.add(object)
    }
    pub fn release(handle: u64) {
        match self.registry_value.get(handle) {
            some(object) => {
                self.forget_tree(object)
                self.registry_value.release(handle)
                self.popup_value.validate()
            }
            none => {}
        }
    }
    fn forget_tree(object: RenderObject) {
        match object.visual() { some(visual) => { self.forget_tree(visual) } none => {} }
        for index: int in 0..object.child_count() {
            match object.child_at(index) { some(child) => { self.forget_tree(child) } none => {} }
        }
        self.focus_value.forget(object.handle())
        self.input_value.forget(object.handle())
        self.router_value.forget(platform.Handle.of(object.handle()))
    }
    pub fn focus(handle: u64) -> Result<bool> { return self.focus_value.focus(handle) }
    pub fn clear_focus() {
        self.popup_value.dismiss(); self.focus_value.clear()
        self.input_value.cancel_capture(); self.input_value.clear_hover()
    }
    pub fn dispatch(event: input.UiEvent) -> Result<bool> {
        self.popup_value.validate()
        return self.input_value.dispatch(event)
    }
    pub fn pointer(root: RenderObject, kind: input.EventKind, position: geometry.Point, button: int, clicks: int = 1, modifiers: int = 0) -> Result<bool> {
        match self.popup_value.root() {
            some(popup) => {
                if kind == input.EventKind.pointer_down && popup.hit_test(position) == none {
                    self.popup_value.dismiss()
                    self.input_value.clear_hover()
                    return ok(true)
                }
                return self.input_value.pointer(popup, kind, position, button, clicks, modifiers)
            }
            none => {}
        }
        return self.input_value.pointer(root, kind, position, button, clicks, modifiers)
    }
    pub fn key(root: RenderObject, kind: input.EventKind, key: input.Key, text: string, modifiers: int) -> Result<bool> {
        match self.popup_value.root() {
            some(_) => {
                if kind == input.EventKind.key_down && (key == input.Key.escape || key == input.Key.tab) {
                    self.popup_value.dismiss()
                    if key == input.Key.escape { return ok(true) }
                }
            }
            none => {}
        }
        return self.input_value.key(root, kind, key, text, modifiers)
    }
    pub fn draw(root: RenderObject, size: geometry.Size, scale: f64) -> Result<bool> {
        if self.closed { return err("UI context is closed", "stale") }
        if !root.belongs_to(self.invalidation_value) { return err("paint root belongs to another context", "bad_owner") }
        self.focus_value.validate()
        self.input_value.validate_hover()
        if self.theme_version != self.theme_value.version() {
            self.theme_version = self.theme_value.version()
            self.invalidation_value.layout()
        }
        if !self.invalidation_value.needs_paint() { return ok(false) }
        let version: int = self.invalidation_value.paint_version()
        let commands: paint.DisplayList = new paint.DisplayList()
        root.record(commands)?
        match self.popup_value.root() { some(popup) => { popup.record(commands)? } none => {} }
        let canvas: paint.Canvas = self.renderer_value.begin(size, scale, self.theme_value.background())?
        match commands.replay(canvas) {
            err(problem) => { self.renderer_value.end(); return err(problem.msg, problem.kind) }
            ok(_) => {}
        }
        self.renderer_value.end()?
        self.invalidation_value.painted(version)
        return ok(true)
    }
    pub fn close() {
        if self.closed { return }
        self.closed = true
        self.popup_value.dismiss()
        self.input_value.clear_hover()
        // Forget callbacks before releasing registry entries.
        self.router_value.clear()
        self.registry_value.close()
        self.invalidation_value.animations().clear()
        self.focus_value.clear(); self.input_value.cancel_capture()
    }
    fn deinit() { self.close() }
}
