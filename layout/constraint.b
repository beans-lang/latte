// The room a node is allowed to occupy.
package layout

import latte.geometry

/// A minimum and a maximum in each direction.
///
/// A negative maximum means **unbounded**: the node may be as large as it
/// likes on that axis. This is how a vertical stack asks its children how tall
/// they naturally are, and it is the same convention `geometry.Size.unbounded`
/// uses at the host boundary, so no translation happens in between.
///
/// A minimum is never negative and never exceeds its maximum. Every
/// constructor here enforces that, because a reversed range does not fail — it
/// quietly produces a box of the wrong size several calls later.
pub struct Constraint {
    pub min_width: f64 = 0.0
    pub max_width: f64 = -1.0
    pub min_height: f64 = 0.0
    pub max_height: f64 = -1.0

    /// No limit in either direction.
    pub static fn unbounded() -> Constraint {
        return Constraint {}
    }

    /// Exactly this size and nothing else.
    pub static fn tight(size: geometry.Size) -> Constraint {
        return Constraint { min_width: size.width, max_width: size.width,
                            min_height: size.height, max_height: size.height }
    }

    /// At most this size, at least nothing — what a container hands a child
    /// that is free to be smaller than the room it was offered.
    pub static fn loose(size: geometry.Size) -> Constraint {
        return Constraint { min_width: 0.0, max_width: size.width,
                            min_height: 0.0, max_height: size.height }
    }

    pub static fn of(min_width: f64, max_width: f64,
                     min_height: f64, max_height: f64) -> Constraint {
        return Constraint { min_width: min_width, max_width: max_width,
                            min_height: min_height, max_height: max_height }
    }

    /// Whether these are the same four numbers.
    ///
    /// Field by field rather than through a derived equality: what a measure
    /// cache needs to know is that a node is being asked the identical
    /// question, and identical here means the numbers are the same, not that
    /// two constraints describe the same room.
    pub fn same_as(other: Constraint) -> bool {
        return self.min_width == other.min_width &&
               self.max_width == other.max_width &&
               self.min_height == other.min_height &&
               self.max_height == other.max_height
    }

    pub fn has_max_width() -> bool {
        return self.max_width >= 0.0
    }

    pub fn has_max_height() -> bool {
        return self.max_height >= 0.0
    }

    /// The maxima as a `Size`, keeping -1 for an unbounded axis. This is the
    /// value handed to `Measure`, which speaks the same convention.
    pub fn available() -> geometry.Size {
        return geometry.Size.of(self.max_width, self.max_height)
    }

    /// `size` pulled inside this range.
    ///
    /// An unbounded axis imposes no upper limit, so only the minimum applies
    /// there. Nothing is ever clamped below zero: a caller asking for a
    /// negative size has a bug, and passing it through hides where.
    pub fn clamp(size: geometry.Size) -> geometry.Size {
        var width: f64 = size.width
        var height: f64 = size.height
        if width < self.min_width { width = self.min_width }
        if self.has_max_width() && width > self.max_width { width = self.max_width }
        if height < self.min_height { height = self.min_height }
        if self.has_max_height() && height > self.max_height { height = self.max_height }
        if width < 0.0 { width = 0.0 }
        if height < 0.0 { height = 0.0 }
        return geometry.Size.of(width, height)
    }

    /// This constraint with `insets` taken off every bound.
    ///
    /// Used twice per pass: a container deflates by its own padding before
    /// asking children how big they want to be, and again by each child's
    /// margin. Bounds never go below zero, so a box padded past its own size
    /// offers zero room rather than negative room.
    pub fn deflate(insets: geometry.EdgeInsets) -> Constraint {
        return Constraint {
            min_width: shrink(self.min_width, insets.horizontal()),
            max_width: shrink_max(self.max_width, insets.horizontal()),
            min_height: shrink(self.min_height, insets.vertical()),
            max_height: shrink_max(self.max_height, insets.vertical())
        }
    }

    /// This constraint with no upper limit on the main axis, which is what a
    /// run asks a child before it knows how much space there is to share.
    pub fn unbound(axis: Direction) -> Constraint {
        if axis.is_horizontal() {
            return Constraint { min_width: 0.0, max_width: -1.0,
                                min_height: self.min_height, max_height: self.max_height }
        }
        return Constraint { min_width: self.min_width, max_width: self.max_width,
                            min_height: 0.0, max_height: -1.0 }
    }

    /// This constraint with both minima dropped to zero — a child may be
    /// smaller than the parent's own minimum.
    pub fn loosen() -> Constraint {
        return Constraint { min_width: 0.0, max_width: self.max_width,
                            min_height: 0.0, max_height: self.max_height }
    }

    pub fn show() -> string {
        return "{self.min_width}..{self.max_width} x {self.min_height}..{self.max_height}"
    }
}

// Shrinks a bound that is always a real number.
fn shrink(value: f64, amount: f64) -> f64 {
    let left: f64 = value - amount
    if left < 0.0 { return 0.0 }
    return left
}

// Shrinks a bound where a negative value means "no limit", which must stay
// no limit however much is taken off it.
fn shrink_max(value: f64, amount: f64) -> f64 {
    if value < 0.0 { return -1.0 }
    return shrink(value, amount)
}
