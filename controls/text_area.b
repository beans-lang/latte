// Text across many lines.
package controls

import latte.platform
import latte.scene

/// A multi-line, scrolling text control.
///
/// Not a `TextField` with a taller frame. Every platform makes these two
/// different objects — `NSTextView` inside an `NSScrollView`, an `EDIT` with
/// `ES_MULTILINE`, a `GtkTextView` — and they differ in what Return does, in
/// what the caret keys do at a line end, and in whether the text scrolls when
/// it outgrows the box. A field stretched to five lines is a field whose
/// bottom is simply not visible.
pub class TextArea extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.text_area, context)
    }

    pub static fn of(context: scene.UiContext, value: string) -> Result<TextArea> {
        var control: TextArea = new TextArea(context)
        control.set_value(value)?
        return ok(control)
    }

    /// What is in the box.
    ///
    /// `set_value` and not `set_text`, which is what this used to be called.
    /// The four controls a person types into — `TextField`, `SecureField`,
    /// `SearchField` and this one — now all spell it the same way, and the
    /// rule behind the names is worth stating because it is the one thing
    /// that keeps them from drifting again: **a caption is text, an edited
    /// value is a value.** A `Label` and a `Button` carry text, because it is
    /// the program's words and the user cannot change them; a text control
    /// carries a value, because it is the user's and the program reads it
    /// back. Under both names it was always the same `P_VALUE` write, so
    /// nothing here changed except which word a person has to remember, and
    /// there is now one of those instead of two.
    pub fn set_value(value: string) -> Result<bool> {
        return self.set_text_raw(value)
    }

    pub fn value() -> Result<string> {
        return self.text_raw()
    }

    /// Use the platform's native plain-text editor for code such as SQL.
    ///
    /// On macOS this uses the monospaced system font and stops smart quotes,
    /// smart dashes, text replacements and spelling correction. Other hosts
    /// refuse this mode until they can offer the same native editing rules.
    pub fn set_code_mode(on: bool) -> Result<bool> {
        return self.set_flag(platform.P_CODE_MODE, on, "set code mode on a text area")
    }

    pub fn is_code_mode() -> Result<bool> {
        return self.read_flag(platform.P_CODE_MODE, "read code mode on a text area")
    }

    pub override fn display_text() -> Result<string> {
        return self.text_raw()
    }
}
