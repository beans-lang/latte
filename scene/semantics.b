package scene

import latte.geometry

/// A value snapshot. OS adapters translate it; they do not decide its meaning.
pub class SemanticsNode {
    id_value: u64
    role_value: string
    label_value: string
    value_value: string
    bounds_value: geometry.Rect
    enabled_value: bool
    pub fn init(id: u64, role: string, label: string, value: string,
                bounds: geometry.Rect, enabled: bool) {
        self.id_value = id
        self.role_value = role
        self.label_value = label
        self.value_value = value
        self.bounds_value = bounds
        self.enabled_value = enabled
    }
    pub fn id() -> u64 { return self.id_value }
    pub fn role() -> string { return self.role_value }
    pub fn label() -> string { return self.label_value }
    pub fn value() -> string { return self.value_value }
    pub fn bounds() -> geometry.Rect { return self.bounds_value }
    pub fn enabled() -> bool { return self.enabled_value }
}
