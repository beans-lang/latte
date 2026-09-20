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
    /// Where this node sits in a grid, one-based, and how big that grid is.
    /// Zero for everything that is not part of one — which is nearly
    /// everything, and is why it is four numbers rather than a second class.
    ///
    /// A virtual table has to carry these. Its rows are the dozen on screen,
    /// so a reader that counted what it was given would say "row 3 of 12" in
    /// the middle of ten million.
    row_value: int = 0
    column_value: int = 0
    rows_value: int = 0
    columns_value: int = 0
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
    pub fn row() -> int { return self.row_value }
    pub fn column() -> int { return self.column_value }
    pub fn rows() -> int { return self.rows_value }
    pub fn columns() -> int { return self.columns_value }
    pub fn in_grid() -> bool {
        return self.row_value > 0 || self.column_value > 0 ||
               self.rows_value > 0 || self.columns_value > 0
    }
    pub fn set_grid(row: int, column: int, rows: int, columns: int) {
        self.row_value = row; self.column_value = column
        self.rows_value = rows; self.columns_value = columns
    }
}

/// Where an input method should put its editing element, and what it is
/// editing. `rect` is the caret, in the object's own coordinates.
pub class EditingSpot {
    pub text: string
    pub anchor: int
    pub caret: int
    pub rect: geometry.Rect
    pub fn init(text: string, anchor: int, caret: int, rect: geometry.Rect) {
        self.text = text
        self.anchor = anchor
        self.caret = caret
        self.rect = rect
    }
}
