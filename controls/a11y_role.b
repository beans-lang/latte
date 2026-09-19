// What a control a program draws itself calls itself.
package controls

import latte.platform

/// The word a screen reader is given for a `Canvas`. Four existing ones and no
/// new ones; carried by a canvas alone, so no control can misdescribe itself.
pub enum(u8) A11yRole {
    /// Whatever the kind says — `group` for a canvas. The default, so no
    /// screen that exists today changes what it reports.
    automatic
    /// Something you press.
    button
    /// A picture.
    image
    /// An area with things in it.
    group

    pub fn code() -> int {
        return match self {
            automatic => platform.A11Y_AUTO,
            button => platform.A11Y_BUTTON,
            image => platform.A11Y_IMAGE,
            group => platform.A11Y_GROUP,
        }
    }

    pub fn name() -> string {
        return match self {
            automatic => "automatic",
            button => "button",
            image => "image",
            group => "group",
        }
    }

    pub static fn of(code: int) -> Option<A11yRole> {
        if code == platform.A11Y_AUTO { return some(A11yRole.automatic) }
        if code == platform.A11Y_BUTTON { return some(A11yRole.button) }
        if code == platform.A11Y_IMAGE { return some(A11yRole.image) }
        if code == platform.A11Y_GROUP { return some(A11yRole.group) }
        return none
    }
}
