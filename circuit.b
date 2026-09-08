// The circuit — one tab's live connection to its page, as a state machine.
//
// Everything here is transport-free on purpose. `latte.web` owns the socket,
// the fibers and the clock; this file owns what a circuit MEANS: what a client
// message does, which batch number goes out, what an ack retires, what a
// disconnect retains, what a limit ends, and where a panic lands. Two things
// follow from that split and both are load-bearing:
//
//  * The module root must build for `wasm32-unknown-unknown --runtime
//    freestanding` (PLAN.md, D4). That refuses `brew`, `contained`, `std.time`,
//    `std.random`, `std.crypto` and `std.encoding.json` — measured, through
//    `--emit obj`, not just `check`. So containment arrives as an injected
//    `guard` closure and time arrives as a `now_ms` parameter. `Channel`,
//    `AtomicInt` and `Mutex` ARE allowed there, which is why the inbox and the
//    cross-thread push handle can live at the root.
//  * A package under `latte/` cannot import the module root, so `latte.web`
//    can never name `Circuit`. `CircuitSet` therefore hands the host a set of
//    closures over std types, and the app wires the two together in its own
//    `package main`.
//
// The socket rule W0 proved is not enforceable from here — it is a property of
// `latte.web` — but this file is written so that it CAN hold: nothing here
// writes anything. Frames accumulate in `outbox` and the host's single writer
// fiber drains it.
package latte

import std.fmt

// ---------------------------------------------------------------- options
//
// PLAN.md: "Limits, all options with defaults: client message size, inbox
// depth per circuit, un-acked batch window, virtual window size, idle circuit
// timeout, retention after disconnect, circuits per worker. **Crossing one
// ends the circuit with a `bye`, never a panic.**"
//
// Every one of them is here, and `bye_kind_for` names the kind each sends.

pub class CircuitOptions {
    /// Client message size, nesting depth, elements per array or object, and
    /// string length. See `WireLimits`.
    pub wire: WireLimits = new WireLimits()

    /// How many cross-thread jobs may be queued before `Push.post` refuses.
    /// A counter and not `try_send`, because `try_send` is not offered for a
    /// move-only element type and a full channel would otherwise PARK the
    /// posting thread — which is the one thing a push must never do
    /// (`probes/ANSWERS.md` §2).
    pub max_inbox: int = 64

    /// How far the batch number may run ahead of the client's last ack before
    /// the circuit ends. It is also the size of the replay buffer, because an
    /// un-acked batch is exactly a batch a reconnect might have to resend.
    pub max_unacked: int = 32

    /// The largest slice a `range` message may ask for. W6 owns virtual lists;
    /// the clamp lives here so a hostile client cannot ask for 50,000 rows in
    /// one message before W6 exists.
    pub max_window: int = 200

    /// No client message and no push for this long ends the circuit.
    pub idle_ms: int = 120000

    /// How long a dropped circuit is kept so a reconnect can replay.
    pub retention_ms: int = 30000

    /// How many circuits one `CircuitSet` will hold. Crossing it evicts the
    /// oldest DISCONNECTED circuit; if every circuit is live, the new one is
    /// refused rather than a live tab being killed for a new one.
    pub max_circuits: int = 1000

    /// How many render passes one event may cause. A component that dirties
    /// itself from its own render would otherwise spin forever; this surfaces
    /// it in its error boundary instead (PLAN.md, "DoS: render loops").
    pub max_renders: int = 32

    pub fn init() {}
}

// ---------------------------------------------------------------- boundaries
//
// An error boundary is a COMPONENT, not a flag on the renderer, because that
// is the only shape that answers "which boundary" for a handler at any depth:
// the nearest mounted `ErrorBoundary` at or above the component that bound the
// handler. `Builder.boundary` / `fail_boundary` / `end_boundary` do the frame
// work; this wraps them so an author writes one class and nothing else.

pub class ErrorBoundary extends Component {
    /// The content this boundary protects.
    pub body: fn(Builder) = fn(b: Builder) {}

    /// What to render instead, given the failure report. The default is plain
    /// and deliberately says nothing a server should not say out loud — the
    /// report a circuit hands it is a trace id, never a panic message
    /// (PLAN.md, "information disclosure").
    pub fallback: fn(Builder, string) = fn(b: Builder, report: string) {
        b.open(0, "div")
        b.attr(1, "class", "latte-error")
        b.text(2, "Something went wrong.")
        b.close()
    }

    /// Non-empty while this boundary is showing its fallback.
    pub failure: string = ""

    pub fn init() {}

    pub override fn render(b: Builder) {
        b.boundary(0)
        if self.failure == "" {
            b.fragment(1, self.body)
        } else {
            // Marks the boundary frame `failed`, so old-ok against new-failed
            // is a replacement to the differ rather than a silent match, and
            // restarts numbering — which is why the fallback numbers from 0.
            b.fail_boundary(self.failure)
            let show: fn(Builder, string) = self.fallback
            show(b, self.failure)
        }
        b.end_boundary()
    }

    /// Show the fallback from now on. Marks this component — not the one that
    /// failed — because this is the component whose rendered output changes.
    pub fn fail(report: string) {
        self.failure = report
        self.notify()
    }

    pub fn recover() {
        self.failure = ""
        self.notify()
    }
}

