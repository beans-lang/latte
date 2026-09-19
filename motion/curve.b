// How an animation gets from one value to the other.
package motion

import latte.platform

/// The shape of an animation over time.
///
/// Four names rather than four bezier control points. Every platform has these
/// and means the same thing by them, a name is what a person actually says
/// about a movement, and the control points are written down once in C where
/// the two hosts that have to compute them can share them.
///
/// `ease_in_out` is the default, because it is what an interface almost always
/// wants: a thing that starts moving gently and arrives gently reads as
/// physical, and one that starts and stops at full speed reads as a jump.
pub enum(u8) Curve {
    linear
    ease_in
    ease_out
    ease_in_out

    pub fn name() -> string {
        return match self {
            linear => "linear",
            ease_in => "ease_in",
            ease_out => "ease_out",
            ease_in_out => "ease_in_out",
        }
    }

    /// The header's own number for this curve.
    ///
    /// Written out rather than cast. `enum(u8)` fixes the layout in memory and
    /// nothing else: the language is explicit that there is no conversion to
    /// or from an integer and that a sized enum is still not a C ABI type. So
    /// the translation is a `match`, the way `controls.WidgetKind` does it, and
    /// `tools/check_constants.sh` holds the numbers to the header.
    pub fn code() -> int {
        return match self {
            linear => platform.CURVE_LINEAR,
            ease_in => platform.CURVE_EASE_IN,
            ease_out => platform.CURVE_EASE_OUT,
            ease_in_out => platform.CURVE_EASE_IN_OUT,
        }
    }

    pub static fn of(code: int) -> Curve {
        if code == platform.CURVE_LINEAR { return Curve.linear }
        if code == platform.CURVE_EASE_IN { return Curve.ease_in }
        if code == platform.CURVE_EASE_OUT { return Curve.ease_out }
        return Curve.ease_in_out
    }
}
