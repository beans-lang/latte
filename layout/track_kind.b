// How one grid row or column decides its size.
package layout

/// The three ways a grid track can be sized.
///
/// These are the same three every grid system converges on, because they
/// answer three different questions: "exactly this many points", "as big as
/// what is in it", and "a share of whatever is left".
pub enum TrackKind {
    /// A fixed number of points, whatever the content.
    fixed
    /// As large as the largest thing in the track, and no larger.
    auto
    /// A share of the space left after the fixed and auto tracks are settled.
    fraction

    pub fn name() -> string {
        match self {
            fixed => { return "fixed" }
            auto => { return "auto" }
            fraction => { return "fraction" }
        }
    }
}
