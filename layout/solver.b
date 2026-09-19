// Turns a layout tree into frames.
package layout

import latte.geometry

/// Runs a layout pass over a tree and writes a frame onto every node.
///
/// Three steps, in this order, and the order is the design:
///
/// 1. **Arrange**, always left to right. Every layout algorithm is written
///    once, direction-free.
/// 2. **Mirror**, if the locale reads right to left. One recursive flip over
///    finished frames, ten lines, testable on its own.
/// 3. **Snap** to the device pixel grid, on absolute edges.
///
/// Doing the mirror inside each algorithm would mean every algorithm needs
/// right-to-left tests. Doing the snap inside each algorithm would be worse:
/// see `snap` below for what goes wrong.
pub class Solver {
    ruler: Measure
    reading: TextDirection = TextDirection.ltr
    scale: f64 = 1.0

    pub fn init(ruler: Measure) {
        self.ruler = ruler
    }

    /// Sets the reading order. Trees solved after this call mirror.
    pub fn set_direction(reading: TextDirection) {
        self.reading = reading
    }

    /// Sets the backing-store scale — 1 for a standard display, 2 for a
    /// Retina one. Frames land on whole device pixels at this scale.
    ///
    /// A scale of 0 or less turns snapping off, which is what the tests that
    /// check the raw arithmetic use.
    pub fn set_scale(scale: f64) {
        self.scale = scale
    }

    pub fn direction() -> TextDirection {
        return self.reading
    }

    /// Lays `root` out inside `into` and writes a frame onto every node.
    pub fn solve(root: LayoutNode, into: geometry.Rect) -> Result<bool> {
        // What the tree measured last time is about controls as they were
        // last time. A label given new words wants a new width, and a pass
        // that started from remembered numbers would lay the screen out for
        // the words before. See `LayoutNode.measured_for`.
        root.forget_measures()
        root.place(into, self.ruler)?
        if self.reading.is_rtl() {
            mirror(root)
        }
        if self.scale > 0.0 {
            snap(root, into.x, into.y, self.scale)
        }
        return ok(true)
    }

    /// How big `root` wants to be, without placing anything.
    ///
    /// This is what sizes a window to its content: measure first, open the
    /// window at that size, then solve into it.
    pub fn fit(root: LayoutNode, limit: Constraint) -> Result<geometry.Size> {
        root.forget_measures()
        return root.measure(limit, self.ruler)
    }
}

/// Flips every mirroring container's children about its own content box.
///
/// A child's frame is relative to its parent's frame origin, and the content
/// box is the parent's frame inset by its layout's padding. Mirroring inside
/// that box — rather than inside the whole frame — is what keeps an asymmetric
/// padding correct: a container with 30 points of padding on the left and 10
/// on the right keeps 30 on the left after the flip, because the padding
/// belongs to the container and not to the reading order.
fn mirror(node: LayoutNode) {
    let count: int = node.count()
    if count == 0 {
        return
    }
    if node.layout().mirrors_in_rtl() {
        let pad: geometry.EdgeInsets = node.layout().padding()
        let frame: geometry.Rect = node.frame()
        let left: f64 = pad.left
        let right: f64 = frame.width - pad.right
        for index: int in 0..count {
            let child: LayoutNode = node.at(index)
            let box: geometry.Rect = child.frame()
            child.set_frame(geometry.Rect.of(left + right - box.x - box.width,
                                             box.y, box.width, box.height))
        }
    }
    for index: int in 0..count {
        mirror(node.at(index))
    }
}

/// Rounds every frame onto the device pixel grid.
///
/// The rounding is done on **absolute** edges, and both edges of a box are
/// rounded independently — never the position and then the size. Rounding a
/// size is how a row of boxes ends up with a one-pixel gap between two of
/// them: neighbours computed at x=10.5 and x=20.5 both round their positions
/// to 10 and 20 but their widths to 10, so the second starts a pixel after the
/// first ends. Rounding shared edges instead means the right edge of one box
/// and the left edge of the next are the same number, so they always meet.
///
/// It has to be absolute because a child's frame is relative to its parent,
/// and a parent already snapped by half a pixel shifts every descendant by
/// that half pixel. The absolute origin is carried down the walk for exactly
/// that reason.
fn snap(node: LayoutNode, origin_x: f64, origin_y: f64, scale: f64) {
    let box: geometry.Rect = node.frame()
    let left: f64 = origin_x + box.x
    let top: f64 = origin_y + box.y
    let right: f64 = round_to(left + box.width, scale)
    let bottom: f64 = round_to(top + box.height, scale)
    let x: f64 = round_to(left, scale)
    let y: f64 = round_to(top, scale)
    node.set_frame(geometry.Rect.of(x - round_to(origin_x, scale),
                                    y - round_to(origin_y, scale),
                                    right - x, bottom - y))
    for index: int in 0..node.count() {
        snap(node.at(index), left, top, scale)
    }
}

/// Half-up rounding onto a grid of `1/scale` points.
///
/// `std.math` has `floor` and `ceil` but no `round`, and the naive
/// `(v + 0.5).floor()` rounds -10.5 to -10 while rounding 10.5 to 11 — the two
/// sides of a mirrored layout would then disagree by a pixel. Splitting on the
/// sign keeps the rounding symmetric about zero, which is what a coordinate
/// system with an origin in the middle of it needs.
fn round_to(value: f64, scale: f64) -> f64 {
    let scaled: f64 = value * scale
    if scaled >= 0.0 {
        return (scaled + 0.5).floor() / scale
    }
    return (scaled - 0.5).ceil() / scale
}
