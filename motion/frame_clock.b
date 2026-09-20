// The beat everything that moves runs on.
package motion

import latte.platform
import latte.input

/// Asks the host to be told before every frame the display will show.
///
/// A clock rather than a timer, and the difference is the whole point: the
/// host's own frame callback drives it — `requestAnimationFrame` in a browser
/// — so the ticks are the refresh rate the screen really has. A program
/// written against this is already right on a 120 Hz display and already right
/// when the machine slows down, which is not true of anything built on an
/// interval somebody picked.
///
/// **It stops when nothing is moving.** One request buys one callback, and the
/// next is only asked for while there are listeners. An idle screen therefore
/// costs no frames at all, which is a property the idle-redraw check proves
/// rather than a claim.
pub class FrameClock {
    priv scene: platform.Handle = platform.Handle.none()
    priv router: input.EventRouter
    priv token: int = 0
    priv started: bool = false

    pub fn init(scene: platform.Handle, router: input.EventRouter) {
        self.scene = scene
        self.router = router
    }

    /// Starts the clock, calling `handler` before every frame.
    ///
    /// `token` comes back on every frame and says which listener it is for: a
    /// scene may have several. A repeated token is refused, not replaced.
    pub fn start(token: int, handler: fn(Frame)) -> Result<bool> {
        if self.started {
            return err("this frame clock is already running under token {self.token} — a second thing moving in the same scene is its own FrameClock, not this one started again",
                       "wrong_moment")
        }
        ClockDesk.instance.join(self.scene, self.router, token, handler)?
        self.token = token
        self.started = true
        return ok(true)
    }

    /// Stops it, and takes this clock's handler off with it.
    ///
    /// Stopping a clock that is not running succeeds: a teardown path should
    /// not have to ask first. The host's clock stops when the *last* listener
    /// on the scene leaves, which is what lets one canvas be taken off screen
    /// while another keeps moving.
    pub fn stop() -> Result<bool> {
        ClockDesk.instance.leave(self.scene, self.router, self.token)?
        self.started = false
        return ok(true)
    }

    /// What the clock is doing: running or not, how many frames it has
    /// delivered, and where it has got to.
    pub fn state() -> Result<ClockState> {
        return ok(ClockDesk.instance.state(self.scene))
    }

    /// Raises one frame, `seconds` after the previous one, without waiting for
    /// a display.
    ///
    /// The same idea as `Button.activate`: it drives the clock down the exact
    /// path a real frame takes rather than around it. It is how motion is
    /// tested where there is nothing on screen — and that is every build
    /// machine.
    pub fn step(seconds: f64) -> Result<bool> {
        if seconds <= 0.0 {
            return err("could not step a frame clock: a step is a positive number of seconds, and {seconds} is not",
                       "out_of_range")
        }
        return ClockDesk.instance.step(self.scene, seconds)
    }
}
