// A line between things.
package controls
import latte.scene

/// A rule that divides one group of controls from another.
///
/// It carries no state and answers nothing, and it is a control rather than a
/// drawing for one reason: the platform decides what a divider looks like, and
/// it is not the same on any two of them. A line latte drew would be right
/// on the machine it was tuned on and subtly wrong everywhere else, and would
/// not follow the system appearance when it changed.
pub class Separator extends Widget {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.separator, context)
    }
}
