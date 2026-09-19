// Which way a run of children flows, and the axis mapping that follows.
package layout

import latte.geometry

/// The main axis of a stack, flex or grid run.
///
/// This is a physical axis, not a logical one. Right-to-left reading order is
/// a separate concern handled once by mirroring finished frames, so a
/// `horizontal` run is always laid out left to right first and flipped after
/// if the locale asks. Folding both ideas into one enum is how frameworks end
/// up mirroring twice.
///
/// The accessors below are the reason one arrangement algorithm serves both
/// directions. Everything downstream talks about "main" and "cross", and this
/// enum is the single place that decides which of those is x and which is y.
/// A vertical-stack bug that a horizontal stack does not have is almost always
/// a place where somebody reached for `.width` instead of `main_of`.
pub enum Direction {
    horizontal
    vertical

    pub fn name() -> string {
        match self {
            horizontal => { return "horizontal" }
            vertical => { return "vertical" }
        }
    }

    /// The axis at right angles to this one.
    pub fn cross() -> Direction {
        match self {
            horizontal => { return Direction.vertical }
            vertical => { return Direction.horizontal }
        }
    }

    pub fn is_horizontal() -> bool {
        return self == Direction.horizontal
    }

    // ---- reading a size or a rect along this axis ----

    pub fn main_of(size: geometry.Size) -> f64 {
        if self.is_horizontal() { return size.width }
        return size.height
    }

    pub fn cross_of(size: geometry.Size) -> f64 {
        if self.is_horizontal() { return size.height }
        return size.width
    }

    /// Where `rect` begins along this axis.
    pub fn main_start(rect: geometry.Rect) -> f64 {
        if self.is_horizontal() { return rect.x }
        return rect.y
    }

    pub fn cross_start(rect: geometry.Rect) -> f64 {
        if self.is_horizontal() { return rect.y }
        return rect.x
    }

    pub fn main_extent(rect: geometry.Rect) -> f64 {
        if self.is_horizontal() { return rect.width }
        return rect.height
    }

    pub fn cross_extent(rect: geometry.Rect) -> f64 {
        if self.is_horizontal() { return rect.height }
        return rect.width
    }

    // ---- building a size or a rect from axis-relative numbers ----

    pub fn size(main: f64, cross: f64) -> geometry.Size {
        if self.is_horizontal() { return geometry.Size.of(main, cross) }
        return geometry.Size.of(cross, main)
    }

    /// A constraint that pins `main` along this axis and offers `0..cross`
    /// across it — what a run hands a child once its main size is settled and
    /// only the cross size is still open.
    pub fn pin(main: f64, cross: f64) -> Constraint {
        if self.is_horizontal() {
            return Constraint.of(main, main, 0.0, cross)
        }
        return Constraint.of(0.0, cross, main, main)
    }

    pub fn rect(main_at: f64, cross_at: f64, main: f64, cross: f64) -> geometry.Rect {
        if self.is_horizontal() {
            return geometry.Rect.of(main_at, cross_at, main, cross)
        }
        return geometry.Rect.of(cross_at, main_at, cross, main)
    }
}
