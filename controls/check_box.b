// A box the user ticks.
package controls

import latte.platform
import latte.scene

/// A check box with a label beside it.
///
/// Toggling it produces a `value_changed` event. Read `state()` in the
/// handler rather than tracking it separately: the platform owns the control's
/// state, and a second copy in Beans is a second thing that can be wrong.
pub class CheckBox extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.check_box, context)
    }

    pub static fn of(context: scene.UiContext, title: string) -> Result<CheckBox> {
        var box: CheckBox = new CheckBox(context)
        box.set_title(title)?
        return ok(box)
    }

    pub fn set_title(title: string) -> Result<bool> {
        return self.set_text_raw(title)
    }

    pub fn title() -> Result<string> {
        return self.text_raw()
    }

    pub fn set_state(state: CheckState) -> Result<bool> {
        return self.set_property(platform.P_CHECKED, state.code())
    }

    pub fn state() -> Result<CheckState> {
        return ok(CheckState.of(self.read_property(platform.P_CHECKED)?))
    }

    pub override fn display_text() -> Result<string> {
        return self.title()
    }
}