// ---------------------------------------------------------------- push
//
// The cross-thread push handle. `unique class … implements Send` is the only
// way a user class crosses a thread boundary, so a handle is MOVED into the
// thread that will use it and a circuit hands out one per poster.
//
// It carries no reference to a component and it cannot: a plain class
// reference is not Send, so a poster physically cannot capture the thing it
// means to change (`probes/ANSWERS.md` §2). The closure it posts receives the
// `Circuit` from the circuit fiber instead. That is also why the push path
// inherits "nothing on the wire is ever interpreted as a name" — there is no
// name and no reference for a poster to supply.
pub unique class Push implements Send {
    jobs: Channel<send fn(Circuit)>
    wake: Channel<string>
    depth: AtomicInt
    cap: int = 0

    pub fn init(jobs: Channel<send fn(Circuit)>, wake: Channel<string>,
                depth: AtomicInt, cap: int) {
        self.jobs = jobs
        self.wake = wake
        self.depth = depth
        self.cap = cap
    }

    /// Queue a job for the circuit fiber. `false` means the inbox is full and
    /// the job was NOT taken — the poster keeps it and decides, rather than
    /// parking inside a framework.
    ///
    /// The claim is made BEFORE the send, so the channel can never be full
    /// when `send` runs and `send` can therefore never park. Releasing the
    /// claim is the circuit fiber's job, after the job has run.
    pub fn post(move job: send fn(Circuit)) -> bool {
        if self.depth.add_and_get(1) > self.cap {
            let _: int = self.depth.add_and_get(-1)
            return false
        }
        self.jobs.send(move job)
        // A dropped marker costs nothing: the circuit fiber drains `jobs` on
        // EVERY wake, whatever woke it, so the worst case is that this job
        // waits for the next tick instead of jumping the queue.
        let _: bool = self.wake.try_send(WAKE_PUSH)
        return true
    }
}

/// The wake grammar. One `Channel<string>` carries every reason the circuit
/// fiber has to run, because `Channel` has no `receive_timeout` and a fiber
/// cannot wait on two channels at once.
pub const WAKE_PUSH: string = "p"
pub const WAKE_TICK: string = "t"
pub const WAKE_GONE: string = "x"
/// A client message is `"c"` followed by its text.
pub const WAKE_MESSAGE: string = "c"

// ---------------------------------------------------------------- retention

class SentBatch {
    pub number: int = 0
    pub text: string = ""
    pub fn init(number: int, text: string) {
        self.number = number
        self.text = text
    }
}

// ---------------------------------------------------------------- circuit

pub class Circuit {
    /// 256 bits from the host's CSPRNG, bound to the session. Never in a URL,
    /// never logged (PLAN.md, "circuit id theft or fixation"). The root does
    /// not make it — `std.random` is refused here — it is handed in.
    pub id: string = ""
    pub options: CircuitOptions = new CircuitOptions()
    pub renderer: Renderer = new Renderer()

    /// Server-side only, and it never reaches the wire. A contained panic's
    /// message goes here; what the client sees is a trace id.
    pub log: List<string> = []

    /// Frames the host's single writer fiber must send, in order.
    outbox: List<string> = []

    /// Containment, injected because `brew` and `contained` are both refused
    /// at the module root. The default runs the body with no boundary at all,
    /// which is right for a wasm host and for a suite driving the state
    /// machine by hand; `latte.web` installs `latte.boundary.run`.
    pub guard: fn(fn() -> bool) -> string =
        fn(body: fn() -> bool) -> string { let _: bool = body(); return "" }

    /// The page. `none` until `attach`.
    page: Option<Component> = none
    make_page: fn(string) -> Option<Component> =
        fn(url: string) -> Option<Component> { return none }

    batch_number: int = 0
    last_ack: int = 0
    sent: List<SentBatch> = []

    attached: bool = false
    ended: bool = false
    end_kind: string = ""
    end_message: string = ""
    connected: bool = true
    /// When the last client message or push arrived.
    seen_ms: int = 0
    /// When the socket went away, or -1 while it is up.
    dropped_ms: int = -1

    pub jobs: Channel<send fn(Circuit)>
    pub wake: Channel<string>
    depth: AtomicInt

    next_call: int = 1
    waiting: Map<int, fn(bool, string)> = {}

    /// Set for the duration of one guarded dispatch, because a closure that
    /// mutates a local is a shape `brew`'s fabricated closure will not take —
    /// so the state a guarded body reads and writes lives on `self`.
    running: ClientMessage = new ClientMessage()
    landed: bool = false

    /// Every trace id this circuit has issued, newest last. A suite reads it;
    /// nothing else does.
    pub traces: List<string> = []
    trace_next: int = 1

    pub fn init(id: string, options: CircuitOptions,
                make_page: fn(string) -> Option<Component>) {
        self.id = id
        self.options = options
        self.make_page = make_page
        self.jobs = new Channel(options.max_inbox)
        // One slot per inbox slot, plus room for a tick and a reader sentinel
        // that must never be dropped.
        self.wake = new Channel(options.max_inbox + 8)
        self.depth = new AtomicInt(0)
    }

    // ---- what the host asks ----------------------------------------------

