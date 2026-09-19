// One row or column of a grid.
package layout

/// A grid track: how it is sized, and by how much.
///
/// `value` means points for a `fixed` track and a weight for a `fraction`
/// one. An `auto` track ignores it. One field serving two meanings is worth
/// the small ambiguity here: the alternative is a union or three structs, and
/// every caller writes `Track.fixed(120.0)` rather than touching the field.
pub struct Track {
    pub kind: TrackKind = TrackKind.auto
    pub value: f64 = 0.0

    /// Exactly `points` wide (or tall).
    pub static fn fixed(points: f64) -> Track {
        return Track { kind: TrackKind.fixed, value: points }
    }

    /// As large as the largest child in it.
    pub static fn auto() -> Track {
        return Track { kind: TrackKind.auto, value: 0.0 }
    }

    /// `weight` shares of the space left over. `Track.fraction(1.0)` is the
    /// web's `1fr`.
    pub static fn fraction(weight: f64) -> Track {
        return Track { kind: TrackKind.fraction, value: weight }
    }

    pub fn show() -> string {
        match self.kind {
            fixed => { return "{self.value}pt" }
            auto => { return "auto" }
            fraction => { return "{self.value}fr" }
        }
    }
}
