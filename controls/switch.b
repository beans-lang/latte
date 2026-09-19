// A control the user flips.
package controls

import latte.platform
import latte.scene

/// An on/off switch.
///
/// The platform's own — `NSSwitch`, `UISwitch`, `GtkSwitch` — and **the first
/// control latte has that is not on every platform**. The Win32 common
/// controls have no toggle switch: Windows has them, but they live in WinUI,
/// which is a different toolkit and not something an `HWND` can be. So a
/// program asks before it builds one.
///
/// `Switch.of` refuses with `no_such_control` where there is none, and
/// `WidgetKind.switch.available()` is the question on its own. What latte
/// will not do is draw an imitation, or quietly hand back a check box: the
/// first is a control that is wrong in a way the user can see and the program
/// cannot, and the second ships a design reviewed on a Mac to Windows as
/// something else.
///
/// **Two states, never three.** A check box can be mixed, because "some of the
/// things this box stands for" is a real answer; a switch is one thing and is
/// on or off. Writing the mixed value through the property bag is
/// `out_of_range` on every host, which is why `set_on` takes a `bool` and
/// there is no `CheckState` here.
pub class Switch extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.switch, context)
    }

    /// A switch already in a known position.
    ///
    /// Refuses where the platform has no switch, rather than handing back a
    /// control that is not alive and letting the first property write fail
    /// with `stale_handle` — a message about a handle, for a problem about a
    /// platform.
    pub static fn of(context: scene.UiContext, on: bool) -> Result<Switch> {
        WidgetKind.switch.demand()?
        var control: Switch = new Switch(context)
        control.set_on(on)?
        return ok(control)
    }

    pub fn set_on(on: bool) -> Result<bool> {
        return self.set_flag(platform.P_CHECKED, on, "flip a switch")
    }

    pub fn is_on() -> Result<bool> {
        return self.read_flag(platform.P_CHECKED, "read whether a switch is on")
    }
}