    pub fn ending() -> bool { return self.ended }
    pub fn end_reason() -> string { return self.end_kind }
    pub fn is_attached() -> bool { return self.attached }
    pub fn is_connected() -> bool { return self.connected }
    pub fn batch_count() -> int { return self.batch_number }
    pub fn acked() -> int { return self.last_ack }
    pub fn retained() -> int { return self.sent.len() }
    pub fn inbox_depth() -> int { return self.depth.load() }

    /// Take everything queued for the wire. The host's writer fiber calls this
    /// and nothing else writes.
    pub fn take_outbox() -> List<string> {
        var out: List<string> = []
        for frame: string in self.outbox { out.push(frame) }
        self.outbox.clear()
        return move out
    }

    /// A handle another OS thread can hold. One per poster: it is `unique`, so
    /// it is moved into the thread that uses it.
    pub fn push_handle() -> Push {
        return new Push(self.jobs, self.wake, self.depth, self.options.max_inbox)
    }

    // ---- opening ----------------------------------------------------------

    /// The first frame on the wire. Sent before anything is rendered, so a
    /// client that does not know this protocol version stops before it has
    /// applied a batch it cannot read.
    pub fn open(now_ms: int) {
        self.seen_ms = now_ms
        self.outbox.push(encode_hello(self.id, self.options.wire))
    }

    // ---- one client message ----------------------------------------------

    /// Consume one message from the client. Never panics, never parks.
    pub fn accept(text: string, now_ms: int) {
        if self.ended { return }
        self.seen_ms = now_ms
        let message: ClientMessage = decode_client(text, self.options.wire)
        if message.fault != "" {
            self.stop("protocol", message.fault)
            return
        }
        if message.kind == CLIENT_ATTACH { self.on_attach(message, now_ms); return }
        if message.kind == CLIENT_RESUME { self.on_resume(message, now_ms); return }
        if !self.attached {
            self.stop("protocol", "a {kind_name(message.kind)} arrived before attach")
            return
        }
        if message.kind == CLIENT_EVENT { self.on_event(message, now_ms) }
        else if message.kind == CLIENT_ACK { self.on_ack(message) }
        else if message.kind == CLIENT_NAV { self.on_nav(message, now_ms) }
        else if message.kind == CLIENT_JS { self.on_js(message, now_ms) }
        else if message.kind == CLIENT_RANGE { self.on_range(message) }
        else { self.stop("protocol", "unhandled message kind"); return }
        // Every path above that dispatched has already settled; this is for
        // the ones that did NOT — a stale handler id, an ack, a range — after
        // which the renderer may still hold work raised from somewhere else.
        // A `notify()` from a Callback, a timer or an error boundary's own
        // `recover()` is not tied to any message, and without this it would
        // sit unsent until the next tick. The probe that found it: recover()
        // then a click on a slot id the failed boundary had already disposed
        // — the click landed nowhere, so nothing settled, so the recovery
        // never went out.
        if !self.ended { self.settle(now_ms) }
    }

    fn on_attach(message: ClientMessage, now_ms: int) {
        // The id the client presents must be the one this circuit was opened
        // with. The host has already checked it against the session cookie;
        // this is the second half of the same check and it is cheap.
        if message.circuit != self.id {
            self.stop("forbidden", "the circuit id does not match this connection")
            return
        }
        if self.attached {
            self.stop("protocol", "attach arrived twice on one circuit")
            return
        }
        let build: fn(string) -> Option<Component> = self.make_page
        match build(message.url) {
            some(component) => {
                self.page = some(component)
                self.attached = true
                self.renderer.mount(component)
                self.publish()
            }
            none => { self.stop("notfound", "no page answers that url") }
        }
    }

    fn on_resume(message: ClientMessage, now_ms: int) {
        if message.circuit != self.id {
            self.stop("forbidden", "the circuit id does not match this connection")
            return
        }
        if !self.attached {
            self.stop("protocol", "resume on a circuit that never attached")
            return
        }
        // Everything at or below `last_ack` has been dropped from the replay
        // buffer, so a client asking to resume from further back than that is
        // asking for frames this end no longer holds. Say so rather than
        // sending it a hole.
        if message.batch < self.last_ack {
            self.stop("stale", "the client is behind the retained batches")
            return
        }
        self.connected = true
        self.dropped_ms = -1
        self.retire(message.batch)
        for batch: SentBatch in self.sent { self.outbox.push(batch.text) }
    }

    fn on_ack(message: ClientMessage) {
        if message.batch > self.batch_number {
            self.stop("protocol", "an ack for a batch that was never sent")
            return
        }
        if message.batch < self.last_ack {
            // Out of order or replayed. Not fatal: acks are monotonic on a
            // healthy client and an older one carries no information.
            return
        }
        self.retire(message.batch)
    }

    fn on_nav(message: ClientMessage, now_ms: int) {
        if !nav_target_is_local(message.url) {
            self.stop("forbidden", "a navigation target must be same-origin and path-only")
            return
        }
        let build: fn(string) -> Option<Component> = self.make_page
        match build(message.url) {
            some(component) => {
                self.page = some(component)
                self.renderer = new Renderer()
                self.renderer.mount(component)
                self.publish()
            }
            none => { self.stop("notfound", "no page answers that url") }
        }
    }

