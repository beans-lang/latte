// Two little arrows that step a number.
package controls

import latte.platform
import latte.scene

/// A stepper.
///
/// `NSStepper`, `UIStepper`, a `GtkSpinButton`, an up-down control. It carries
/// the same four numbers a `Slider` does — a low end, a high end, a value and
/// an increment — and the difference between the two controls is what the user
/// is doing: a slider is a position they aim at, and a stepper is a number they
/// nudge. Both raise `value_changed`.
///
/// **The increment is not optional here.** A slider with no step is continuous,
/// which is a real thing to be; a stepper with no step is two arrows that do
/// nothing, so `set_step(0.0)` is `out_of_range` rather than a control that
/// looks fine and never moves.
///
/// One platform counts in whole numbers. A Win32 up-down control holds an
/// `int32`, so the host keeps the real range beside it and stores a tick index
/// — `value = low + tick × step`. A quarter-step range works there for the same
/// reason it works everywhere else, rather than being silently truncated to
/// zero.
pub class Stepper extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.stepper, context)
    }

    /// A stepper over `low`..`high`, stepping by `step`, starting at `start`.
    ///
    /// The range goes in before the value, because a platform that clamps on
    /// every change would otherwise move the value to fit a range it is about
    /// to be given.
    pub static fn of(context: scene.UiContext, low: f64, high: f64, step: f64, start: f64) -> Result<Stepper> {
        var control: Stepper = new Stepper(context)
        control.set_range(low, high)?
        control.set_step(step)?
        control.set_value(start)?
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
        return self.read_real(platform.P_VALUE, "read a stepper's value")
    }

    pub fn low() -> Result<f64> {
        return self.read_real(platform.P_MIN, "read a stepper's lowest value")
    }

    pub fn high() -> Result<f64> {
        return self.read_real(platform.P_MAX, "read a stepper's highest value")
    }

    /// How far one press moves it. Must be more than zero.
    pub fn set_step(step: f64) -> Result<bool> {
        return self.set_property_real(platform.P_STEP, step)
    }

    pub fn step() -> Result<f64> {
        return self.read_real(platform.P_STEP, "read a stepper's increment")
    }
}
