package scene

import latte.input
import latte.platform

/// Owns focus for one window. It keeps handles, never references to controls.
pub class FocusManager {
    registry_value: RenderRegistry
    router_value: input.EventRouter
    focused_handle: u64 = 0
    pub fn init(registry: RenderRegistry, router: input.EventRouter) {
        self.registry_value = registry; self.router_value = router
    }
    pub fn current() -> u64 { return self.focused_handle }
    pub fn forget(handle: u64) { if self.focused_handle == handle { self.focused_handle = 0 } }
    pub fn validate() {
        match self.registry_value.get(self.focused_handle) {
            some(object) => { if !object.is_focusable() || !self.interactive(object) { self.clear() } }
            none => { self.focused_handle = 0 }
        }
    }
    pub fn advance(root: RenderObject, backward: bool) -> Result<bool> {
        var order: List<u64> = []
        self.focus_order(root, order)
        if order.len() == 0 { return ok(false) }
        var next: int = if backward { order.len() - 1 } else { 0 }
        for index: int in 0..order.len() {
            if order[index] == self.focused_handle {
                next = (index + if backward { order.len() - 1 } else { 1 }) % order.len()
            }
        }
        return self.focus(order[next])
    }
    pub fn focus(handle: u64) -> Result<bool> {
        match self.registry_value.get(handle) {
            none => { return err("cannot focus stale render object", "stale") }
            some(object) => {
                if !object.is_focusable() || !self.interactive(object) { return err("render object cannot take focus", "unsupported") }
                if self.focused_handle == handle { return ok(false) }
                match self.registry_value.get(self.focused_handle) {
                    some(previous) => {
                        previous.focus_changed(false)
                        self.router_value.deliver(input.UiEvent.of(input.EventKind.blur, platform.Handle.of(previous.handle())))
                    }
                    none => {}
                }
                self.focused_handle = handle
                object.focus_changed(true)
                self.router_value.deliver(input.UiEvent.of(input.EventKind.focus, platform.Handle.of(handle)))
                return ok(true)
            }
        }
    }
    pub fn interactive(object: RenderObject) -> bool {
        if !object.is_alive() || !object.is_enabled() || object.is_hidden() { return false }
        if object.parent() == 0 { return true }
        match self.registry_value.get(object.parent()) {
            some(parent) => {
                if parent.is_visual_child(object.handle()) {
                    return parent.interactive_visual() && self.interactive(parent)
                }
                if !parent.shows_children() || !self.interactive(parent) { return false }
                for index: int in 0..parent.child_count() {
                    match parent.child_at(index) {
                        some(child) => { if child.handle() == object.handle() { return parent.shows_child(index) } }
                        none => {}
                    }
                }
                return false
            }
            none => { return false }
        }
    }
    pub fn clear() {
        let previous: u64 = self.focused_handle
        self.focused_handle = 0
        match self.registry_value.get(previous) {
            some(object) => {
                object.focus_changed(false)
                self.router_value.deliver(input.UiEvent.of(input.EventKind.blur, platform.Handle.of(previous)))
            }
            none => {}
        }
    }
    fn focus_order(root: RenderObject, order: List<u64>) {
        if root.is_hidden() || !root.is_enabled() || !root.is_alive() { return }
        if root.is_focusable() { order.push(root.handle()) }
        if root.interactive_visual() {
            match root.visual() { some(visual) => { self.focus_order(visual, order) } none => {} }
        }
        if !root.shows_children() { return }
        for index: int in 0..root.child_count() {
            if !root.shows_child(index) { continue }
            match root.child_at(index) { some(child) => { self.focus_order(child, order) } none => {} }
        }
    }
}