    fn on_js(message: ClientMessage, now_ms: int) {
        match self.waiting.get(message.call) {
            some(then) => {
                let _: bool = self.waiting.remove(message.call)
                self.running = message
                let g: fn(fn() -> bool) -> string = self.guard
                let report: string = g(fn() -> bool { return self.run_js_result(then) })
                if report != "" { self.contain(0, report); return }
                self.settle(now_ms)
            }
            none => {
                // A result for a call this end never made, or made twice. Not
                // fatal — a reconnecting client may still be holding one — but
                // it is not dispatched either.
                self.log.push("a js result arrived for call {message.call}, which is not outstanding")
            }
        }
    }

    fn run_js_result(then: fn(bool, string)) -> bool {
        then(self.running.ok, self.running.value)
        return true
    }

    fn on_range(message: ClientMessage) {
        // The range is untrusted input (PLAN.md, "virtual range abuse"), and
        // TWO different caps stand in front of it. This is the WIRE's: a
        // message asking for more than `max_window` rows ends the circuit,
        // because no client latte ships ever sends one. `VirtualGeometry`
        // then trims whatever survives against the collection, silently,
        // because a range that runs off the end of a list which shrank under
        // the user is ordinary and must not cost a session.
        if message.count > self.options.max_window {
            self.stop("limit", "a range asked for {message.count} rows, over the {self.options.max_window} cap")
            return
        }
        // `h` on a range is a COMPONENT id — the number `Virtual.render`
        // wrote into `data-latte-virtual` — and not a handler slot. Nothing
        // off the wire is ever a name: the client hands back a number and the
        // renderer looks it up, so a message can only ever reach a component
        // this page actually mounted.
        match self.renderer.component(message.handler) {
            some(component) => {
                match component as? Virtual {
                    some(list) => {
                        let moved: bool = list.apply_range(message.start, message.count)
                        var tail: string = " (unchanged)"
                        if moved { tail = "" }
                        self.log.push(
                            "range {message.start}+{message.count} on list {message.handler} -> {list.placement.describe()}{tail}")
                    }
                    none => {
                        // Not an error, and not a reason to end a session: a
                        // page that re-rendered into a different shape between
                        // the scroll and the message leaves the client holding
                        // an id that now belongs to something else. It is the
                        // rule `on_event` applies to a stale handler id, for
                        // the same reason — a race between a scroll and a
                        // re-render must not look like an attack.
                        self.log.push(
                            "range {message.start}+{message.count} on {message.handler}, which is not a virtual list")
                    }
                }
            }
            none => {
                self.log.push(
                    "range {message.start}+{message.count} on {message.handler}, which is not mounted")
            }
        }
    }

    // ---- the event path ---------------------------------------------------

    fn on_event(message: ClientMessage, now_ms: int) {
        let owner: int = self.renderer.owner_of(message.handler)
        self.running = message
        self.landed = false
        let g: fn(fn() -> bool) -> string = self.guard
        let report: string = g(fn() -> bool { return self.run_event() })
        if report != "" {
            self.contain(owner, report)
            return
        }
        if !self.landed {
            // A stale wire id: a row that left the page, or a handler from
            // before a reconnect. Nothing is marked, because marking on an
            // unknown id would let a client dirty a component by guessing a
            // number. It is not an error either — it is what a race between a
            // click and a re-render looks like.
            self.log.push("no handler bound to slot {message.handler}")
            return
        }
        self.settle(now_ms)
    }

    /// The guarded body. It reads `self.running` rather than a captured local
    /// because a closure that mutates a local is not a shape a brewed body
    /// takes, and because both spellings of containment hoist their arguments.
    fn run_event() -> bool {
        let message: ClientMessage = self.running
        if message.family == FAMILY_MOUSE {
            self.landed = self.renderer.fire_mouse(message.handler, mouse_event(message))
        } else if message.family == FAMILY_INPUT {
            self.landed = self.renderer.fire_input(message.handler, input_event(message))
        } else if message.family == FAMILY_KEYBOARD {
            self.landed = self.renderer.fire_keyboard(message.handler, keyboard_event(message))
        } else if message.family == FAMILY_SUBMIT {
            self.landed = self.renderer.fire_submit(message.handler, submit_event(message))
        } else if message.family == FAMILY_FOCUS {
            self.landed = self.renderer.fire_focus(message.handler, focus_event(message))
        }
        return true
    }

    // ---- containment ------------------------------------------------------

    /// A handler panicked. The panic is already contained — the fiber it ran
    /// on is gone and its frames are unwound — so what is left is where to
    /// show it.
    ///
    /// The nearest `ErrorBoundary` at or above `from` renders its fallback and
    /// the circuit continues. With NO boundary anywhere above it, the circuit
    /// ENDS: half a handler ran, the component's state is whatever that half
    /// left behind, and continuing would keep serving a page built from it.
    /// That is Blazor's rule too, and it is why an app that wants to survive a
    /// handler panic has to say where.
    fn contain(from: int, report: string) {
        let trace: string = "t{self.trace_next}"
        self.trace_next += 1
        self.traces.push(trace)
        // The message stays server-side; the client gets an id it can quote.
        self.log.push("{trace}: {report}")
        match self.nearest_boundary(from) {
            some(guard) => {
                self.outbox.push(encode_err("panic", trace))
                guard.fail(trace)
                self.settle(self.seen_ms)
            }
            none => {
                self.stop("panic", trace)
            }
        }
    }

