// One choice out of several.
package controls

import latte.platform
import latte.scene

/// A round button that is on when its neighbours are off.
///
/// Grouping is by **parent**, not by a group object: radio buttons inside one
/// container are one group, and putting two groups in one container is a bug
/// the platform cannot see. That is how AppKit, Win32 and GTK all behave, and
/// a `RadioGroup` type that pretended otherwise would have to fight all three.
/// Put each group in its own `Container`, which is what a layout wants anyway.
pub class RadioButton extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.radio_button, context)
    }

    pub static fn of(context: scene.UiContext, title: string) -> Result<RadioButton> {
        var control: RadioButton = new RadioButton(context)
        control.set_title(title)?
        return ok(control)
    }

    pub fn set_title(title: string) -> Result<bool> {
        return self.set_text_raw(title)
    }

    pub fn title() -> Result<string> {
        return self.text_raw()
    }

    pub fn set_chosen(on: bool) -> Result<bool> {
        return self.set_property(platform.P_CHECKED, if on { 1 } else { 0 })
    }

    pub fn is_chosen() -> Result<bool> {
        return self.read_flag(platform.P_CHECKED, "read whether a radio button is chosen")
    }

    pub override fn display_text() -> Result<string> {
        return self.text_raw()
    }
}
