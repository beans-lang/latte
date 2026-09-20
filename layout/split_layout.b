// Two panes with a handle between them.
package layout

import latte.geometry

/// The arrangement of a split view's two panes.
///
/// **The platform is what actually places them.** `NSSplitView` and `GtkPaned`
/// both lay their panes out from one number and neither can be talked out of
/// it, so latte's hosts do not write a pane's frame at all. What this layout
/// does is compute the *same* two boxes, so that everything inside a pane —
/// which is ordinary latte layout — is solved against the size the pane is
/// actually going to have.
///
/// Two numbers make that possible, and both come from the control rather than
/// from here: `position`, which is `SplitView.divider()`, and `thickness`,
/// which is the handle's own size out of `Widget.content_inset`. They are
/// plain numbers on this class because `latte.layout` makes no host calls —
/// that is what lets the layout expected outputs run on a machine with no display, and
/// it is not worth giving up for two doubles.
///
/// Exactly two children. A third is a refusal rather than a silent drop,
/// because a split view with three panes is a thing the caller believes they
/// have and no platform here provides.
pub class SplitLayout extends Layout {
    priv axis: Direction = Direction.horizontal
    priv position: f64 = 0.0
    priv thickness: f64 = 0.0
    priv pad: geometry.EdgeInsets = geometry.EdgeInsets.zero()

    pub fn init(axis: Direction, position: f64, thickness: f64) {
        self.axis = axis
        self.position = position
        self.thickness = thickness
    }

    /// Side by side, which is `CTD_P_AXIS` 0.
    pub static fn row(position: f64, thickness: f64) -> SplitLayout {
        return new SplitLayout(Direction.horizontal, position, thickness)
    }

    /// Stacked, which is `CTD_P_AXIS` 1.
    pub static fn column(position: f64, thickness: f64) -> SplitLayout {
        return new SplitLayout(Direction.vertical, position, thickness)
    }

    pub fn set_padding(insets: geometry.EdgeInsets) {
        self.pad = insets
    }

    pub override fn padding() -> geometry.EdgeInsets {
        return self.pad
    }

    /// Explicit coordinates, so no mirror.
    ///
    /// A split view's divider is a position the user dragged, and dragging it
    /// to 200 means 200 from the leading edge in the reading order the user
    /// was looking at. Flipping it again in the solver would move the divider
    /// every time the layout was re-solved.
    pub override fn mirrors_in_rtl() -> bool {
        return false
    }

    pub override fn measure(node: LayoutNode, limit: Constraint,
                            ruler: Measure) -> Result<geometry.Size> {
        // Whatever it is given. A split view is a frame to divide, not a size
        // that follows from its contents: asking the panes would make the
        // divider's position depend on what is inside the panes, which is the
        // opposite of what a divider is for.
        return ok(limit.clamp(geometry.Size.of(limit.max_width, limit.max_height)))
    }

    pub override fn arrange(node: LayoutNode, content: geometry.Rect,
                            ruler: Measure) -> Result<bool> {
        let count: int = node.count()
        if count > 2 {
            return err("a split view has two panes and \"{node.name}\" was given {count}",
                       "too_many_panes")
        }
        if count == 0 {
            return ok(true)
        }
        let along: f64 = if self.axis.is_horizontal() { content.width } else { content.height }
        // Clamped rather than refused: the position is the *platform's*, read
        // back after the user dragged it, and a window narrowed below the
        // divider is an ordinary thing for a user to do. What latte refuses
        // is a position a program wrote out of range — and that refusal is in
        // the host, where the control's real size is known.
        var first: f64 = self.position
        if first < 0.0 { first = 0.0 }
        if first > along { first = along }
        var second: f64 = along - first - self.thickness
        if second < 0.0 { second = 0.0 }

        if self.axis.is_horizontal() {
            node.at(0).place(geometry.Rect.of(content.x, content.y, first, content.height), ruler)?
            if count > 1 {
                node.at(1).place(geometry.Rect.of(content.x + first + self.thickness,
                                                  content.y, second, content.height), ruler)?
            }
        } else {
            node.at(0).place(geometry.Rect.of(content.x, content.y, content.width, first), ruler)?
            if count > 1 {
                node.at(1).place(geometry.Rect.of(content.x, content.y + first + self.thickness,
                                                  content.width, second), ruler)?
            }
        }
        return ok(true)
    }

    pub override fn label() -> string {
        return "split.{self.axis.name()}"
    }
}
