// How leftover main-axis space is shared out.
package layout

/// Where children sit along the main axis when they do not fill it.
///
/// The three `space_*` values differ only in what they do with the gaps at the
/// two ends, which is the part people get wrong from memory:
///
/// - `space_between` — no gap at either end; all free space goes between.
/// - `space_around`  — each child gets an equal gap on both sides, so the end
///                     gaps are half the size of the ones between children.
/// - `space_evenly`  — every gap, ends included, is the same size.
///
/// A run with one child has no "between", so `space_between` places it at the
/// start; the other two still centre it.
pub enum Justify {
    start
    center
    end
    space_between
    space_around
    space_evenly

    pub fn name() -> string {
        match self {
            start => { return "start" }
            center => { return "center" }
            end => { return "end" }
            space_between => { return "space_between" }
            space_around => { return "space_around" }
            space_evenly => { return "space_evenly" }
        }
    }

    /// The offset of the first child from the start edge, given `free` space
    /// left over across `count` children.
    pub fn lead(free: f64, count: int) -> f64 {
        if free <= 0.0 || count <= 0 {
            return 0.0
        }
        match self {
            start => { return 0.0 }
            center => { return free / 2.0 }
            end => { return free }
            space_between => { return 0.0 }
            space_around => { return free / (count as f64) / 2.0 }
            space_evenly => { return free / ((count + 1) as f64) }
        }
    }

    /// The extra gap inserted between neighbouring children, on top of the
    /// run's own fixed spacing.
    pub fn gap(free: f64, count: int) -> f64 {
        if free <= 0.0 || count <= 1 {
            return 0.0
        }
        match self {
            start => { return 0.0 }
            center => { return 0.0 }
            end => { return 0.0 }
            space_between => { return free / ((count - 1) as f64) }
            space_around => { return free / (count as f64) }
            space_evenly => { return free / ((count + 1) as f64) }
        }
    }
}
