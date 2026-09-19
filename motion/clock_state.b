// What the platform says its clock is doing.
package motion

/// A frame clock's own account of itself.
///
/// `frames` counts the frames the clock actually handed over, so a program
/// that counted the frames it received can compare the two: a delivery path
/// that lost one is then a failing test rather than an animation that
/// finishes slightly early.
pub struct ClockState {
    pub running: bool = false
    pub frames: int = 0
    /// The `elapsed` of the last frame delivered, and 0 before the first.
    pub elapsed: f64 = 0.0

    pub fn show() -> string {
        return "running={self.running} frames={self.frames}"
    }
}
