// What an animation is allowed to move.
package motion

import latte.platform

/// The properties an animation can move.
///
/// A list rather than "any property", and a short one, because what can be
/// animated is part of the contract: a host that animated a property another
/// host refused would be the `enabled` mistake made a second time. Opacity is
/// the whole list today. The properties that describe a layer — corner radius,
/// rotation, scale, translation, colour — are the ones that come next, and
/// each is a name here and a case in four hosts, never a new entry point.
pub enum(u8) Animatable {
    opacity

    pub fn name() -> string {
        return match self {
            opacity => "opacity",
        }
    }

    /// The property key the header gives this, translated rather than cast for
    /// the reason written out in `Curve.code`.
    pub fn code() -> int {
        return match self {
            opacity => platform.P_OPACITY,
        }
    }
}
