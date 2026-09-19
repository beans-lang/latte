// A field that says what it is for.
package controls

import latte.platform
import latte.scene

/// A search field.
///
/// `NSSearchField`, a `UISearchTextField`, a `GtkSearchEntry`, an `EDIT` with a
/// cue banner. It is a text field that looks like the place you type a search
/// — the magnifier, the clear button, the rounded shape the platform uses —
/// and it raises `text_commit` the same way a text field does.
///
/// **The hint is what makes it useful.** "Search orders" written into the
/// empty field is the whole of the affordance on three platforms and the only
/// one on the fourth; without it a search field is a text field with rounder
/// corners.
///
/// What differs, and is worth knowing before shipping a design: Win32's is an
/// edit control with `EM_SETCUEBANNER`. That is what a Windows search box is —
/// Explorer's is exactly that — but it has no clear button, so a program that
/// leans on one should offer its own.
pub class SearchField extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.search_field, context)
    }

    pub static fn of(context: scene.UiContext, hint: string) -> Result<SearchField> {
        WidgetKind.search_field.demand()?
        var field: SearchField = new SearchField(context)
        field.set_hint(hint)?
        return ok(field)
    }

    pub fn set_value(value: string) -> Result<bool> {
        return self.set_text_raw(value)
    }

    pub fn value() -> Result<string> {
        return self.text_raw()
    }

    /// The words the field shows while it is empty.
    pub fn set_hint(hint: string) -> Result<bool> {
        return self.set_string(platform.S_HINT, hint, "set a search field's hint")
    }

    pub fn hint() -> Result<string> {
        return self.string_at(platform.S_HINT, "read a search field's hint")
    }

    pub override fn display_text() -> Result<string> {
        return self.value()
    }
}
