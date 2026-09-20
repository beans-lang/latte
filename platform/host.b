// Everything Latte needs from whatever is hosting it.
package platform

/// The one seam between Latte and the world outside it.
///
/// Latte draws, lays out, edits and routes entirely in Beans. What it cannot
/// do for itself is exactly this: read the system's appearance, reach a
/// clipboard, be told when a frame is due, tell an input method where the
/// caret is, and publish an accessibility tree. Those are the methods here,
/// and there are no others — a `Host` is the complete list of things Latte
/// asks the outside for.
///
/// Every method answers a `Result`. A host that cannot do one of these says so
/// and the caller sees a refusal naming the capability; nothing here is
/// allowed to quietly do nothing, because a clipboard that silently fails is a
/// bug with no error, no log line and nothing to search for.
pub interface Host {
    /// Whether this host can do `what` at all. Asked before the call, so a
    /// program can take a different road rather than collect a refusal.
    fn can(what: Capability) -> bool

    fn appearance() -> Appearance
    /// Device pixels per logical point. 1.0 where nothing says otherwise.
    fn scale() -> f64
    /// The system's "reduce motion" setting. False where a host has none.
    fn reduce_motion() -> bool

    fn clipboard_write(text: string) -> Result<bool>
    fn clipboard_read() -> Result<string>

    /// A monotonic clock in nanoseconds. Only differences are meaningful.
    fn now_nanos() -> int

    /// Asks to be called back once, before the next frame the display shows.
    ///
    /// One request, one callback, **per caller**. A page has one
    /// `requestAnimationFrame` and more than one thing that wants it — the
    /// scene advancing its transitions, and a `motion.FrameClock` moving
    /// something a program wrote — so a host that kept one handler would
    /// deliver to whichever asked last and the other would wait forever.
    fn request_frame(handler: fn(f64)) -> Result<bool>
    /// Drops a pending request. Answers whether there was one.
    fn cancel_frame() -> Result<bool>

    /// Tells the host where text is being edited, so an input method can put
    /// its candidate window in the right place and a browser can keep its own
    /// editing state in step. `active` false ends the session.
    fn text_input(active: bool, text: string, anchor: int, caret: int,
                  x: f64, y: f64, width: f64, height: f64) -> Result<bool>

    /// Publishes one accessibility tree. `begin`, then a node per control in
    /// paint order, then `end` — the same three-call shape every platform's
    /// virtual-element API has.
    fn semantics_begin() -> Result<bool>
    fn semantics_node(id: u64, role: string, label: string, value: string,
                      x: f64, y: f64, width: f64, height: f64,
                      enabled: bool, focused: bool) -> Result<bool>
    fn semantics_end() -> Result<bool>
}

/// The host Latte is running under.
///
/// A singleton because there is one of them: a program has one clipboard, one
/// display and one accessibility tree, and a second `Host` would mean two
/// answers to "is it dark". `install` is how a runtime — the browser adapter,
/// or a test — puts its own in place.
///
/// The default is `HeadlessHost`, which refuses everything it cannot do and
/// runs a clock that only moves when a test moves it. That is the right
/// default: a suite with no browser around it gets deterministic frames and a
/// named refusal, rather than a host that pretends.
pub singleton class HostDesk {
    current: Host = new HeadlessHost()

    fn init() {}

    pub fn install(host: Host) {
        self.current = host
    }

    pub fn host() -> Host {
        return self.current
    }

    /// Puts the headless host back. Teardown in tests, so one suite's host
    /// cannot answer for the next one's.
    pub fn reset() {
        self.current = new HeadlessHost()
    }
}

/// The host a program has when nothing else is installed.
///
/// It is not a stub that says yes. Everything that needs a machine — a
/// clipboard, an input method, an accessibility tree — is refused by name.
/// What it does supply is a clock, because a test that steps frames needs one
/// and a clock is arithmetic, not a capability.
pub class HeadlessHost implements Host {
    nanos: int = 0
    /// Every handler waiting for the next frame. A list rather than one slot:
    /// two callers is the normal case, not the exception.
    pending: List<fn(f64)> = []

    pub fn init() {}

    pub fn can(what: Capability) -> bool {
        return match what {
            frame_clock => true,
            _ => false,
        }
    }

    pub fn appearance() -> Appearance { return Appearance.light }
    pub fn scale() -> f64 { return 1.0 }
    pub fn reduce_motion() -> bool { return false }

    pub fn clipboard_write(text: string) -> Result<bool> {
        return err("could not copy text: this host has no clipboard", "unsupported")
    }

    pub fn clipboard_read() -> Result<string> {
        return err("could not paste text: this host has no clipboard", "unsupported")
    }

    pub fn now_nanos() -> int { return self.nanos }

    pub fn request_frame(handler: fn(f64)) -> Result<bool> {
        self.pending.push(handler)
        return ok(true)
    }

    pub fn cancel_frame() -> Result<bool> {
        let had: bool = self.pending.len() > 0
        self.pending = []
        return ok(had)
    }

    /// Runs every pending frame callback, `seconds` after the last frame. The
    /// test clock: nothing here moves on its own.
    ///
    /// The list is taken before the walk, so a handler that asks for another
    /// frame from inside this one is waiting for the *next* frame and not
    /// running twice in this one.
    pub fn advance(seconds: f64) -> bool {
        self.nanos = self.nanos + (seconds * 1000000000.0) as int
        // Copied, not moved: a field cannot be moved out of yet, and a handler
        // that asks for a frame from inside this one waits for the next.
        var waiting: List<fn(f64)> = []
        for handler: fn(f64) in self.pending { waiting.push(handler) }
        self.pending = []
        if waiting.len() == 0 { return false }
        for handler: fn(f64) in waiting { handler(self.nanos as f64 / 1000000000.0) }
        return true
    }

    pub fn text_input(active: bool, text: string, anchor: int, caret: int,
                      x: f64, y: f64, width: f64, height: f64) -> Result<bool> {
        if !active { return ok(true) }
        return err("could not start text input: this host has no input method",
                   "unsupported")
    }

    pub fn semantics_begin() -> Result<bool> {
        return err("could not publish an accessibility tree: this host has none",
                   "unsupported")
    }

    pub fn semantics_node(id: u64, role: string, label: string, value: string,
                          x: f64, y: f64, width: f64, height: f64,
                          enabled: bool, focused: bool) -> Result<bool> {
        return err("could not publish an accessibility node: this host has none",
                   "unsupported")
    }

    pub fn semantics_end() -> Result<bool> {
        return err("could not publish an accessibility tree: this host has none",
                   "unsupported")
    }
}
