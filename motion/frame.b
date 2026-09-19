// One frame, as the program sees it.
package motion

import latte.input

/// What a frame clock hands a handler: which frame, how far in, and how long
/// since the last one.
///
/// A value rather than an object. It is read inside the handler and nothing
/// outlives the call, so it costs no allocation and copying it is free.
pub struct Frame {
    /// 1 for the first frame after the clock started, and one more each time.
    pub number: int = 0

    /// Seconds since the clock started.
    pub elapsed: f64 = 0.0

    /// Seconds since the previous frame — since the start, for frame 1.
    ///
    /// This is the number to move things by. Stepping by `delta` is what makes
    /// motion run at one speed on a 60 Hz screen and a 120 Hz one, and it stays
    /// honest when the machine stalls: no tick is dropped or merged, so the
    /// deltas always add up to `elapsed`.
    pub delta: f64 = 0.0

    /// The word `FrameClock.start` was given, echoed back on every frame.
    pub token: int = 0

    /// Reads a frame out of the event the clock raised.
    ///
    /// One event record carries every kind, so a frame's two times travel in
    /// the fields a pointer event uses for its position. That packing stops
    /// here — a handler is given this, never a `UiEvent` with a clock reading
    /// hidden in its `position`.
    pub static fn of(event: input.UiEvent) -> Frame {
        return Frame {
            number: event.index,
            elapsed: event.position.x,
            delta: event.position.y,
            token: event.token,
        }
    }

    /// A frame built from the clock's own numbers, with no event behind it.
    pub static fn at(number: int, elapsed: f64, delta: f64, token: int) -> Frame {
        return Frame { number: number, elapsed: elapsed, delta: delta, token: token }
    }

    /// What a golden can hold. The times are deliberately not in it: they are
    /// never the same twice, so printing them would make a test a report on
    /// how busy the machine was.
    pub fn show() -> string {
        return "frame #{self.number} token={self.token}"
    }
}
