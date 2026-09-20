// A Measure that answers from a table instead of from a platform.
package layout

import latte.geometry

/// Synthetic measurements, keyed the same way real ones are.
///
/// Two jobs. In the test suite it makes the layout engine deterministic: every
/// expected output holds frames computed from numbers written down in the test, so
/// a failure means the solver changed, never that a font did. In an
/// application it is the stand-in a headless tool uses — a screenshot differ, a
/// layout linter — where no window server exists to ask.
///
/// A key with no row measures as zero rather than failing. A layout tree under
/// construction has nodes whose widgets do not exist yet, and refusing there
/// would make the common case the error case. A test that cares asserts on the
/// frame it expected, which catches a missing row immediately.
pub class TableMeasure implements Measure {
    rows: Map<int, geometry.Size>
    /// The keys that reflow, and the height of one of their lines.
    lines: Map<int, f64> = {}

    pub fn init() {
        self.rows = {}
    }

    /// Records that the node with this key measures `width` by `height`.
    pub fn put(key: int, width: f64, height: f64) {
        self.rows.set(key, geometry.Size.of(width, height))
    }

    /// Records text `width` wide on one line of `line_height`: offered less
    /// width, it answers the offer and as many lines as its width needs.
    pub fn put_text(key: int, width: f64, line_height: f64) {
        self.rows.set(key, geometry.Size.of(width, line_height))
        self.lines.set(key, line_height)
    }

    pub fn count() -> int {
        return self.rows.len()
    }

    /// The recorded size, clipped to whatever `available` allows.
    ///
    /// Clipping happens here rather than in the caller because a real platform
    /// does it too: ask AppKit how big a label wants to be in 100 points of
    /// width and it answers at most 100 and wraps. A table that ignored the
    /// offer would make wrapping tests impossible to write.
    pub fn measure(key: int, available: geometry.Size) -> Result<geometry.Size> {
        match self.rows.get(key) {
            some(size) => {
                var width: f64 = size.width
                var height: f64 = size.height
                if available.width >= 0.0 && width > available.width {
                    match self.lines.get(key) {
                        some(line) => {
                            // Whole lines, the way words break: 500 wide in 300 is two.
                            var count: f64 = (size.width / available.width).ceil()
                            if available.width <= 0.0 { count = 1.0 }
                            height = line * count
                        }
                        none => {}
                    }
                    width = available.width
                }
                if available.height >= 0.0 && height > available.height {
                    height = available.height
                }
                return ok(geometry.Size.of(width, height))
            }
            none => {
                return ok(geometry.Size.zero())
            }
        }
    }
}
