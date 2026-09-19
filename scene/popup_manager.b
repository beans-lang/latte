package scene

import latte.platform

/// A window's topmost popup. TemplateSet owns its widgets and callbacks; this
/// manager keeps only checked handles and restores focus when it closes.
pub class PopupManager {
    registry: RenderRegistry
    focus: FocusManager
    input: InputManager
    dirty: Invalidation
    owner_id: u64 = 0
    root_id: u64 = 0
    pub fn init(registry: RenderRegistry, focus: FocusManager, input: InputManager, dirty: Invalidation) {
        self.registry = registry; self.focus = focus; self.input = input; self.dirty = dirty
    }
    pub fn owner() -> u64 { return self.owner_id }
    pub fn root() -> Option<RenderObject> { self.validate(); return self.registry.get(self.root_id) }
    pub fn show(owner: RenderObject, root: RenderObject) -> Result<bool> {
        owner.demand_alive()?; root.demand_alive()?
        if !owner.belongs_to(self.dirty) || !root.belongs_to(self.dirty) {
            return err("popup belongs to another window", "bad_owner")
        }
        if self.owner_id == owner.handle() && self.root_id == root.handle() { return ok(false) }
        self.dismiss()
        if !root.is_enabled() { root.set_integer(platform.P_ENABLED, 1)? }
        self.owner_id = owner.handle(); self.root_id = root.handle()
        if owner.is_focusable() { self.focus.focus(owner.handle())? }
        self.dirty.paint(); self.dirty.semantics()
        return ok(true)
    }
    pub fn validate() {
        if self.owner_id == 0 { return }
        match self.registry.get(self.owner_id) {
            some(owner) => {
                if owner.popup_open() && self.focus.interactive(owner) && self.registry.get(self.root_id) != none && self.owns_focus() { return }
            }
            none => {}
        }
        self.dismiss()
    }
    pub fn dismiss() {
        if self.owner_id == 0 { return }
        let owner: u64 = self.owner_id
        let restore: bool = self.owns_focus()
        match self.registry.get(self.root_id) { some(root) => { root.set_integer(platform.P_ENABLED, 0) } none => {} }
        self.owner_id = 0; self.root_id = 0
        self.input.cancel_capture()
        match self.registry.get(owner) {
            some(object) => {
                object.dismiss_popup()
                if restore && object.is_focusable() && self.focus.interactive(object) { self.focus.focus(owner) }
            }
            none => {}
        }
        self.dirty.paint(); self.dirty.semantics()
    }
    fn owns_focus() -> bool {
        var handle: u64 = self.focus.current()
        if handle == self.owner_id { return true }
        for handle != 0 {
            if handle == self.root_id { return true }
            match self.registry.get(handle) { some(object) => { handle = object.parent() } none => { return false } }
        }
        return false
    }
}
