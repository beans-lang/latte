// A width and a height in points.
package geometry

/// How big something is, or wants to be.
///
/// A negative component means "unbounded" when a size is offered to `measure`
/// as a constraint. It is never a legal answer: a control that measures itself
/// reports a real number, or the host reports a failure.
pub struct Size {
    pub width: f64 = 0.0
    pub height: f64 = 0.0

    pub static fn of(width: f64, height: f64) -> Size {
        return Size { width: width, height: height }
    }

    pub static fn zero() -> Size {
        return Size {}
    }

    /// The constraint that imposes no limit in either direction.
    pub static fn unbounded() -> Size {
        return Size { width: -1.0, height: -1.0 }
    }

    pub fn is_empty() -> bool {
        return self.width <= 0.0 || self.height <= 0.0
    }

    pub fn show() -> string {
        return "{self.width}x{self.height}"
    }
}
