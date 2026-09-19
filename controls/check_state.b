// On, off, or neither.
package controls

/// What a check box is showing.
///
/// `mixed` is a real third state, not an absence: a "select all" box over a
/// partial selection shows it, and every platform latte targets can draw it.
/// The three platforms spell it differently — `NSControlStateValueMixed`,
/// `BST_INDETERMINATE`, `gtk_check_button_set_inconsistent` — which is exactly
/// why it belongs in one enum here.
pub enum CheckState {
    off
    on
    mixed

    pub fn code() -> int {
        return match self {
            off => 0,
            on => 1,
            mixed => 2,
        }
    }

    pub fn name() -> string {
        return match self {
            off => "off",
            on => "on",
            mixed => "mixed",
        }
    }

    pub static fn of(code: int) -> CheckState {
        if code == 1 { return CheckState.on }
        if code == 2 { return CheckState.mixed }
        return CheckState.off
    }
}
