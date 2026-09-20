// One line of text the user types and nobody reads over their shoulder.
package controls

import latte.platform
import latte.scene

/// A single-line field that shows dots instead of what was typed.
///
/// The platform's own secure field — `NSSecureTextField`, a `UITextField` with
/// secure entry, a `GtkEntry` with visibility off, an `EDIT` control with
/// `ES_PASSWORD` — and that matters more here than for any other control. A
/// real secure field is what tells the window server not to let the screen be
/// captured, what keeps the text out of the pasteboard and out of dictation,
/// and what stops autocorrect from learning a password. A text field with a
/// bullet glyph substituted does none of it.
///
/// **It does not report its text to a dump.** `display_text` answers "" rather
/// than the value, so a control tree printed to a log or a golden file does
/// not carry what somebody typed. `value()` is there for the program that
/// actually needs it, and it is a call somebody had to write on purpose.
pub class SecureField extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.secure_field, context)
    }

    pub static fn of(context: scene.UiContext, value: string) -> Result<SecureField> {
        WidgetKind.secure_field.demand()?
        var field: SecureField = new SecureField(context)
        field.set_value(value)?
        return ok(field)
    }

    pub fn set_value(value: string) -> Result<bool> {
        return self.set_text_raw(value)
    }

    /// What was typed.
    ///
    /// Deliberately not `display_text`: see the note on the class.
    pub fn value() -> Result<string> {
        return self.text_raw()
    }

    pub fn set_editable(on: bool) -> Result<bool> {
        return self.set_flag(platform.P_EDITABLE, on, "make a secure field editable")
    }

    pub fn is_editable() -> Result<bool> {
        return self.read_flag(platform.P_EDITABLE, "read whether a secure field is editable")
    }

    /// What the field shows while it is empty.
    ///
    /// Every single-line field carries one — `ctd_kind_has_hint` in
    /// `controls.KindRules` names exactly the three — and this wrapper was
    /// missing for two of them, so the property was reachable through
    /// `set_string` and through no method.
    pub fn set_hint(hint: string) -> Result<bool> {
        return self.set_string(platform.S_HINT, hint, "set a secure field's hint")
    }

    pub fn hint() -> Result<string> {
        return self.string_at(platform.S_HINT, "read a secure field's hint")
    }
}
