// Space reserved around or inside a box.
package geometry

/// Four edge distances in points.
///
/// One type serves both jobs a UI needs. As **padding** on a container it is
/// space kept inside the box, so children sit in a smaller content box. As a
/// **margin** on a child it is space the parent keeps outside the child's
/// frame. The arithmetic is identical; only who applies it differs, which is
/// why there is one type and not two.
///
/// Edges are named physically — `left` is the left of the screen, not the
/// leading edge. Right-to-left mirroring happens once, at the end of a layout
/// pass, over frames that are already physical. An insets type that flipped
/// its own meaning would mirror twice.
pub struct EdgeInsets {
    pub top: f64 = 0.0
    pub right: f64 = 0.0
    pub bottom: f64 = 0.0
    pub left: f64 = 0.0

    pub static fn zero() -> EdgeInsets {
        return EdgeInsets {}
    }

    /// The same distance on all four edges.
    pub static fn all(amount: f64) -> EdgeInsets {
        return EdgeInsets { top: amount, right: amount, bottom: amount, left: amount }
    }

    /// One distance left and right, another top and bottom — the shape most
    /// real padding takes.
    pub static fn symmetric(horizontal: f64, vertical: f64) -> EdgeInsets {
        return EdgeInsets { top: vertical, right: horizontal,
                            bottom: vertical, left: horizontal }
    }

    pub static fn of(top: f64, right: f64, bottom: f64, left: f64) -> EdgeInsets {
        return EdgeInsets { top: top, right: right, bottom: bottom, left: left }
    }

    /// Total space taken horizontally, which is what a width calculation
    /// subtracts.
    pub fn horizontal() -> f64 {
        return self.left + self.right
    }

    pub fn vertical() -> f64 {
        return self.top + self.bottom
    }

    pub fn is_zero() -> bool {
        return self.top == 0.0 && self.right == 0.0 &&
               self.bottom == 0.0 && self.left == 0.0
    }

    /// `rect` with these insets taken out of it.
    ///
    /// The result is clamped at zero rather than allowed to go negative: a box
    /// padded by more than its own size has no content room, and a negative
    /// width propagates into every later calculation as a number that looks
    /// real.
    pub fn deflate(rect: Rect) -> Rect {
        var width: f64 = rect.width - self.horizontal()
        var height: f64 = rect.height - self.vertical()
        if width < 0.0 { width = 0.0 }
        if height < 0.0 { height = 0.0 }
        return Rect.of(rect.x + self.left, rect.y + self.top, width, height)
    }

    /// `rect` with these insets added around it — the inverse of `deflate`.
    pub fn inflate(rect: Rect) -> Rect {
        return Rect.of(rect.x - self.left, rect.y - self.top,
                       rect.width + self.horizontal(),
                       rect.height + self.vertical())
    }

    pub fn show() -> string {
        return "{self.top},{self.right},{self.bottom},{self.left}"
    }
}
