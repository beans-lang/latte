// One line of text the user can type into.
package controls

import latte.scene

import latte.platform

/// A single-line editable field.
///
/// The platform's own field, which is the entire point: it brings the system
/// input method, dictation, the emoji picker, spell-checking, the standard
/// editing shortcuts and the selection behaviour the user already knows.
/// Rebuilding any of that is how a toolkit ends up subtly wrong in every
/// language but English.
pub class TextField extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.text_field, context)
    }

    pub static fn of(context: scene.UiContext, value: string) -> Result<TextField> {
        var field: TextField = new TextField(context)
        field.set_value(value)?
        return ok(field)
    }

    pub fn set_value(value: string) -> Result<bool> {
        return self.set_text_raw(value)
    }

    pub fn value() -> Result<string> {
        return self.text_raw()
    }

    pub fn set_editable(on: bool) -> Result<bool> {
        return self.set_flag(platform.P_EDITABLE, on, "make a text field editable")
    }

    pub fn is_editable() -> Result<bool> {
        return self.read_flag(platform.P_EDITABLE, "read whether a text field is editable")
    }

    pub override fn display_text() -> Result<string> {
        return self.value()
    }

    /// What the field shows while it is empty.
    ///
    /// Every single-line field carries one — `ctd_kind_has_hint` in
    /// `controls.KindRules` names exactly the three — and this wrapper was
    /// missing for two of them, so the property was reachable through
    /// `set_string` and through no method.
    pub fn set_hint(hint: string) -> Result<bool> {
        return self.set_string(platform.S_HINT, hint, "set a text field's hint")
    }

    pub fn hint() -> Result<string> {
        return self.string_at(platform.S_HINT, "read a text field's hint")
    }
}