    /// The nearest mounted `ErrorBoundary` at or above `from`, walking the
    /// mount tree. `from` may be -1 (an unknown owner), in which case the walk
    /// starts at the page root.
    fn nearest_boundary(from: int) -> Option<ErrorBoundary> {
        var parents: Map<int, int> = self.parent_map()
        var walk: int = from
        if walk < 0 { walk = 0 }
        for true {
            match self.renderer.component(walk) {
                some(component) => {
                    match component as? ErrorBoundary {
                        some(guard) => { return some(guard) }
                        none => {}
                    }
                }
                none => {}
            }
            match parents.get(walk) {
                some(up) => { walk = up }
                none => { return none }
            }
        }
        return none
    }

    /// child id -> parent id, from the Builder tree. `Renderer` keeps this
    /// index privately; rebuilding it here costs one walk of the mounted
    /// components and happens only on a failure path.
    fn parent_map() -> Map<int, int> {
        var out: Map<int, int> = {}
        var ids: List<int> = self.renderer.ids()
        for id: int in ids {
            match self.renderer.buffer(id) {
                some(buffer) => {
                    var slots: List<int> = buffer.nested.keys()
                    slots.sort()
                    for slot: int in slots { out[slot] = id }
                }
                none => {}
            }
        }
        return move out
    }

    // ---- the inbox --------------------------------------------------------

    /// Run every queued cross-thread job, then publish whatever they dirtied.
    /// `try_receive` never parks, so the whole inbox drains in one pass
    /// between renders rather than a park per job.
    pub fn drain(now_ms: int) -> int {
        var ran: int = 0
        var more: bool = true
        for more && !self.ended {
            match self.jobs.try_receive() {
                some(job) => {
                    let g: fn(fn() -> bool) -> string = self.guard
                    // `move(job)` because the element type is move-only: the
                    // closure has to OWN the job, and a field could not hand
                    // it back out again ("binding cannot move a field yet").
                    let report: string = g(fn() move(job) -> bool {
                        job(self)
                        return true
                    })
                    let _: int = self.depth.add_and_get(-1)
                    ran += 1
                    self.seen_ms = now_ms
                    if report != "" { self.contain(0, report) }
                }
                none => { more = false }
            }
        }
        if ran > 0 && !self.ended { self.settle(now_ms) }
        return ran
    }

    // ---- time -------------------------------------------------------------

    /// Called by the host's ticker. Answers `true` when it did something.
    pub fn tick(now_ms: int) -> bool {
        if self.ended { return false }
        var worked: bool = self.drain(now_ms) > 0
        // Anything `notify()`ed between messages settles here, which is what
        // makes a timer, a Callback or a boundary recovery reach the wire on
        // a circuit nobody is clicking.
        if !self.ended && self.renderer.pending() > 0 {
            self.settle(now_ms)
            worked = true
        }
        if self.connected && now_ms - self.seen_ms >= self.options.idle_ms {
            self.stop("idle", "no message for {self.options.idle_ms} ms")
            worked = true
        }
        return worked
    }

    /// The socket went away. The circuit is KEPT — its state, its handlers and
    /// its un-acked batches — so a reconnect inside the retention window
    /// replays instead of re-rendering the world.
    pub fn disconnected(now_ms: int) {
        self.connected = false
        self.dropped_ms = now_ms
        // Anything still queued for a socket that is gone is dropped: a
        // reconnect replays from `sent`, which is the record that survives.
        self.outbox.clear()
    }

    pub fn expired(now_ms: int) -> bool {
        if self.connected { return false }
        if self.dropped_ms < 0 { return false }
        return now_ms - self.dropped_ms >= self.options.retention_ms
    }

    // ---- rendering --------------------------------------------------------

    /// Render until the dirty set is empty, then publish one batch.
    ///
    /// The cap is what makes a component that dirties itself a visible failure
    /// instead of a hung worker. It is charged per EVENT, not per pass, which
    /// is the only reading under which "the component that will not settle" is
    /// the thing reported.
    fn settle(now_ms: int) {
        var passes: int = 0
        for self.renderer.pending() > 0 && !self.ended {
            passes += 1
            if passes > self.options.max_renders {
                let culprit: int = self.first_dirty()
                self.contain(culprit,
                    "a component re-rendered itself {self.options.max_renders} times without settling")
                return
            }
            let _: int = self.renderer.flush()
        }
        self.publish()
    }

    fn first_dirty() -> int {
        var ids: List<int> = self.renderer.ids()
        for id: int in ids { if self.renderer.is_dirty(id) { return id } }
        return 0
    }

    /// Turn whatever re-rendered into one wire frame, if anything did.
    fn publish() {
        if self.ended { return }
        let batch: Batch = self.renderer.batch()
        if batch.updates.len() == 0 && batch.disposed.len() == 0 { return }
        self.batch_number += 1
        let text: string = encode_batch(self.batch_number, batch)
        self.sent.push(new SentBatch(self.batch_number, text))
        if self.connected { self.outbox.push(text) }
        if self.batch_number - self.last_ack > self.options.max_unacked {
            self.stop("limit",
                "{self.batch_number - self.last_ack} batches went out un-acked, over the {self.options.max_unacked} window")
        }
    }

    /// Drop every retained batch at or below `through`.
    fn retire(through: int) {
        self.last_ack = through
        var keep: List<SentBatch> = []
        for batch: SentBatch in self.sent {
            if batch.number > through { keep.push(batch) }
        }
        self.sent = move keep
    }

