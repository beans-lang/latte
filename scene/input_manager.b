package scene

import latte.input
import latte.geometry
import latte.platform

/// Routes events through the retained tree and owns pointer capture. Controls
/// supply their own behavior through RenderObject.handle_event.
pub class InputManager {
    registry_value: RenderRegistry
    router_value: input.EventRouter
    focus_value: FocusManager
    invalidation_value: Invalidation
    hover_value: HoverManager
    captured_handle: u64 = 0
    pub fn init(registry: RenderRegistry, router: input.EventRouter, focus: FocusManager, dirty: Invalidation) {
        self.registry_value = registry; self.router_value = router
        self.focus_value = focus; self.invalidation_value = dirty
        self.hover_value = new HoverManager(registry, focus)
    }
    pub fn cancel_capture() { self.captured_handle = 0 }
    pub fn forget(handle: u64) {
        if self.captured_handle == handle { self.cancel_capture() }
        self.hover_value.forget(handle)
    }
    pub fn clear_hover() { self.hover_value.clear() }
    pub fn validate_hover() { self.hover_value.validate() }
    fn settle_choice(object: RenderObject) {
        if !object.exclusive_choice() { return }
        match self.registry_value.get(object.parent()) {
            some(parent) => {
                for index: int in 0..parent.child_count() {
                    match parent.child_at(index) {
                        some(sibling) => { if sibling.handle() != object.handle() { sibling.clear_choice() } }
                        none => {}
                    }
                }
            }
            none => {}
        }
    }
    pub fn set_value_as_user(handle: u64, index: int, value: f64) -> Result<bool> {
        match self.registry_value.get(handle) {
            none => { return err("value targets a stale render object", "stale") }
            some(object) => {
                if !self.focus_value.interactive(object) { return ok(false) }
                if !object.set_value_as_user(index, value)? { return ok(false) }
                self.settle_choice(object)
                let event: input.UiEvent = input.UiEvent.of(input.EventKind.value_changed, platform.Handle.of(handle))
                event.index = object.value_event_index(index, value)
                event.position = geometry.Point.at(object.value_event_value(index, value), 0.0)
                event.text = object.value_event_text(index, value)
                self.router_value.deliver(event)
                return ok(true)
            }
        }
    }
    pub fn scroll(root: RenderObject, point: geometry.Point, dx: f64, dy: f64) -> Result<bool> {
        if !root.belongs_to(self.invalidation_value) { return err("input root belongs to another context", "bad_owner") }
        if !(dx > -10000000.0 && dx < 10000000.0 && dy > -10000000.0 && dy < 10000000.0) {
            return err("invalid scroll delta", "out_of_range")
        }
        var target: Option<RenderObject> = root.hit_test(point)
        for target != none {
            match target {
                some(object) => {
                    if !self.focus_value.interactive(object) { return ok(false) }
                    if object.scroll_by(dx, dy)? { return ok(true) }
                    target = self.registry_value.get(object.parent())
                }
                none => {}
            }
        }
        return ok(false)
    }
    pub fn commit_cell(handle: u64, row: int, column: int, text: string) -> Result<bool> {
        match self.registry_value.get(handle) {
            none => { return err("cell edit targets a stale render object", "stale") }
            some(object) => {
                if !self.focus_value.interactive(object) { return ok(false) }
                if !object.on_cell_commit(row, column, text)? { return ok(false) }
                if object.is_focusable() { self.focus_value.focus(handle)? }
                let event: input.UiEvent = input.UiEvent.of(input.EventKind.text_commit, platform.Handle.of(handle))
                event.index = row; event.token = column; event.text = text
                self.router_value.deliver(event)
                return ok(true)
            }
        }
    }
    pub fn cancel_cell(handle: u64) -> Result<bool> {
        match self.registry_value.get(handle) {
            none => { return err("cell edit targets a stale render object", "stale") }
            some(object) => {
                if !self.focus_value.interactive(object) { return ok(false) }
                if !object.on_cell_cancel()? { return ok(false) }
                if object.is_focusable() { self.focus_value.focus(handle)? }
                return ok(true)
            }
        }
    }
    /// A key. **Not text** — see the refusal below.
    pub fn key(root: RenderObject, kind: input.EventKind, key: input.Key, text: string, modifiers: int) -> Result<bool> {
        if !root.belongs_to(self.invalidation_value) { return err("input root belongs to another context", "bad_owner") }
        // `index` means "which key" here and "where the replacement starts"
        // on a text event, and one field cannot mean both. Sending text down
        // this road set index to the key code — 0 for a key that types
        // something — and a text field read that as "replace bytes 0..0", so
        // every character landed at the start of the line and typing "Zoe"
        // produced "eoZ". It is refused by name rather than left to be
        // rediscovered: `UiContext.text_input` is the road, and it takes the
        // range explicitly.
        if kind == input.EventKind.text_input ||
           kind == input.EventKind.composition_update ||
           kind == input.EventKind.composition_cancel {
            return err("could not deliver {kind.name()} as a key: text carries a replacement range and a key carries a key code, and they share a field. Send it through text_input",
                       "wrong_road")
        }
        self.focus_value.validate()
        if kind == input.EventKind.key_down && key == input.Key.tab {
            return self.focus_value.advance(root, (modifiers & platform.MOD_SHIFT) != 0)
        }
        if self.focus_value.current() == 0 { return ok(false) }
        let event: input.UiEvent = input.UiEvent.of(kind, platform.Handle.of(self.focus_value.current()))
        event.index = key.code(); event.text = text; event.modifiers = modifiers
        return self.dispatch(event)
    }
    pub fn dispatch(event: input.UiEvent) -> Result<bool> {
        match self.registry_value.get(event.target.raw) {
            none => { return err("event targets a stale render object", "stale") }
            some(object) => {
                if !self.focus_value.interactive(object) { return ok(false) }
                let produced: Option<input.UiEvent> = object.handle_event(event)
                if produced != none { self.settle_choice(object) }
                self.router_value.deliver(event)
                match produced { some(action) => { self.router_value.deliver(action) } none => {} }
                return ok(true)
            }
        }
    }
    pub fn pointer(root: RenderObject, kind: input.EventKind, position: geometry.Point, button: int, clicks: int = 1, modifiers: int = 0) -> Result<bool> {
        if !root.belongs_to(self.invalidation_value) { return err("input root belongs to another context", "bad_owner") }
        self.hover_value.update(root, position)
        var target: Option<RenderObject> = self.registry_value.get(self.captured_handle)
        if target == none { target = root.hit_test(position) }
        match target {
            none => { return ok(false) }
            some(object) => {
                if kind == input.EventKind.pointer_down {
                    self.captured_handle = object.handle()
                    if object.is_focusable() { self.focus_value.focus(object.handle())? }
                }
                let event: input.UiEvent = input.UiEvent.of(kind, platform.Handle.of(object.handle()))
                var local: geometry.Point = position
                var here: Option<RenderObject> = some(object)
                for here != none {
                    match here {
                        some(node) => {
                            local.x -= node.frame().x; local.y -= node.frame().y
                            here = self.registry_value.get(node.parent())
                            match here {
                                some(parent) => { local.x -= parent.child_offset_for(node.handle()).x; local.y -= parent.child_offset_for(node.handle()).y }
                                none => {}
                            }
                        }
                        none => {}
                    }
                }
                event.position = local; event.index = button; event.token = clicks
                event.modifiers = modifiers
                if kind == input.EventKind.pointer_up { self.captured_handle = 0 }
                return self.dispatch(event)
            }
        }
    }
}
