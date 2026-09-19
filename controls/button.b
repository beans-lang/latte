// Something the user presses.
package controls

import latte.scene

import latte.platform

/// A push button.
///
/// Pressing it produces an `activate` event. There is no handler argument
/// here: handlers are registered on the application's event router by handle,
/// so a button holds no closure and cannot form a reference cycle with the
/// code that reacts to it.
pub class Button extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.button, context)
    }

    pub static fn of(context: scene.UiContext, title: string) -> Result<Button> {
        var button: Button = new Button(context)
        button.set_title(title)?
        return ok(button)
    }

    /// A button's text is its title, which is the word every platform uses for
    /// it and the word that distinguishes it from a text field's value.
    pub fn set_title(title: string) -> Result<bool> {
        return self.set_text_raw(title)
    }

    pub fn title() -> Result<string> {
        return self.text_raw()
    }

    /// The one button a screen leads with. macOS fills it with the accent
    /// colour; a host without that style refuses rather than drawing a plain one.
    pub fn set_prominent(on: bool) -> Result<bool> {
        return self.set_property(platform.P_PROMINENT, if on { 1 } else { 0 })
    }

    pub fn prominent() -> Result<bool> {
        return ok(self.read_property(platform.P_PROMINENT)? == 1)
    }

    pub override fn display_text() -> Result<string> {
        return self.title()
    }
}
