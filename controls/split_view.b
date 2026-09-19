// Two panes with a handle between them.
package controls

import latte.platform
import latte.geometry
import latte.layout
import latte.scene

/// A split view.
///
/// `NSSplitView`, `GtkPaned` — and **not on every platform**: the Win32 common
/// controls have no splitter at all (every Windows application draws its own,
/// which is what latte will not do), and UIKit's split view is a view
/// *controller* that owns the screen and changes shape with the device.
///
/// **Exactly two panes, and the platform is what places them.** Both toolkits
/// lay their panes out from the divider's position and neither can be talked
/// out of it, so latte's hosts do not write a pane's frame — they write
/// `divider` and read the same number back. `layout.SplitLayout` computes the
/// same two boxes so that everything *inside* a pane is solved against the
/// size the pane is going to have; `split_layout()` below builds one with the
/// numbers already filled in.
///
/// A third pane is refused. A split view with three panes is a thing the
/// caller believes they have and no platform here provides.
pub class SplitView extends ChildHolder {
    pub fn init(context: scene.UiContext) {
        super.init(WidgetKind.split_view, context)
    }

    /// A split view, side by side or stacked.
    pub static fn of(context: scene.UiContext, stacked: bool) -> Result<SplitView> {
        WidgetKind.split_view.demand()?
        var split: SplitView = new SplitView(context)
        split.set_stacked(stacked)?
        return ok(split)
    }

    pub override fn add(child: Widget) -> Result<bool> {
        if self.count() >= 2 {
            return err("a split view has two panes and already has both", "too_many_panes")
        }
        return super.add(child)
    }

    /// Whether the panes are stacked one above the other rather than side by
    /// side.
    pub fn set_stacked(stacked: bool) -> Result<bool> {
        return self.set_property(platform.P_AXIS, if stacked { 1 } else { 0 })
    }

    pub fn is_stacked() -> Result<bool> {
        return self.read_flag(platform.P_AXIS, "read which way a split view divides")
    }

    /// Where the handle sits, in points from the leading edge.
    pub fn set_divider(where: f64) -> Result<bool> {
        return self.set_property_real(platform.P_DIVIDER, where)
    }

    pub fn divider() -> Result<f64> {
        return self.read_real(platform.P_DIVIDER, "read where a split view's handle is")
    }

    /// The handle's own thickness, which is what it keeps out of the room the
    /// panes share.
    pub fn handle_size() -> Result<f64> {
        let kept: geometry.EdgeInsets = self.content_inset()?
        if self.is_stacked()? { return ok(kept.bottom) }
        return ok(kept.right)
    }

    /// An arranger already carrying this control's two numbers.
    ///
    /// Built here rather than by the caller because getting either number from
    /// somewhere else is how a pane ends up laid out against a size it does
    /// not have — and because `latte.layout` cannot ask a control anything,
    /// by design.
    pub fn split_layout() -> Result<layout.SplitLayout> {
        let stacked: bool = self.is_stacked()?
        let where: f64 = self.divider()?
        let thick: f64 = self.handle_size()?
        if stacked { return ok(layout.SplitLayout.column(where, thick)) }
        return ok(layout.SplitLayout.row(where, thick))
    }
}
