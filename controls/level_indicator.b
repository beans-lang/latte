// How full something is.
package controls

import latte.platform
import latte.scene

/// A gauge: a battery, a signal, a rating, a disk.
///
/// **Not on every platform.** `NSLevelIndicator` and `GtkLevelBar` are real
/// controls; UIKit and the Win32 common controls have nothing that means it.
/// A `UIProgressView` is not one — a progress bar is work with a beginning and
/// an end, and a level is a reading that goes up and down and never finishes —
/// so latte refuses rather than drawing a bar and calling it a gauge. Ask
/// `WidgetKind.level_indicator.available()`, or let `of` refuse with
/// `no_such_control`.
///
/// It takes no input. There is no `set_enabled` on one, and the value only
/// ever comes from the program.
pub class LevelIndicator extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.level_indicator, context)
    }

    pub static fn of(context: scene.UiContext, low: f64, high: f64, level: f64) -> Result<LevelIndicator> {
        WidgetKind.level_indicator.demand()?
        var control: LevelIndicator = new LevelIndicator(context)
        control.set_range(low, high)?
        control.set_level(level)?
        return ok(control)
    }

    pub fn set_range(low: f64, high: f64) -> Result<bool> {
        self.set_property_real(platform.P_MIN, low)?
        return self.set_property_real(platform.P_MAX, high)
    }

    pub fn set_level(level: f64) -> Result<bool> {
        return self.set_property_real(platform.P_VALUE, level)
    }

    pub fn level() -> Result<f64> {
        return self.read_real(platform.P_VALUE, "read a level indicator's level")
    }

    pub fn low() -> Result<f64> {
        return self.read_real(platform.P_MIN, "read a level indicator's lowest value")
    }

    pub fn high() -> Result<f64> {
        return self.read_real(platform.P_MAX, "read a level indicator's highest value")
    }
}