    // ---- JS interop -------------------------------------------------------

    /// Ask the browser to run a function the PAGE registered with
    /// `latte.register(name, fn)`. `name` selects from that registry and
    /// nothing else: the client never evaluates a string, never reads a
    /// property named on the wire, and refuses a name it was not given.
    ///
    /// Answers the call id. `then` runs on the circuit fiber when the result
    /// comes back, under the same containment an event gets.
    pub fn js_call(name: string, args: List<string>, then: fn(bool, string)) -> int {
        let call: int = self.next_call
        self.next_call += 1
        self.waiting[call] = then
        self.outbox.push(encode_js(call, name, args))
        return call
    }

    pub fn outstanding_calls() -> int { return self.waiting.len() }

    /// Server-driven navigation. Refused unless it is same-origin and
    /// path-only, so an open redirect has no spelling here either.
    pub fn navigate(url: string) -> bool {
        if !nav_target_is_local(url) { return false }
        self.outbox.push(encode_nav(url))
        return true
    }

    // ---- ending -----------------------------------------------------------

    /// End the circuit with a `bye`. Idempotent, and it is the ONLY way a
    /// circuit ends: no path here panics, and every limit routes through it.
    pub fn stop(kind: string, message: string) {
        if self.ended { return }
        self.ended = true
        self.end_kind = kind
        self.end_message = message
        self.outbox.push(encode_bye(kind, message))
    }

    /// The whole page as HTML — what a prerender sends, and what a suite
    /// compares an applier against.
    pub fn html() -> string { return self.renderer.html() }

    /// The mounted page, or `none` before `attach`.
    ///
    /// A job posted from another OS thread arrives as a `send fn(Circuit)`,
    /// and a `send` closure may capture nothing that is not itself `Send` — so
    /// a poster cannot bring the component along. This is how the job it
    /// posted finds the page: on the circuit's own fiber, where touching
    /// component state is safe, and nowhere else.
    pub fn page_component() -> Option<Component> { return self.page }
}

fn kind_name(kind: int) -> string {
    if kind == CLIENT_ATTACH { return "attach" }
    if kind == CLIENT_RESUME { return "resume" }
    if kind == CLIENT_EVENT { return "ev" }
    if kind == CLIENT_ACK { return "ack" }
    if kind == CLIENT_NAV { return "nav" }
    if kind == CLIENT_JS { return "js" }
    if kind == CLIENT_RANGE { return "range" }
    return "message"
}

/// Same-origin and path-only. A navigation target is the one string a client
/// sends that this end turns into a request, so it is the one place an open
/// redirect or an SSRF could start (PLAN.md, "open redirect and SSRF through
/// navigation").
///
/// The rule is deliberately narrow: it must begin with exactly one `/`, hold
/// no control byte, no backslash and no `..` segment. `//host` is refused
/// because a browser reads it as scheme-relative and it is a different origin;
/// a backslash is refused because several browsers normalise `\` to `/` before
/// they parse the authority.
pub fn nav_target_is_local(url: string) -> bool {
    if url.len() == 0 { return false }
    if url.byte_at(0) != 47 { return false }
    if url.len() > 1 && url.byte_at(1) == 47 { return false }
    var index: int = 0
    for index < url.len() {
        let byte: int = url.byte_at(index)
        if byte < 32 || byte == 127 { return false }
        if byte == 92 { return false }
        index += 1
    }
    let path: string = stop_at(url, 63)
    for piece: string in stop_at(path, 35).split("/") {
        if piece == ".." { return false }
    }
    return true
}

fn stop_at(text: string, byte: int) -> string {
    let at: int = text.find_byte(byte, 0)
    if at < 0 { return text }
    return text.slice(0, at)
}

// ---------------------------------------------------------------- the set
//
// Every circuit one worker holds, and the closures `latte.web` drives them
// through. The seam carries `int`, `string`, `bool`, `List<string>`,
// `Map<string, string>` and `Channel<string>` — std types only — because
// `latte.web` cannot name a single type in this file.

pub class CircuitSet {
    pub options: CircuitOptions = new CircuitOptions()

    /// Given the handshake facts — `id`, `url`, and whatever else the host
    /// puts there — answer the page to mount, or `none` to refuse.
    make: fn(Map<string, string>, string) -> Option<Component> =
        fn(facts: Map<string, string>, url: string) -> Option<Component> { return none }

    /// Containment, handed on to every circuit this set opens.
    pub guard: fn(fn() -> bool) -> string =
        fn(body: fn() -> bool) -> string { let _: bool = body(); return "" }

    live: Map<int, Circuit> = {}
    handles: Map<string, int> = {}
    /// The session each circuit was opened for, from `facts["session"]`. It is
    /// what `adopt` compares: a reconnect may only pick up a circuit its own
    /// session opened, or one stolen id would hand a whole live page away.
    sessions: Map<int, string> = {}
    order: List<int> = []
    next_handle: int = 1

    /// Anything the set refused, for a host that wants to log it.
    pub faults: List<string> = []

    pub fn init(options: CircuitOptions,
                make: fn(Map<string, string>, string) -> Option<Component>) {
        self.options = options
        self.make = make
    }

    pub fn count() -> int { return self.live.len() }

