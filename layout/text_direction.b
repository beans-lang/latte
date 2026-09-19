// Reading order.
package layout

/// Whether the user's language reads left to right or right to left.
///
/// latte lays every tree out left to right, then mirrors the finished frames
/// in one pass when this is `rtl`. That ordering is deliberate: every layout
/// algorithm stays direction-free and therefore has one set of tests, and the
/// mirror is a single ten-line function that can be checked on its own.
///
/// Mirroring is per container, not per screen, and a container whose layout
/// places children at explicit coordinates opts out — see
/// `Layout.mirrors_in_rtl`.
pub enum TextDirection {
    ltr
    rtl

    pub fn name() -> string {
        match self {
            ltr => { return "ltr" }
            rtl => { return "rtl" }
        }
    }

    pub fn is_rtl() -> bool {
        return self == TextDirection.rtl
    }
}
