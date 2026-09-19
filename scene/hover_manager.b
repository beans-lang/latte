package scene

import latte.geometry

/// The hovered path belongs to one window and holds only checked handles.
/// Pointer capture does not change which control is under the pointer.
pub class HoverManager {
    registry: RenderRegistry
    focus: FocusManager
    path: Map<u64, bool> = {}
    pub fn init(registry: RenderRegistry, focus: FocusManager) {
        self.registry = registry; self.focus = focus
    }
    pub fn update(root: RenderObject, point: geometry.Point) {
        var next: Map<u64, bool> = {}
        var target: Option<RenderObject> = none
        if point.x >= 0.0 && point.y >= 0.0 { target = root.hit_test(point) }
        for target != none {
            match target {
                some(object) => {
                    if !self.focus.interactive(object) { break }
                    next[object.handle()] = true
                    object.hover_changed(true)
                    target = self.registry.get(object.parent())
                }
                none => {}
            }
        }
        for handle: u64 in self.path.keys() {
            if !next.get(handle).or(false) {
                match self.registry.get(handle) { some(object) => { object.hover_changed(false) } none => {} }
            }
        }
        self.path = move next
    }
    pub fn validate() {
        for handle: u64 in self.path.keys() {
            match self.registry.get(handle) {
                some(object) => { if !self.focus.interactive(object) { self.forget(handle) } }
                none => { self.path.remove(handle) }
            }
        }
    }
    pub fn forget(handle: u64) {
        if !self.path.get(handle).or(false) { return }
        match self.registry.get(handle) { some(object) => { object.hover_changed(false) } none => {} }
        self.path.remove(handle)
    }
    pub fn clear() { for handle: u64 in self.path.keys() { self.forget(handle) } }
}
