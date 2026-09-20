// Where a frame's time went, when something asks.
package platform

// The phases a frame is cut into. The numbers are the order a benchmark reads
// them back in, so they are written rather than derived from a list's order.
pub const PHASE_INPUT: int = 0
pub const PHASE_HIT: int = 1
pub const PHASE_SOURCE: int = 2
pub const PHASE_COMPOSE: int = 3
pub const PHASE_DIFF: int = 4
pub const PHASE_LAYOUT: int = 5
pub const PHASE_SHAPE: int = 6
pub const PHASE_RECORD: int = 7
pub const PHASE_DRAW: int = 8
pub const PHASE_A11Y: int = 9
pub const PHASE_A11Y_PUBLISH: int = 10
pub const PHASE_COUNT: int = 11

// What a phase counts as well as times.
pub const TALLY_CELL_READS: int = 0
pub const TALLY_LIVE_CELLS: int = 1
pub const TALLY_SHAPED: int = 2
pub const TALLY_A11Y_NODES: int = 3
pub const TALLY_ELEMENTS: int = 4
pub const TALLY_CHANGES: int = 5
pub const TALLY_COUNT: int = 6

/// Exclusive time per phase, per frame.
///
/// Off until something turns it on, and one branch per boundary when it is:
/// a released page pays a load and a test-and-branch at each `enter`, which is
/// what lets the benchmark run the shipping build rather than a special one.
pub singleton class Probe {
    running: bool = false
    /// Open spans — the phase, when it opened, and the nanoseconds its
    /// children have taken — so a phase reports its own work and not its
    /// callees'. Shaping happens inside layout and inside recording.
    open_phase: List<int> = []
    open_start: List<int> = []
    open_child: List<int> = []
    /// This frame so far: exclusive nanoseconds per phase, then the tallies.
    live: List<int> = []
    live_tally: List<int> = []
    /// Every frame marked, PHASE_COUNT + TALLY_COUNT values each, oldest first.
    tape: List<int> = []
    frames_marked: int = 0

    fn init() { self.clear_frame() }

    pub fn on() -> bool { return self.running }

    /// Turns timing on or off. Turning it *on* clears whatever was recorded,
    /// so a run never mixes two settings; turning it off keeps the tape, which
    /// is the whole point of having one.
    pub fn enable(yes: bool) {
        if yes && !self.running { self.reset() }
        self.running = yes
        self.open_phase = []
        self.open_start = []
        self.open_child = []
    }

    pub fn reset() {
        self.tape = []
        self.frames_marked = 0
        self.open_phase = []
        self.open_start = []
        self.open_child = []
        self.clear_frame()
    }

    fn clear_frame() {
        self.live = []
        self.live_tally = []
        for index: int in 0..PHASE_COUNT { self.live.push(0) }
        for index: int in 0..TALLY_COUNT { self.live_tally.push(0) }
    }

    fn now() -> int { return HostDesk.instance.host().now_nanos() }

    pub fn enter(phase: int) {
        if !self.running { return }
        if phase < 0 || phase >= PHASE_COUNT { return }
        self.open_phase.push(phase)
        self.open_start.push(self.now())
        self.open_child.push(0)
    }

    /// Closes the innermost span. A phase that does not match the open one is
    /// dropped rather than guessed at: a mismatched pair is a bug in the
    /// instrumentation and silently shifting the numbers would hide it.
    pub fn leave(phase: int) {
        if !self.running { return }
        let depth: int = self.open_phase.len()
        if depth == 0 { return }
        if self.open_phase[depth - 1] != phase { return }
        let elapsed: int = self.now() - self.open_start[depth - 1]
        let inner: int = self.open_child[depth - 1]
        self.open_phase.remove(depth - 1)
        self.open_start.remove(depth - 1)
        self.open_child.remove(depth - 1)
        var own: int = elapsed - inner
        if own < 0 { own = 0 }
        self.live[phase] = self.live[phase] + own
        if self.open_phase.len() > 0 {
            let top: int = self.open_phase.len() - 1
            self.open_child[top] = self.open_child[top] + elapsed
        }
    }

    pub fn count(tally: int, amount: int) {
        if !self.running { return }
        if tally < 0 || tally >= TALLY_COUNT { return }
        self.live_tally[tally] = self.live_tally[tally] + amount
    }

    /// Replaces a tally rather than adding to it, for the ones that are a
    /// standing number — how many cells are alive — rather than an event count.
    pub fn note(tally: int, value: int) {
        if !self.running { return }
        if tally < 0 || tally >= TALLY_COUNT { return }
        self.live_tally[tally] = value
    }

    /// Ends one frame's row and starts the next. Everything still open is
    /// dropped: a span that crossed a frame boundary has no honest home.
    pub fn mark_frame() {
        if !self.running { return }
        for index: int in 0..PHASE_COUNT { self.tape.push(self.live[index]) }
        for index: int in 0..TALLY_COUNT { self.tape.push(self.live_tally[index]) }
        self.frames_marked = self.frames_marked + 1
        self.open_phase = []
        self.open_start = []
        self.open_child = []
        self.clear_frame()
    }

    pub fn frames() -> int { return self.frames_marked }

    /// One recorded number. Phases come back as milliseconds and tallies as
    /// counts, which is why the row is read by index rather than by name.
    pub fn value(frame: int, slot: int) -> f64 {
        let width: int = PHASE_COUNT + TALLY_COUNT
        if frame < 0 || frame >= self.frames_marked { return -1.0 }
        if slot < 0 || slot >= width { return -1.0 }
        let raw: int = self.tape[frame * width + slot]
        if slot < PHASE_COUNT { return raw as f64 / 1000000.0 }
        return raw as f64
    }

    pub fn row_width() -> int { return PHASE_COUNT + TALLY_COUNT }
}
