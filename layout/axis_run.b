// Working storage for one pass along a run's main axis.
package layout

/// The per-child numbers a stack or flex run computes, held together.
///
/// This is a class rather than a handful of parallel lists passed between
/// methods, for one reason that matters in Beans: `List` is move-only, so
/// handing four of them to a method and getting them back is a fight with the
/// ownership checker on every call. A single object reference passes freely,
/// and `FlexLayout` can override one method that reads and writes it.
///
/// It is package-private machinery, not API. The shape is: measure once into
/// `base`, decide a final `main` for each child, and freeze the ones that have
/// hit a bound so the next round of distribution skips them.
class AxisRun {
    count: int = 0
    room: f64 = 0.0
    base: List<f64> = []
    main: List<f64> = []
    lower: List<f64> = []
    upper: List<f64> = []
    grow: List<f64> = []
    shrink: List<f64> = []
    frozen: List<bool> = []

    fn init(room: f64) {
        self.room = room
    }

    /// Records one child. `upper` below zero means it has no upper bound.
    fn add(base: f64, lower: f64, upper: f64, grow: f64, shrink: f64) {
        self.base.push(base)
        self.main.push(base)
        self.lower.push(lower)
        self.upper.push(upper)
        self.grow.push(grow)
        self.shrink.push(shrink)
        self.frozen.push(false)
        self.count = self.count + 1
    }

    fn base_at(index: int) -> f64 {
        return self.base[index]
    }

    fn main_at(index: int) -> f64 {
        return self.main[index]
    }

    fn grow_at(index: int) -> f64 {
        return self.grow[index]
    }

    fn shrink_at(index: int) -> f64 {
        return self.shrink[index]
    }

    fn set_main(index: int, value: f64) {
        self.main[index] = value
    }

    fn is_frozen(index: int) -> bool {
        return self.frozen[index]
    }

    fn freeze(index: int) {
        self.frozen[index] = true
    }

    /// The total main-axis size currently assigned across every child.
    fn total() -> f64 {
        var sum: f64 = 0.0
        for value: f64 in self.main {
            sum = sum + value
        }
        return sum
    }

    /// Pulls one child's size inside its own bounds, and reports whether that
    /// changed it — which is what tells the distribution loop to freeze it.
    fn clamp_at(index: int, value: f64) -> f64 {
        var out: f64 = value
        if out < self.lower[index] { out = self.lower[index] }
        if self.upper[index] >= 0.0 && out > self.upper[index] {
            out = self.upper[index]
        }
        if out < 0.0 { out = 0.0 }
        return out
    }
}
