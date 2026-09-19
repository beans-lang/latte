// Which button, when a pointer has more than one.
package input

import latte.platform

/// A pointer button.
///
/// Three, because that is what every desktop pointer has and what every
/// platform here already calls them: a trackpad's tap is `left` and its
/// two-finger tap is `right` on all of them. A finger has no button at all,
/// so every touch on a phone is `left` — which is what UIKit itself reports
/// and what a program written against this already handles.
pub enum(u8) PointerButton {
    left
    right
    middle

    pub fn code() -> int {
        return match self {
            left => platform.BTN_LEFT,
            right => platform.BTN_RIGHT,
            middle => platform.BTN_MIDDLE,
        }
    }

    /// The button a number names. Anything else is `left`: a pointer event
    /// always came from *some* button, and inventing a fourth name for a
    /// number no host sends would be a case nobody could ever handle.
    pub static fn of(code: int) -> PointerButton {
        if code == platform.BTN_RIGHT { return PointerButton.right }
        if code == platform.BTN_MIDDLE { return PointerButton.middle }
        return PointerButton.left
    }

    pub fn name() -> string {
        return match self {
            left => "left",
            right => "right",
            middle => "middle",
        }
    }
}