    pub fn handle_for(id: string) -> int {
        match self.handles.get(id) { some(handle) => { return handle } none => { return -1 } }
    }

    pub fn circuit(handle: int) -> Option<Circuit> { return self.live.get(handle) }

    /// Open a circuit for a socket that has just been accepted.
    ///
    /// `facts` is whatever the host learned during the handshake; `id` is the
    /// one key this file reads. Answers a handle, or -1 with a fault recorded.
    pub fn open(facts: Map<string, string>, now_ms: int) -> int {
        let id: string = read_fact(facts, "id")
        if id.len() < 16 {
            self.faults.push("a circuit id must be at least 16 characters")
            return -1
        }
        if self.handles.contains_key(id) {
            self.faults.push("a circuit with that id is already open")
            return -1
        }
        if self.live.len() >= self.options.max_circuits {
            if !self.evict(now_ms) {
                self.faults.push(
                    "this worker already holds {self.options.max_circuits} live circuits")
                return -1
            }
        }
        let handle: int = self.next_handle
        self.next_handle += 1
        let made: Circuit = new Circuit(id, self.options, self.page_maker(facts))
        made.guard = self.guard
        made.open(now_ms)
        self.live[handle] = made
        self.handles[id] = handle
        self.sessions[handle] = read_fact(facts, "session")
        self.order.push(handle)
        return handle
    }

    /// The session a handle belongs to, or `""` when the host named none.
    pub fn session_of(handle: int) -> string {
        match self.sessions.get(handle) {
            some(name) => { return name }
            none => { return "" }
        }
    }

    /// Whatever is queued for the wire on `handle`, and nothing else.
    ///
    /// `open` queues the `hello` before any message has arrived, so the host's
    /// writer needs a way to collect it that is not `accept` and not `tick`.
    /// This is that way, and it is the only other reader of the outbox.
    pub fn outbox(handle: int) -> List<string> {
        match self.live.get(handle) {
            some(found) => { return found.take_outbox() }
            none => { return [] }
        }
    }

    /// The socket's FIRST message may be a `resume` naming a circuit this
    /// connection did not open. Answer the handle that message belongs to.
    ///
    /// A reconnecting client comes back on a new socket, and the host has
    /// already opened a fresh circuit for it and announced that circuit's id
    /// in `hello` — it could not have done otherwise, because nothing in the
    /// handshake says which circuit the client is coming back to. So the
    /// client's `resume` names a DIFFERENT circuit, and `Circuit.on_resume`
    /// would refuse it as `forbidden`. This moves the socket to the retained
    /// circuit instead and retires the fresh one, which nothing ever attached
    /// to and which therefore has nothing worth keeping.
    ///
    /// It answers `handle` unchanged whenever it will not move the socket, and
    /// then `accept` says why in a `bye` the client can read: an unknown id or
    /// an expired one is `forbidden`, a resume of this very circuit is
    /// `protocol`. Nothing here ends a circuit and nothing here writes.
    ///
    /// **Only the first message can adopt.** Once a socket's circuit is
    /// attached, a later `resume` on it is an ordinary in-circuit resume and
    /// belongs to the circuit it is already talking to.
    pub fn adopt(handle: int, text: string, now_ms: int) -> int {
        var fresh: Circuit = new Circuit("", self.options,
            fn(url: string) -> Option<Component> { return none })
        match self.live.get(handle) {
            some(found) => { fresh = found }
            none => { return handle }
        }
        if fresh.is_attached() { return handle }
        let message: ClientMessage = decode_client(text, self.options.wire)
        if message.fault != "" { return handle }
        if message.kind != CLIENT_RESUME { return handle }
        if message.circuit == "" { return handle }
        if message.circuit == fresh.id { return handle }
        var target: int = -1
        match self.handles.get(message.circuit) {
            some(other) => { target = other }
            none => { return handle }
        }
        var retained: Circuit = fresh
        match self.live.get(target) {
            some(found) => { retained = found }
            none => { return handle }
        }
        if retained.expired(now_ms) { self.forget(target); return handle }
        if retained.ending() { self.forget(target); return handle }
        if !retained.is_attached() { return handle }
        // The control that makes a stolen id useless. Both sides come from
        // `facts["session"]`, which the host reads from the handshake and the
        // wire never touches.
        if self.session_of(target) != self.session_of(handle) {
            self.faults.push(
                "a resume named a circuit that belongs to another session")
            return handle
        }
        self.forget(handle)
        return target
    }

    /// The per-circuit page factory: the set's `make` with this connection's
    /// facts already bound, so a `Circuit` never sees a `Map` off the wire.
    fn page_maker(facts: Map<string, string>) -> fn(string) -> Option<Component> {
        let build: fn(Map<string, string>, string) -> Option<Component> = self.make
        return fn(url: string) -> Option<Component> { return build(facts, url) }
    }

    /// Oldest-first eviction, and only of a DISCONNECTED circuit: killing a
    /// live tab to make room for a new one trades a working session for a
    /// speculative one. Answers whether room was made.
    fn evict(now_ms: int) -> bool {
        for handle: int in self.order {
            match self.live.get(handle) {
                some(existing) => {
                    if !existing.is_connected() {
                        self.forget(handle)
                        return true
                    }
                }
                none => {}
            }
        }
        return false
    }

