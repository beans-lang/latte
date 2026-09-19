// A choice from a list.
package controls

import latte.platform
import latte.scene

/// A control that shows one of several choices and lets the user pick another.
///
/// The items are replaced wholesale rather than patched, and that is a
/// decision rather than a shortcut. A list of choices is almost always rebuilt
/// from whatever the program is showing, and an insert-and-move API would mean
/// a second reconciler — with its own bugs — for a control whose contents are
/// strings. When a list is long enough that rebuilding it shows, the answer is
/// a control with a data source, not a diffed item list.
///
/// The selection is an **index**, not the text. Two items may legitimately
/// read the same, and a selection by text could not tell them apart.
pub class ComboBox extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.combo_box, context)
    }

    pub static fn of(context: scene.UiContext, items: List<string>) -> Result<ComboBox> {
        var control: ComboBox = new ComboBox(context)
        control.set_items(items)?
        return ok(control)
    }

    /// Replaces every item. The selection afterwards is the first item, or
    /// none when the list is empty.
    pub fn set_items(items: List<string>) -> Result<bool> {
        let choice: scene.ComboBoxRender = (self.render_object()? as? scene.ComboBoxRender).expect("shared combo box")
        return choice.replace_items(items)
    }

    pub fn add_item(text: string) -> Result<bool> {
        let choice: scene.ComboBoxRender = (self.render_object()? as? scene.ComboBoxRender).expect("shared combo box")
        return choice.add_item(text)
    }

    pub fn count() -> Result<int> {
        let choice: scene.ComboBoxRender = (self.render_object()? as? scene.ComboBoxRender).expect("shared combo box")
        return ok(choice.count())
    }

    pub fn item_at(index: int) -> Result<string> {
        let choice: scene.ComboBoxRender = (self.render_object()? as? scene.ComboBoxRender).expect("shared combo box")
        return choice.item_at(index)
    }

    /// Which item is chosen, or -1 for none.
    pub fn selected() -> Result<int> {
        return self.read_property(platform.P_SELECTED)
    }

    pub fn select(index: int) -> Result<bool> {
        return self.set_property(platform.P_SELECTED, index)
    }

    /// The text of the chosen item, or "" when nothing is chosen.
    pub override fn display_text() -> Result<string> {
        let choice: scene.ComboBoxRender = (self.render_object()? as? scene.ComboBoxRender).expect("shared combo box")
        return ok(choice.selected_text())
    }
}
