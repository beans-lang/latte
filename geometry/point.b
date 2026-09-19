// A position in points, top-left origin, y growing downward.
package geometry

/// A point in its parent's coordinate space.
///
/// latte puts the origin at the top-left corner and grows y downward. Four
/// of the five platforms latte targets already agree; macOS is the odd one
/// and its host flips at the boundary, so nothing above `latte.platform` ever
/// sees AppKit's bottom-left convention.
pub struct Point {
    pub x: f64 = 0.0
    pub y: f64 = 0.0

    pub static fn at(x: f64, y: f64) -> Point {
        return Point { x: x, y: y }
    }

    pub static fn zero() -> Point {
        return Point {}
    }

    pub fn offset(dx: f64, dy: f64) -> Point {
        return Point { x: self.x + dx, y: self.y + dy }
    }

    pub fn show() -> string {
        return "{self.x},{self.y}"
    }
}
