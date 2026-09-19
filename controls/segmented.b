// A few choices, all of them on screen.
package controls

import latte.platform
import latte.scene

/// A segmented control.
///
/// `NSSegmentedControl` and `UISegmentedControl` are real controls; **GTK and
/// the Win32 common controls have none**, and latte refuses rather than
/// building a row of toggle buttons that looks like one. A row of toggles is
/// not a segmented control: nothing keeps exactly one of them down, so it can
/// be all-off or all-on, and a program that relied on "one is always chosen"
/// would be wrong in a way the user can see.
///
/// The choices are the item list — the same one a `ComboBox` uses, because "a
/// list of choices" is one idea and a caller should not have to know which
/// control it landed in. `select` and `selected` are the index.
pub class Segmented extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.segmented, context)
    }

    pub static fn of(context: scene.UiContext, choices: List<string>) -> Result<Segmented> {
        WidgetKind.segmented.demand()?
        var bar: Segmented = new Segmented(context)
        bar.set_items(choices)?
        return ok(bar)
    }

    /// Replaces every choice.
    pub fn set_items(choices: List<string>) -> Result<bool> {
        let choice: scene.SegmentedRender = (self.render_object()? as? scene.SegmentedRender).expect("shared segmented control")
        return choice.replace_items(choices)
    }

    pub fn add_item(text: string) -> Result<bool> {
        let choice: scene.SegmentedRender = (self.render_object()? as? scene.SegmentedRender).expect("shared segmented control")
        return choice.add_item(text)
    }

    pub fn count() -> Result<int> {
        let choice: scene.SegmentedRender = (self.render_object()? as? scene.SegmentedRender).expect("shared segmented control")
        return ok(choice.count())
    }

    pub fn item_at(index: int) -> Result<string> {
        let choice: scene.SegmentedRender = (self.render_object()? as? scene.SegmentedRender).expect("shared segmented control")
        return choice.item_at(index)
    }

    /// Which one is chosen, or -1 for none.
    pub fn selected() -> Result<int> {
        return self.read_property(platform.P_SELECTED)
    }

    /// Choose one, or -1 for none.
    pub fn select(index: int) -> Result<bool> {
        return self.set_property(platform.P_SELECTED, index)
    }

    pub override fn display_text() -> Result<string> {
        let at: int = self.selected().or(-1)
        if at < 0 { return ok("") }
        return self.item_at(at)
    }
}
