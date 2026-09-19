// Text the user reads but cannot edit.
package controls

import latte.scene

/// A run of static text.
///
/// Not an editable field with editing turned off: a label is not focusable,
/// takes no keyboard input, and reports itself to assistive technology as
/// text rather than as a form control.
pub class Label extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.label, context)
    }

    pub static fn of(context: scene.UiContext, text: string) -> Result<Label> {
        var label: Label = new Label(context)
        label.set_text(text)?
        return ok(label)
    }

    pub fn set_text(text: string) -> Result<bool> {
        return self.set_text_raw(text)
    }

    pub fn text() -> Result<string> {
        return self.text_raw()
    }

    pub override fn display_text() -> Result<string> {
        return self.text()
    }
}
