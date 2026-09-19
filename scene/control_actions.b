package scene

/// A removable template's action service. It carries a checked handle rather
/// than the owning control or window, and cannot retain a UiContext cycle.
pub class ControlActions {
    registry: RenderRegistry
    input: InputManager
    popups: PopupManager
    owner: u64
    pub fn init(registry: RenderRegistry, input: InputManager, popups: PopupManager, owner: u64) {
        self.registry = registry; self.input = input; self.popups = popups; self.owner = owner
    }
    pub fn choose(index: int, value: f64) -> Result<bool> {
        return self.input.set_value_as_user(self.owner, index, value)
    }
    pub fn commit_cell(row: int, column: int, text: string) -> Result<bool> {
        return self.input.commit_cell(self.owner, row, column, text)
    }
    pub fn cancel_cell() -> Result<bool> { return self.input.cancel_cell(self.owner) }
    pub fn dismiss() {
        match self.registry.get(self.owner) { some(object) => { object.dismiss_popup() } none => {} }
        if self.popups.owner() == self.owner { self.popups.dismiss() }
    }
}
