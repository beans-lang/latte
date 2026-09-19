// Where a leaf's natural size comes from.
package layout

import latte.geometry

/// Answers how big a leaf node wants to be.
///
/// This is the layout engine's one dependency on the outside world, and it is
/// an interface on purpose. Text metrics are the only thing latte cannot
/// compute for itself — how wide "Order a coffee" renders depends on the
/// platform's font stack — so that single question is isolated behind one
/// method and injected.
///
/// The payoff is that the whole engine is testable with no display, no window
/// server and no foreign function call: `TableMeasure` answers from a table
/// and the same solver produces the same frames on every operating system.
/// The suite therefore runs identically on a Linux CI runner and on a Mac,
/// which is what lets a layout bug be found before any platform is involved.
///
/// `available` carries -1 on an axis with no limit, matching
/// `geometry.Size.unbounded`. An implementation must answer a real, finite
/// size on both axes regardless.
pub interface Measure {
    fn measure(key: int, available: geometry.Size) -> Result<geometry.Size>
}
