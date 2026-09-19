// A rectangle in points, top-left origin.
package geometry

/// Where a widget sits inside its parent.
///
/// Frames are relative to the parent's content box, never to the screen. A
/// widget that has not been laid out yet has a zero frame rather than an
/// absent one: every platform answers a rectangle here, so an `Option` would
/// only move the question somewhere less useful.
pub struct Rect {
    pub x: f64 = 0.0
    pub y: f64 = 0.0
    pub width: f64 = 0.0
    pub height: f64 = 0.0

    pub static fn of(x: f64, y: f64, width: f64, height: f64) -> Rect {
        return Rect { x: x, y: y, width: width, height: height }
    }

    pub static fn zero() -> Rect {
        return Rect {}
    }

    pub static fn at(origin: Point, size: Size) -> Rect {
        return Rect { x: origin.x, y: origin.y,
                      width: size.width, height: size.height }
    }

    pub fn origin() -> Point {
        return Point { x: self.x, y: self.y }
    }

    pub fn size() -> Size {
        return Size { width: self.width, height: self.height }
    }

    pub fn right() -> f64 {
        return self.x + self.width
    }

    pub fn bottom() -> f64 {
        return self.y + self.height
    }

    pub fn contains(point: Point) -> bool {
        return point.x >= self.x && point.x < self.right() &&
               point.y >= self.y && point.y < self.bottom()
    }

    /// The frame as the test goldens print it: whole points, no decimals.
    /// Sub-point differences come out of font metrics that move between OS
    /// releases, and a golden carrying them fails for the wrong reason.
    pub fn show() -> string {
        return "{self.x as int},{self.y as int},{self.width as int},{self.height as int}"
    }
}
