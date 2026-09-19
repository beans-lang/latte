// A value picked by dragging.
package controls

import latte.platform
import latte.scene

/// A control for choosing a number in a range.
///
/// Continuous by default: it reports every position as the thumb moves, not
/// only when it is let go. A slider that reported once at the end could not
/// drive a live preview, which is most of what sliders are for — and a program
/// that wants the other behaviour ignores the events until they stop.
pub class Slider extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.slider, context)
    }

    /// A slider over `low`..`high`, starting at `start`.
    pub static fn of(context: scene.UiContext, low: f64, high: f64, start: f64) -> Result<Slider> {
        var control: Slider = new Slider(context)
        control.set_range(low, high)?
        control.set_value(start)?
        return ok(control)
    }

    /// The ends of the range. Setting them is one call because a platform that
    /// clamps the value on each change would move it twice for one edit, and
    /// the intermediate position is not one anybody asked for.
    pub fn set_range(low: f64, high: f64) -> Result<bool> {
        self.set_property_real(platform.P_MIN, low)?
        return self.set_property_real(platform.P_MAX, high)
    }

    pub fn set_value(value: f64) -> Result<bool> {
        return self.set_property_real(platform.P_VALUE, value)
    }

    pub fn value() -> Result<f64> {
        return self.read_real(platform.P_VALUE, "read a slider's value")
    }

    pub fn low() -> Result<f64> {
        return self.read_real(platform.P_MIN, "read a slider's lowest value")
    }

    pub fn high() -> Result<f64> {
        return self.read_real(platform.P_MAX, "read a slider's highest value")
    }

    /// The increment the thumb lands on, or 0 for a continuous slider.
    ///
    /// A step is not a rounding the caller applies afterwards: the control
    /// itself snaps, so the thumb sits where the value is and a user dragging
    /// it feels the detents.
    pub fn set_step(step: f64) -> Result<bool> {
        return self.set_property_real(platform.P_STEP, step)
    }
}
