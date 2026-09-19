// How far along something is.
package controls

import latte.platform
import latte.scene

/// A bar showing progress through a known amount of work, or — when the
/// amount is not known — that work is happening at all.
///
/// The two are one control and not two, because which one a program needs
/// changes while it runs: a download is indeterminate until the server sends a
/// content length, and swapping one control for another at that moment would
/// make the bar jump.
pub class ProgressBar extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.progress_bar, context)
    }

    pub static fn of(context: scene.UiContext, low: f64, high: f64) -> Result<ProgressBar> {
        var control: ProgressBar = new ProgressBar(context)
        control.set_range(low, high)?
        return ok(control)
    }

    pub fn set_range(low: f64, high: f64) -> Result<bool> {
        self.set_property_real(platform.P_MIN, low)?
        return self.set_property_real(platform.P_MAX, high)
    }

    pub fn set_value(value: f64) -> Result<bool> {
        return self.set_property_real(platform.P_VALUE, value)
    }

    pub fn value() -> Result<f64> {
        return self.read_real(platform.P_VALUE, "read a progress bar's value")
    }

    /// Whether the total is unknown. An indeterminate bar animates; a
    /// determinate one shows its value.
    ///
    /// The animation is part of the same property rather than a second one: a
    /// bar that is indeterminate and not animating looks like a bar that has
    /// hung, which is the opposite of what it is there to say.
    pub fn set_indeterminate(on: bool) -> Result<bool> {
        return self.set_property(platform.P_INDETERMINATE, if on { 1 } else { 0 })
    }

    pub fn is_indeterminate() -> Result<bool> {
        return self.read_flag(platform.P_INDETERMINATE,
                              "read whether a progress bar is indeterminate")
    }
}