    /// Feed one client message to one circuit and take back what it queued.
    pub fn accept(handle: int, text: string, now_ms: int) -> List<string> {
        match self.live.get(handle) {
            some(found) => {
                found.accept(text, now_ms)
                return found.take_outbox()
            }
            none => {
                var out: List<string> = []
                out.push(encode_bye("gone", "this circuit is no longer open"))
                return move out
            }
        }
    }

    /// One timer tick for one circuit, plus the retention sweep for the set.
    pub fn tick(handle: int, now_ms: int) -> List<string> {
        let _: int = self.sweep(now_ms)
        match self.live.get(handle) {
            some(found) => {
                let _: bool = found.tick(now_ms)
                return found.take_outbox()
            }
            none => { return [] }
        }
    }

    pub fn ending(handle: int) -> bool {
        match self.live.get(handle) {
            some(found) => { return found.ending() }
            none => { return true }
        }
    }

    /// The socket for `handle` is gone. The circuit is retained so a reconnect
    /// can replay — unless it had already ended, in which case there is
    /// nothing to come back to.
    pub fn disconnect(handle: int, now_ms: int) -> bool {
        match self.live.get(handle) {
            some(found) => {
                if found.ending() { self.forget(handle); return false }
                found.disconnected(now_ms)
                return true
            }
            none => { return false }
        }
    }

    /// Reattach a retained circuit to a new socket. Answers its handle, or -1.
    pub fn resume(id: string, now_ms: int) -> int {
        match self.handles.get(id) {
            some(handle) => {
                match self.live.get(handle) {
                    some(found) => {
                        if found.expired(now_ms) { self.forget(handle); return -1 }
                        if found.ending() { self.forget(handle); return -1 }
                        return handle
                    }
                    none => { return -1 }
                }
            }
            none => { return -1 }
        }
    }

    /// Drop every circuit whose retention window has passed. Answers how many.
    pub fn sweep(now_ms: int) -> int {
        var dead: List<int> = []
        var handles: List<int> = self.live.keys()
        handles.sort()
        for handle: int in handles {
            match self.live.get(handle) {
                some(found) => { if found.expired(now_ms) { dead.push(handle) } }
                none => {}
            }
        }
        for handle: int in dead { self.forget(handle) }
        return dead.len()
    }

    fn forget(handle: int) {
        match self.live.get(handle) {
            some(found) => { let _: bool = self.handles.remove(found.id) }
            none => {}
        }
        let _: bool = self.live.remove(handle)
        let _: bool = self.sessions.remove(handle)
        var kept: List<int> = []
        for existing: int in self.order { if existing != handle { kept.push(existing) } }
        self.order = move kept
    }

    /// The wake channel for one circuit. `latte.web`'s reader fiber, ticker
    /// and any cross-thread poster all send into it; the circuit fiber is the
    /// only reader.
    pub fn wake_of(handle: int) -> Channel<string> {
        match self.live.get(handle) {
            some(found) => { return found.wake }
            none => { return new Channel(1) }
        }
    }

    // ---- the closures the host takes --------------------------------------
    //
    // `latte.web` cannot name `CircuitSet`, so it takes these instead. Each is
    // a closure over `self`, and every parameter and result is a std type.

    pub fn open_fn() -> fn(Map<string, string>, int) -> int {
        return fn(facts: Map<string, string>, now_ms: int) -> int {
            return self.open(facts, now_ms)
        }
    }

    pub fn accept_fn() -> fn(int, string, int) -> List<string> {
        return fn(handle: int, text: string, now_ms: int) -> List<string> {
            return self.accept(handle, text, now_ms)
        }
    }

    pub fn tick_fn() -> fn(int, int) -> List<string> {
        return fn(handle: int, now_ms: int) -> List<string> {
            return self.tick(handle, now_ms)
        }
    }

    pub fn ending_fn() -> fn(int) -> bool {
        return fn(handle: int) -> bool { return self.ending(handle) }
    }

    pub fn disconnect_fn() -> fn(int, int) -> bool {
        return fn(handle: int, now_ms: int) -> bool {
            return self.disconnect(handle, now_ms)
        }
    }

    pub fn resume_fn() -> fn(string, int) -> int {
        return fn(id: string, now_ms: int) -> int { return self.resume(id, now_ms) }
    }

    pub fn wake_fn() -> fn(int) -> Channel<string> {
        return fn(handle: int) -> Channel<string> { return self.wake_of(handle) }
    }

    pub fn outbox_fn() -> fn(int) -> List<string> {
        return fn(handle: int) -> List<string> { return self.outbox(handle) }
    }

    pub fn adopt_fn() -> fn(int, string, int) -> int {
        return fn(handle: int, text: string, now_ms: int) -> int {
            return self.adopt(handle, text, now_ms)
        }
    }
}

fn read_fact(facts: Map<string, string>, name: string) -> string {
    match facts.get(name) { some(value) => { return value } none => { return "" } }
}

/// What the host must print instead of starting a circuit on a platform with
/// no fiber network poller. Windows has none, so `net_fiber_prepare` is a
/// no-op there and a socket read holds the thread instead of parking the
/// fiber: every circuit past the first would wait for the one before it.
/// Static rendering is unaffected and works everywhere.
pub const NO_POLLER_MESSAGE: string =
    "latte: interactive mode needs a fiber network poller, which this platform does not have. Static rendering still works; map_pages without map_circuit."
