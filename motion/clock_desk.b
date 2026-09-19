// One host frame callback, and everything that rides it.
package motion

import latte.platform
import latte.input

/// The listeners on one scene's frame clock. A class, not a nested `Map`:
/// a map inside a map is move-only. Join order is kept so a golden can assert it.
pub class SceneListeners {
    by_token: Map<int, fn(Frame)> = {}
    joined: List<int> = []
    pub frames: int = 0
    pub elapsed: f64 = 0.0
    pub running: bool = false

    pub fn init() {}

    pub fn has(token: int) -> bool { return self.by_token.contains_key(token) }

    pub fn add(token: int, handler: fn(Frame)) {
        self.by_token[token] = handler
        self.joined.push(token)
    }

    /// Takes one off. Answers whether it was there, so the desk can tell a
    /// token that never joined from the last one leaving.
    pub fn remove(token: int) -> bool {
        if !self.by_token.contains_key(token) { return false }
        self.by_token.remove(token)
        var kept: List<int> = []
        for held: int in self.joined {
            if held != token { kept.push(held) }
        }
        self.joined = move kept
        return true
    }

    pub fn count() -> int { return self.by_token.len() }

    /// The tokens in the order they joined, copied so a handler that leaves
    /// during delivery cannot change the list being walked.
    pub fn tokens() -> List<int> {
        var every: List<int> = []
        for held: int in self.joined { every.push(held) }
        return move every
    }

    pub fn handler(token: int) -> Option<fn(Frame)> { return self.by_token.get(token) }
}

/// Every listener on every scene's clock, so one page can hold several moving
/// things while the host is asked for frames exactly once.
///
/// The host's callback is one-shot — that is the shape `requestAnimationFrame`
/// has — so the desk asks for the next frame at the end of each one, and only
/// while a scene still has listeners. **An idle scene asks for nothing**, which
/// is the property that keeps a still page off the GPU.
pub singleton class ClockDesk {
    desks: Map<u64, SceneListeners> = {}
    pending: bool = false
    last_nanos: int = 0

    fn init() {}

    /// Adds `handler` under `token`, asking the host for a frame when the
    /// first listener joins.
    pub fn join(scene: platform.Handle, router: input.EventRouter,
                token: int, handler: fn(Frame)) -> Result<bool> {
        var listeners: SceneListeners = self.listeners_for(scene)
        if listeners.has(token) {
            return err("this scene already has a frame listener under token {token} — give each one a token of its own",
                       "token_taken")
        }
        listeners.add(token, handler)
        listeners.running = true
        self.desks[scene.raw] = listeners
        self.arm()?
        return ok(true)
    }

    /// Takes one listener off; the host is asked for nothing more once the
    /// last scene goes quiet.
    pub fn leave(scene: platform.Handle, router: input.EventRouter,
                 token: int) -> Result<bool> {
        match self.desks.get(scene.raw) {
            none => { return ok(true) }
            some(listeners) => {
                if !listeners.remove(token) { return ok(true) }
                if listeners.count() > 0 { return ok(true) }
                self.desks.remove(scene.raw)
                if self.desks.len() == 0 && self.pending {
                    platform.HostDesk.instance.host().cancel_frame()?
                    self.pending = false
                }
                return ok(true)
            }
        }
    }

    /// How many listeners a scene has. A test asserts this; a program should
    /// not need it.
    pub fn listeners_on(scene: platform.Handle) -> int {
        match self.desks.get(scene.raw) {
            some(listeners) => { return listeners.count() }
            none => { return 0 }
        }
    }

    /// Whether a frame has been asked for and not yet delivered. The idle gate
    /// reads it: false with nothing moving is what "the page stopped drawing"
    /// means.
    pub fn frame_pending() -> bool { return self.pending }

    pub fn state(scene: platform.Handle) -> ClockState {
        match self.desks.get(scene.raw) {
            none => { return ClockState {} }
            some(listeners) => {
                return ClockState { running: listeners.running,
                                    frames: listeners.frames,
                                    elapsed: listeners.elapsed }
            }
        }
    }

    /// Delivers one frame to one scene without waiting for a display.
    pub fn step(scene: platform.Handle, seconds: f64) -> Result<bool> {
        match self.desks.get(scene.raw) {
            none => {
                return err("could not step a frame clock: this scene has no frame listener",
                           "wrong_moment")
            }
            some(listeners) => { self.deliver(scene, listeners, seconds); return ok(true) }
        }
    }

    /// Asks the host for the next frame, unless one is already on the way.
    fn arm() -> Result<bool> {
        if self.pending { return ok(false) }
        if self.desks.len() == 0 { return ok(false) }
        self.pending = true
        match platform.HostDesk.instance.host().request_frame(fn(seconds: f64) {
            ClockDesk.instance.tick(seconds)
        }) {
            ok(_) => { return ok(true) }
            err(problem) => { self.pending = false; return err(problem.msg, problem.kind) }
        }
    }

    /// The host's own callback. `seconds` is its clock, in seconds; only the
    /// difference between two of them is used, so its origin does not matter.
    pub fn tick(seconds: f64) {
        self.pending = false
        let now: int = (seconds * 1000000000.0) as int
        var delta: f64 = 0.0
        if self.last_nanos != 0 { delta = (now - self.last_nanos) as f64 / 1000000000.0 }
        self.last_nanos = now
        // Copied before the walk: a handler that leaves mid-delivery must not
        // change the map being iterated.
        var scenes: List<u64> = []
        for key: u64 in self.desks.keys() { scenes.push(key) }
        for key: u64 in scenes {
            match self.desks.get(key) {
                none => {}
                some(listeners) => { self.deliver(platform.Handle.of(key), listeners, delta) }
            }
        }
        self.arm()
    }

    /// Hands one frame to every listener on a scene, in the order they joined,
    /// each told its own token.
    fn deliver(scene: platform.Handle, listeners: SceneListeners, delta: f64) {
        listeners.frames = listeners.frames + 1
        listeners.elapsed = listeners.elapsed + delta
        let number: int = listeners.frames
        let elapsed: f64 = listeners.elapsed
        for token: int in listeners.tokens() {
            match listeners.handler(token) {
                none => {}
                some(handler) => { handler(Frame.at(number, elapsed, delta, token)) }
            }
        }
    }

    fn listeners_for(scene: platform.Handle) -> SceneListeners {
        match self.desks.get(scene.raw) {
            some(found) => { return found }
            none => { return new SceneListeners() }
        }
    }

    /// Drops every listener. Teardown in tests, so one suite's clock cannot
    /// tick into the next one's.
    pub fn reset() {
        self.desks = {}
        self.pending = false
        self.last_nanos = 0
    }
}
