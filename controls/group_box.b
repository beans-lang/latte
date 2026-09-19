// A titled box around a group of controls.
package controls
import latte.scene

/// A group box.
///
/// `NSBox`, a `GtkFrame`, a `BS_GROUPBOX` — the frame and the title a platform
/// draws around controls that belong together. **UIKit has nothing that means
/// it**: a `UIView` with a border and a label on top would be latte drawing
/// a control, which is the substitution `WidgetKind.available()` exists to
/// refuse. On a phone the shape is a grouped table section, which is a
/// different control.
///
/// It holds children like a `Container` does, and its text is the title on the
/// frame. Everything inside is placed by the solver in the box's own
/// coordinates, so the frame stays outside the children rather than overlapping
/// the first one.
pub class GroupBox extends ChildHolder {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.group_box, context)
    }

    pub static fn of(context: scene.UiContext, title: string) -> Result<GroupBox> {
        WidgetKind.group_box.demand()?
        var box: GroupBox = new GroupBox(context)
        box.set_title(title)?
        return ok(box)
    }

    pub fn set_title(title: string) -> Result<bool> {
        return self.set_text_raw(title)
    }

    pub fn title() -> Result<string> {
        return self.text_raw()
    }

    pub override fn display_text() -> Result<string> {
        return self.title()
    }
}
