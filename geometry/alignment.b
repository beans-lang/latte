// Where a box sits when it is smaller than the room it was given.
package geometry

/// Cross-axis placement for one child inside its parent's content box.
///
/// `inherit` exists so a child can say nothing and take its container's
/// default. Without it a child's alignment field would need an `Option`, and
/// every read site would have to unwrap it — the container's default is the
/// answer in the overwhelming majority of cases, so the type carries the
/// "no opinion" state itself.
///
/// `start` and `end` are **logical**: in a left-to-right layout `start` is the
/// left edge, and in a right-to-left one it is the right edge. The layout
/// engine resolves that by mirroring finished frames once, so nothing here
/// needs to know the text direction.
pub enum Align {
    inherit
    start
    center
    end
    stretch

    pub fn name() -> string {
        match self {
            inherit => { return "inherit" }
            start => { return "start" }
            center => { return "center" }
            end => { return "end" }
            stretch => { return "stretch" }
        }
    }

    /// This alignment, or `fallback` when this one has no opinion.
    ///
    /// A `fallback` that is itself `inherit` resolves to `start`, so the chain
    /// always terminates at a real answer and no caller has to handle
    /// `inherit` after resolving.
    pub fn resolve(fallback: Align) -> Align {
        if self != Align.inherit {
            return self
        }
        if fallback != Align.inherit {
            return fallback
        }
        return Align.start
    }

    /// Where a box of `extent` sits inside `room`, as an offset from the
    /// start edge. `stretch` answers 0 because a stretched box fills the room
    /// and has nowhere to sit.
    pub fn offset(extent: f64, room: f64) -> f64 {
        match self {
            center => { return (room - extent) / 2.0 }
            end => { return room - extent }
            start => { return 0.0 }
            stretch => { return 0.0 }
            inherit => { return 0.0 }
        }
    }
}
