// tests/circuit.b — the circuit as a state machine, gated.
//
// PLAN.md gate 7's first half. The second half is a real server on port 0 and
// lives in `tests/circuit_live.b`; this file is everything the circuit MEANS,
// driven by hand with no socket, no clock and no fibers-that-are-not-brewed:
// what a client message does, which batch number goes out, what an ack
// retires, what a disconnect retains, what a limit ends, and where a panic
// lands.
//
// Three rules shape it.
//
//   * **Every section builds its own circuit.** A section must not pass
//     because of something another section left behind.
//   * **Every refusal has a positive control beside it** (RULES.md, "the
//     refusal that never runs"). § 9 walks all nine `bye` kinds, and each one
//     is a pair: the input that ends the circuit, and the neighbouring input
//     that must NOT.
//   * **The numbers are exact.** "A click sends one text edit" is the headline
//     claim of the whole update model, and a circuit that re-sent the page
//     would still show the right button. Only the frame counts and the exact
//     frame text can tell you.
//
// § 6 is the most valuable case here and it is a regression, not a feature:
// `recover()` on a boundary, then a click on a handler that the failed
// boundary had already disposed. The click lands nowhere, so before the fix
// nothing settled, so the recovery never reached the wire and the page stayed
// on its error screen forever. Reverting either half of the fix reproduces it.
package main

import std.io
import std.thread
import {Builder, Circuit, CircuitOptions, CircuitSet, Component, ErrorBoundary,
        MouseEvent, Push, WireLimits, NO_POLLER_MESSAGE,
        nav_target_is_local} from latte
import {run} from latte.boundary

pub class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub fn init() {}

    pub fn eq(name: string, got: string, want: string) {
        self.checks += 1
        if got == want {
            io.println("ok {name}")
        } else {
            self.bad += 1
            io.println("FAIL {name}:")
            io.println("   got  {got}")
            io.println("   want {want}")
        }
    }

    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }
}

// ============================================================== fixtures

/// One button, one handler, one text node. `boom` makes the handler panic, so
/// the same component serves the happy path and the containment path — a
/// second class would let the two drift.
pub class Counter extends Component {
    pub count: int = 0
    pub boom: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) {
            if self.boom { panic("the handler blew up") }
            self.count += 1
        })
        b.text(2, "Count: {self.count}")
        b.close()
    }
}

/// An `ErrorBoundary` around one `Counter`. The boundary is a COMPONENT, so
/// "which boundary catches this handler" is answered by walking the mount tree
/// rather than by a flag someone remembered to set.
pub class Shell extends ErrorBoundary {
    pub inner: Counter = new Counter()
    pub fn init() {
        super.init()
        self.body = fn(b: Builder) {
            b.component_made<Counter>(0, fn() -> Counter { return self.inner },
                                      fn(c: Counter) {})
        }
    }
}

/// The same page with NO boundary anywhere above the handler. The circuit must
/// END here rather than serve a page built from half a handler's work.
pub class Bare extends Component {
    pub inner: Counter = new Counter()
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.component_made<Counter>(0, fn() -> Counter { return self.inner },
                                  fn(c: Counter) {})
    }
}

/// A component that dirties itself from its own render. Without a cap it spins
/// forever inside one event; with one it surfaces in its error boundary.
pub class Spinner extends Component {
    pub runs: int = 0
    pub spin: bool = false
    pub fn init() {}
    pub override fn render(b: Builder) {
        self.runs += 1
        b.open(0, "p")
        b.on_click(1, fn(e: MouseEvent) { self.spin = true })
        b.text(2, "{self.runs}")
        b.close()
        if self.spin { self.notify() }
    }
}

pub class SpinShell extends ErrorBoundary {
    pub inner: Spinner = new Spinner()
    pub fn init() {
        super.init()
        self.body = fn(b: Builder) {
            b.component_made<Spinner>(0, fn() -> Spinner { return self.inner },
                                      fn(c: Spinner) {})
        }
    }
}

/// Two pages behind two urls, so `nav` and `notfound` are about routing rather
/// than about one page that always exists.
pub class Page extends Component {
    pub title: string = ""
    pub fn init(title: string) { self.title = title }
    pub override fn render(b: Builder) {
        b.open(0, "h1")
        b.text(1, self.title)
        b.close()
    }
}

// ============================================================== helpers

const CID: string = "0123456789abcdef0123"

fn options_of() -> CircuitOptions {
    var out: CircuitOptions = new CircuitOptions()
    // Long enough that no section trips it by accident; § 9 sets its own.
    out.idle_ms = 1000000
    return out
}

/// A circuit over one page, with containment installed the way `latte.web`
/// installs it. Every section calls this rather than sharing one circuit.
fn circuit_over(page: Component, options: CircuitOptions) -> Circuit {
    let made: Circuit = new Circuit(CID, options,
        fn(url: string) -> Option<Component> { return some(page) })
    made.guard = run
    return made
}

/// Everything queued for the wire, one frame per line, drained. The host's
/// writer fiber is the only other caller of `take_outbox`, so a section that
/// reads frames also clears them — which is what makes "and nothing else" an
/// assertion rather than a hope.
fn drained(c: Circuit) -> string {
    return c.take_outbox().join("\n")
}

fn frame_count(c: Circuit) -> int { return c.take_outbox().len() }

/// A panic report carries the source position of the panic, which would make
/// this golden change every time a line moved in this file. The trace id and
/// the message are the facts; the position is not.
fn without_position(line: string) -> string {
    match line.find(" at ") {
        some(at) => {
            let head: string = line.slice(0, at)
            let tail: string = line.slice(at + 4, line.len())
            match tail.find(": ") {
                some(colon) => {
                    return "{head} at <pos>: {tail.slice(colon + 2, tail.len())}"
                }
                none => { return line }
            }
        }
        none => { return line }
    }
}

fn log_of(c: Circuit) -> string {
    var out: List<string> = []
    for line: string in c.log { out.push(without_position(line)) }
    return out.join(" | ")
}

fn attach_message(id: string, url: string) -> string {
    return "\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"{url}\"\}"
}

fn click(slot: int) -> string {
    return "\{\"t\":\"ev\",\"h\":{slot},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":1,\"y\":2\}\}"
}

fn ack(batch: int) -> string { return "\{\"t\":\"ack\",\"b\":{batch}\}" }

/// The same two messages carrying a sequence, so § 15 can ask for a fence on
/// exactly the shapes § 2 and § 3 send without one.
fn click_seq(slot: int, sequence: int) -> string {
    return "\{\"t\":\"ev\",\"h\":{slot},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":1,\"y\":2\},\"n\":{sequence}\}"
}

/// The `b` of a batch frame, so a replay can be asserted in order without
/// pinning the whole body twice.
fn batch_number_of(frame: string) -> string {
    let head: string = "\{\"t\":\"batch\",\"b\":"
    if !frame.starts_with(head) { return "not a batch" }
    let rest: string = frame.slice(head.len(), frame.len())
    match rest.find(",") {
        some(comma) => { return rest.slice(0, comma) }
        none => { return "malformed" }
    }
}

fn ack_seq(batch: int, sequence: int) -> string {
    return "\{\"t\":\"ack\",\"b\":{batch},\"n\":{sequence}\}"
}

fn resume(id: string, batch: int) -> string {
    return "\{\"t\":\"resume\",\"c\":\"{id}\",\"a\":{batch}\}"
}

/// A circuit that has said hello and attached, with the wire drained. Every
/// section past § 1 starts here.
fn attached(page: Component, options: CircuitOptions) -> Circuit {
    let c: Circuit = circuit_over(page, options)
    c.open(0)
    c.accept(attach_message(CID, "/"), 1)
    let _: List<string> = c.take_outbox()
    return c
}

fn main() {
    let r: Report = new Report()

    // ========================================================== § 1
    io.println("-- 1. hello, then attach")

    let shell1: Shell = new Shell()
    let c1: Circuit = circuit_over(shell1, options_of())
    r.eqi("1.1 nothing is queued before open", frame_count(c1), 0)
    c1.open(0)
    r.eq("1.2 hello is the first frame, and it goes out before any render",
         drained(c1),
         "\{\"t\":\"hello\",\"v\":1,\"c\":\"{CID}\",\"mx\":65536\}")
    r.no("1.3 nothing has attached yet", c1.is_attached())
    r.eqi("1.4 no batch has been numbered", c1.batch_count(), 0)

    c1.accept(attach_message(CID, "/"), 1)
    r.yes("1.5 attach attaches", c1.is_attached())
    r.eqi("1.6 attach publishes exactly one batch", c1.batch_count(), 1)
    var batch1: List<string> = c1.take_outbox()
    r.eqi("1.7 and exactly one frame goes out", batch1.len(), 1)
    r.eq("1.8 batch 1 is the whole page, built from the reference pool",
         batch1[0],
         "\{\"t\":\"batch\",\"b\":1,\"r\":[[\"b\",0,false],[\"p\",1],[\"c\",0,\"Counter\",1],[\"P\"],[\"B\"],[\"o\",0,\"button\"],[\"h\",1,\"click\",2],[\"t\",2,\"Count: 0\"],[\"z\"]],\"u\":[\{\"c\":0,\"e\":[[\"in\",0,0]]\},\{\"c\":1,\"e\":[[\"in\",0,5]]\}],\"d\":[]\}")
    r.eq("1.9 and the HTML of the same tree", c1.html(),
         "<button>Count: 0</button>")
    r.eqi("1.10 one batch is retained until it is acked", c1.retained(), 1)
    r.eqi("1.11 nothing is acked yet", c1.acked(), 0)

    // ========================================================== § 2
    io.println("")
    io.println("-- 2. one click, one text edit, and nothing else")

    let shell2: Shell = new Shell()
    let c2: Circuit = attached(shell2, options_of())
    c2.accept(click(2), 2)
    r.eqi("2.1 the handler ran", shell2.inner.count, 1)
    var after: List<string> = c2.take_outbox()
    r.eqi("2.2 one frame", after.len(), 1)
    r.eq("2.3 one component, one edit, no reference pool and no disposals",
         after[0],
         "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 1\"],[\"so\"]]\}],\"d\":[]\}")
    r.eqi("2.4 the boundary component did not re-render",
          c2.renderer.render_count(0), 1)
    r.eqi("2.5 the counter rendered exactly twice: the mount and the click",
          c2.renderer.render_count(1), 2)

    // A second click is the same edit with a new body, not a rebuild.
    c2.accept(click(2), 3)
    r.eq("2.6 the second click is the same shape with a new body", drained(c2),
         "\{\"t\":\"batch\",\"b\":3,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 2\"],[\"so\"]]\}],\"d\":[]\}")
    r.eqi("2.7 the count is 2", shell2.inner.count, 2)

    // An input event on a slot bound to a mouse handler dispatches nothing:
    // the registry keeps five tables and a wire name selects the table.
    c2.accept("\{\"t\":\"ev\",\"h\":2,\"k\":\"input\",\"p\":\{\"v\":\"x\"\}\}", 4)
    r.eqi("2.8 a wrong-family event on a real slot sends nothing",
          frame_count(c2), 0)
    r.no("2.9 and it is not an error", c2.ending())
    r.eqi("2.10 nor did it run the handler", shell2.inner.count, 2)

    // ========================================================== § 3
    io.println("")
    io.println("-- 3. a stale slot id is a race, not an error")

    let shell3: Shell = new Shell()
    let c3: Circuit = attached(shell3, options_of())
    c3.accept(click(999), 2)
    r.eqi("3.1 nothing goes out", frame_count(c3), 0)
    r.no("3.2 the circuit lives", c3.ending())
    r.eqi("3.3 the handler did not run", shell3.inner.count, 0)
    r.eq("3.4 it is recorded server-side and nowhere else", log_of(c3),
         "no handler bound to slot 999")
    // The control: the same message with the id that IS bound.
    c3.accept(click(2), 3)
    r.eqi("3.5 the control: a real slot id does run", shell3.inner.count, 1)
    r.eqi("3.6 and does send a batch", frame_count(c3), 1)

    // ========================================================== § 4
    io.println("")
    io.println("-- 4. the inbox: a job posted from another OS thread")

    let shell4: Shell = new Shell()
    let c4: Circuit = attached(shell4, options_of())
    let handle: Push = c4.push_handle()
    let poster: Thread<bool> = thread.spawn(fn() move(handle) -> bool {
        return handle.post(fn(c: Circuit) { c.log.push("pushed") })
    })
    r.yes("4.1 the post was taken", poster.join())
    r.eqi("4.2 the slot is claimed until the job runs", c4.inbox_depth(), 1)
    r.eqi("4.3 the drain runs it", c4.drain(5), 1)
    r.eqi("4.4 and releases the slot", c4.inbox_depth(), 0)
    r.eq("4.5 the job ran on the circuit", log_of(c4), "pushed")
    r.eqi("4.6 a job that dirtied nothing publishes nothing", frame_count(c4), 0)

    // A job that DOES change the page publishes one batch — the control that
    // says the empty batch above was a decision, not a dropped one.
    let bump: Push = c4.push_handle()
    let second: Thread<bool> = thread.spawn(fn() move(bump) -> bool {
        return bump.post(fn(c: Circuit) {})
    })
    let _: bool = second.join()
    shell4.inner.count = 7
    shell4.inner.notify()
    let ran: int = c4.drain(6)
    r.eqi("4.7 the second job ran", ran, 1)
    r.eq("4.8 and what it dirtied went out", drained(c4),
         "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 7\"],[\"so\"]]\}],\"d\":[]\}")

    // The inbox is bounded, and crossing the bound REFUSES rather than parks.
    var tight: CircuitOptions = options_of()
    tight.max_inbox = 2
    let c4b: Circuit = attached(new Shell(), tight)
    let full: Push = c4b.push_handle()
    let filler: Thread<string> = thread.spawn(fn() move(full) -> string {
        var taken: List<string> = []
        var index: int = 0
        for index < 4 {
            taken.push(if full.post(fn(c: Circuit) {}) { "y" } else { "n" })
            index += 1
        }
        return taken.join("")
    })
    r.eq("4.9 two are taken and the rest are refused, never parked",
         filler.join(), "yynn")
    r.eqi("4.10 the drain empties it", c4b.drain(7), 2)
    r.eqi("4.11 and the depth is back to zero", c4b.inbox_depth(), 0)

    // ========================================================== § 5
    io.println("")
    io.println("-- 5. a handler that panics, with a boundary above it")

    let shell5: Shell = new Shell()
    let c5: Circuit = attached(shell5, options_of())
    shell5.inner.boom = true
    c5.accept(click(2), 2)
    var caught: List<string> = c5.take_outbox()
    r.eqi("5.1 two frames: the report, then the fallback", caught.len(), 2)
    r.eq("5.2 the client is told a trace id and never the message", caught[0],
         "\{\"t\":\"err\",\"k\":\"panic\",\"m\":\"t1\"\}")
    r.eq("5.3 the nearest boundary renders its fallback, and the counter is disposed",
         caught[1],
         "\{\"t\":\"batch\",\"b\":2,\"r\":[[\"b\",0,true],[\"o\",0,\"div\"],[\"a\",1,\"class\",\"latte-error\"],[\"t\",2,\"Something went wrong.\"],[\"z\"],[\"B\"]],\"u\":[\{\"c\":0,\"e\":[[\"rm\",0],[\"in\",0,0]]\}],\"d\":[1]\}")
    r.no("5.4 the circuit LIVES", c5.ending())
    r.eq("5.5 the message stayed server-side, with its trace id", log_of(c5),
         "t1: runtime panic at <pos>: the handler blew up")
    r.eq("5.6 the boundary knows which failure it is showing", shell5.failure, "t1")
    r.eq("5.7 the page is the fallback", c5.html(),
         "<div class=\"latte-error\">Something went wrong.</div>")

    // The control: a handler that does NOT panic, on the same circuit shape.
    let shell5b: Shell = new Shell()
    let c5b: Circuit = attached(shell5b, options_of())
    c5b.accept(click(2), 2)
    r.eqi("5.8 the control: no err frame at all", c5b.take_outbox().len(), 1)
    r.eq("5.9 and no trace was issued", log_of(c5b), "")

    io.println("")
    io.println("-- 5b. the same panic with NO boundary anywhere above it")

    let bare: Bare = new Bare()
    let c5c: Circuit = attached(bare, options_of())
    bare.inner.boom = true
    c5c.accept(click(2), 2)
    r.eq("5.10 the circuit ENDS, because half a handler ran", drained(c5c),
         "\{\"t\":\"bye\",\"k\":\"panic\",\"m\":\"t1\"\}")
    r.yes("5.11 ended", c5c.ending())
    r.eq("5.12 with the panic kind", c5c.end_reason(), "panic")
    r.eq("5.13 and the message is still only server-side", log_of(c5c),
         "t1: runtime panic at <pos>: the handler blew up")
    // The control: the same page, the same click, no panic.
    let bare2: Bare = new Bare()
    let c5d: Circuit = attached(bare2, options_of())
    c5d.accept(click(2), 2)
    r.no("5.14 the control: a page with no boundary is fine until one panics",
         c5d.ending())

    // ========================================================== § 6
    io.println("")
    io.println("-- 6. recover(), then a click on a slot the failure disposed")
    //
    // THE REGRESSION. A `notify()` raised outside the event path — a Callback,
    // a timer, or a boundary's own `recover()` — is tied to no message. Before
    // the fix, `accept` settled only on the paths that had dispatched, and
    // `tick` settled only when a job had run. So: recover() marks the boundary
    // dirty; the client's next click carries a handler id the failed boundary
    // had already disposed; the click lands nowhere; nothing settles; the
    // recovery never reaches the wire and the page stays on its error screen.
    //
    // Deleting either half of the fix — the `if !self.ended { self.settle() }`
    // at the end of `Circuit.accept`, or the `renderer.pending() > 0` arm of
    // `Circuit.tick` — brings it back. § 6.4 and § 6.9 are the two halves.

    let shell6: Shell = new Shell()
    let c6: Circuit = attached(shell6, options_of())
    shell6.inner.boom = true
    c6.accept(click(2), 2)
    let _: List<string> = c6.take_outbox()
    r.eq("6.1 the page is on its error screen", c6.html(),
         "<div class=\"latte-error\">Something went wrong.</div>")

    shell6.inner.boom = false
    shell6.recover()
    r.eqi("6.2 recover() dirties the boundary and nothing has flushed yet",
          c6.renderer.pending(), 1)
    r.eqi("6.3 and nothing is queued for the wire", frame_count(c6), 0)

    // The stale click: slot 2 belonged to the Counter the failure disposed.
    c6.accept(click(2), 3)
    var recovered: List<string> = c6.take_outbox()
    r.eqi("6.4 the recovery reaches the wire on a message that dispatched NOTHING",
          recovered.len(), 1)
    r.eq("6.5 and it re-mounts the body", recovered[0],
         "\{\"t\":\"batch\",\"b\":3,\"r\":[[\"b\",0,false],[\"p\",1],[\"c\",0,\"Counter\",3],[\"P\"],[\"B\"],[\"o\",0,\"button\"],[\"h\",1,\"click\",4],[\"t\",2,\"Count: 0\"],[\"z\"]],\"u\":[\{\"c\":0,\"e\":[[\"rm\",0],[\"in\",0,0]]\},\{\"c\":3,\"e\":[[\"in\",0,5]]\}],\"d\":[]\}")
    r.eq("6.6 the page is the counter again", c6.html(),
         "<button>Count: 0</button>")
    // Slot ids are never reused. The client's old id 2 is dead for good, and
    // the new handler is id 4 under component 3 — which is why `latte.js` must
    // not cache a handler id across a batch that disposed its component.
    c6.accept(click(2), 4)
    r.eqi("6.7 the OLD id is dead for good", frame_count(c6), 0)
    c6.accept(click(4), 5)
    r.eqi("6.8 the NEW id works", shell6.inner.count, 1)

    // The other half: a notify with no message at all reaches the wire on the
    // next tick.
    let shell6b: Shell = new Shell()
    let c6b: Circuit = attached(shell6b, options_of())
    shell6b.inner.count = 5
    shell6b.inner.notify()
    r.eqi("6.9 a tick with no job to run still settles what is pending",
          if c6b.tick(9) { 1 } else { 0 }, 1)
    r.eq("6.10 and the batch went out", drained(c6b),
         "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 5\"],[\"so\"]]\}],\"d\":[]\}")
    r.no("6.11 a tick with nothing pending does nothing", c6b.tick(10))
    r.eqi("6.12 and sends nothing", frame_count(c6b), 0)

    // ========================================================== § 7
    io.println("")
    io.println("-- 7. the render-pass cap")

    var capped: CircuitOptions = options_of()
    capped.max_renders = 4
    let spin: SpinShell = new SpinShell()
    let c7: Circuit = attached(spin, capped)
    r.eqi("7.1 the mount rendered it once", spin.inner.runs, 1)
    c7.accept(click(2), 2)
    var spun: List<string> = c7.take_outbox()
    r.eqi("7.2 it re-rendered itself exactly max_renders times", spin.inner.runs, 5)
    r.eqi("7.3 the report and the fallback", spun.len(), 2)
    r.eq("7.4 reported as a contained failure, not a hung worker", spun[0],
         "\{\"t\":\"err\",\"k\":\"panic\",\"m\":\"t1\"\}")
    r.eq("7.5 and the sentence names what actually happened", log_of(c7),
         "t1: a component re-rendered itself 4 times without settling")
    r.no("7.6 the circuit lives", c7.ending())
    r.eq("7.7 the boundary shows the fallback", c7.html(),
         "<div class=\"latte-error\">Something went wrong.</div>")
    // The control: the same component, one pass, no spin.
    let calm: SpinShell = new SpinShell()
    let c7b: Circuit = attached(calm, capped)
    calm.inner.notify()
    let _: bool = c7b.tick(3)
    r.eqi("7.8 the control: one notify is one render", calm.inner.runs, 2)
    r.no("7.9 and nothing was contained", c7b.ending())
    r.eq("7.10 no trace was issued", log_of(c7b), "")

    // ========================================================== § 8
    io.println("")
    io.println("-- 8. acks, retention, disconnect and replay")

    let shell8: Shell = new Shell()
    let c8: Circuit = attached(shell8, options_of())
    c8.accept(click(2), 2)
    c8.accept(click(2), 3)
    let _: List<string> = c8.take_outbox()
    r.eqi("8.1 three batches have been numbered", c8.batch_count(), 3)
    r.eqi("8.2 all three are retained", c8.retained(), 3)
    c8.accept(ack(1), 4)
    r.eqi("8.3 an ack retires everything at or below it", c8.retained(), 2)
    r.eqi("8.4 and moves the acked mark", c8.acked(), 1)
    c8.accept(ack(1), 5)
    r.eqi("8.5 a repeated ack is not an error and changes nothing", c8.retained(), 2)
    r.no("8.6 the circuit lives", c8.ending())
    c8.accept(ack(0), 6)
    r.eqi("8.7 an older ack carries no information and is ignored", c8.acked(), 1)
    r.no("8.8 and is not fatal", c8.ending())

    c8.disconnected(10)
    r.no("8.9 the socket is gone", c8.is_connected())
    r.eqi("8.10 anything queued for a socket that is gone is dropped",
          frame_count(c8), 0)
    r.no("8.11 inside the retention window it has not expired", c8.expired(11))
    r.yes("8.12 past it, it has", c8.expired(10 + 30000))
    r.no("8.13 the exact boundary is one millisecond short",
         c8.expired(10 + 29999))

    c8.accept(resume(CID, 1), 12)
    var replayed: List<string> = c8.take_outbox()
    r.eqi("8.14 resume replays every un-acked batch", replayed.len(), 2)
    r.yes("8.15 and the connection is up again", c8.is_connected())
    r.eq("8.16 the replayed frames are the ones that were sent, byte for byte",
         replayed.join("\n"),
         "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 1\"],[\"so\"]]\}],\"d\":[]\}\n\{\"t\":\"batch\",\"b\":3,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 2\"],[\"so\"]]\}],\"d\":[]\}")
    // A resume that carries a HIGHER ack retires as it replays.
    c8.disconnected(13)
    c8.accept(resume(CID, 3), 14)
    r.eqi("8.17 a resume that acks more replays less", frame_count(c8), 0)
    r.eqi("8.18 and retains nothing", c8.retained(), 0)

    // ========================================================== § 9
    io.println("")
    io.println("-- 9. every way a circuit ends, each with a control")
    //
    // `stop` is the ONLY way a circuit ends: no path panics, and every limit
    // routes through it. Nine kinds, nine pairs.

    // protocol — a message that is not one.
    let c9a: Circuit = attached(new Shell(), options_of())
    c9a.accept("not json", 2)
    r.eq("9.1 protocol", drained(c9a),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"expected null\"\}")
    let c9b: Circuit = attached(new Shell(), options_of())
    c9b.accept(ack(1), 2)
    r.no("9.2 the control: a well-formed message does not end it", c9b.ending())

    // protocol — a well-formed message before attach.
    let c9c: Circuit = circuit_over(new Shell(), options_of())
    c9c.open(0)
    let _: List<string> = c9c.take_outbox()
    c9c.accept(ack(0), 1)
    r.eq("9.3 protocol: anything but attach or resume, before attach",
         drained(c9c),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"a ack arrived before attach\"\}")
    let c9d: Circuit = circuit_over(new Shell(), options_of())
    c9d.open(0)
    c9d.accept(attach_message(CID, "/"), 1)
    r.no("9.4 the control: attach is what may arrive first", c9d.ending())

    // protocol — attach twice.
    let c9e: Circuit = attached(new Shell(), options_of())
    c9e.accept(attach_message(CID, "/"), 2)
    r.eq("9.5 protocol: attach twice", drained(c9e),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"attach arrived twice on one circuit\"\}")

    // protocol — an ack for a batch that was never sent.
    let c9f: Circuit = attached(new Shell(), options_of())
    c9f.accept(ack(9), 2)
    r.eq("9.6 protocol: an ack from the future", drained(c9f),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"an ack for a batch that was never sent\"\}")
    let c9g: Circuit = attached(new Shell(), options_of())
    c9g.accept(ack(1), 2)
    r.no("9.7 the control: an ack for the batch that WAS sent", c9g.ending())

    // forbidden — the circuit id must be the one this connection was opened with.
    let c9h: Circuit = circuit_over(new Shell(), options_of())
    c9h.open(0)
    let _: List<string> = c9h.take_outbox()
    c9h.accept(attach_message("aaaaaaaaaaaaaaaaaaaa", "/"), 1)
    r.eq("9.8 forbidden: a circuit id that is not this one", drained(c9h),
         "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"the circuit id does not match this connection\"\}")

    // forbidden — a navigation target that is not same-origin and path-only.
    let c9i: Circuit = attached(new Shell(), options_of())
    c9i.accept("\{\"t\":\"nav\",\"u\":\"//evil.example/x\"\}", 2)
    r.eq("9.9 forbidden: a scheme-relative nav target", drained(c9i),
         "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"a navigation target must be same-origin and path-only\"\}")

    // notfound — no page answers the url.
    let c9j: Circuit = new Circuit(CID, options_of(),
        fn(url: string) -> Option<Component> {
            if url == "/known" { return some(new Page("known")) }
            return none
        })
    c9j.guard = run
    c9j.open(0)
    let _: List<string> = c9j.take_outbox()
    c9j.accept(attach_message(CID, "/missing"), 1)
    r.eq("9.10 notfound", drained(c9j),
         "\{\"t\":\"bye\",\"k\":\"notfound\",\"m\":\"no page answers that url\"\}")
    let c9k: Circuit = new Circuit(CID, options_of(),
        fn(url: string) -> Option<Component> {
            if url == "/known" { return some(new Page("known")) }
            return none
        })
    c9k.guard = run
    c9k.open(0)
    let _: List<string> = c9k.take_outbox()
    c9k.accept(attach_message(CID, "/known"), 1)
    r.no("9.11 the control: a url that IS answered", c9k.ending())
    r.eq("9.12 and it rendered", c9k.html(), "<h1>known</h1>")

    // stale — a resume from further back than the retained batches.
    let c9l: Circuit = attached(new Shell(), options_of())
    c9l.accept(click(2), 2)
    c9l.accept(ack(2), 3)
    let _: List<string> = c9l.take_outbox()
    c9l.disconnected(4)
    c9l.accept(resume(CID, 1), 5)
    r.eq("9.13 stale: the client is behind what this end still holds",
         drained(c9l),
         "\{\"t\":\"bye\",\"k\":\"stale\",\"m\":\"the client is behind the retained batches\"\}")
    let c9m: Circuit = attached(new Shell(), options_of())
    c9m.accept(click(2), 2)
    c9m.accept(ack(2), 3)
    let _: List<string> = c9m.take_outbox()
    c9m.disconnected(4)
    c9m.accept(resume(CID, 2), 5)
    r.no("9.14 the control: a resume exactly at the acked mark", c9m.ending())

    // limit — too many batches out with no ack.
    var window: CircuitOptions = options_of()
    window.max_unacked = 2
    let c9n: Circuit = attached(new Shell(), window)
    c9n.accept(click(2), 2)
    let _: List<string> = c9n.take_outbox()
    r.no("9.15 the control: two batches out is inside the window", c9n.ending())
    c9n.accept(click(2), 3)
    r.eq("9.16 limit: the third crosses it", c9n.take_outbox().join("\n").split("\n")[1],
         "\{\"t\":\"bye\",\"k\":\"limit\",\"m\":\"3 batches went out un-acked, over the 2 window\"\}")

    // limit — a range asking for more rows than the window allows.
    var window2: CircuitOptions = options_of()
    window2.max_window = 5
    let c9o: Circuit = attached(new Shell(), window2)
    c9o.accept("\{\"t\":\"range\",\"h\":1,\"s\":0,\"c\":5\}", 2)
    r.no("9.17 the control: a range exactly at the cap", c9o.ending())
    c9o.accept("\{\"t\":\"range\",\"h\":1,\"s\":0,\"c\":6\}", 3)
    r.eq("9.18 limit: one row over", drained(c9o),
         "\{\"t\":\"bye\",\"k\":\"limit\",\"m\":\"a range asked for 6 rows, over the 5 cap\"\}")

    // idle — no message for idle_ms.
    var brief: CircuitOptions = options_of()
    brief.idle_ms = 100
    let c9p: Circuit = attached(new Shell(), brief)
    r.no("9.19 the control: one millisecond short of the timeout",
         c9p.tick(100))
    r.no("9.20 and it is still alive", c9p.ending())
    let _: bool = c9p.tick(101)
    r.eq("9.21 idle", drained(c9p),
         "\{\"t\":\"bye\",\"k\":\"idle\",\"m\":\"no message for 100 ms\"\}")

    // gone — a message for a circuit the set no longer holds.
    var set9: CircuitSet = new CircuitSet(options_of(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var facts9: Map<string, string> = {}
    facts9["id"] = CID
    let h9: int = set9.open(facts9, 0)
    let _: List<string> = set9.accept(h9, attach_message(CID, "/"), 1)
    r.eq("9.22 the control: a handle the set holds",
         set9.accept(h9, ack(0), 2).join(""), "")
    r.eq("9.23 gone: a handle it does not", set9.accept(h9 + 99, ack(0), 1).join(""),
         "\{\"t\":\"bye\",\"k\":\"gone\",\"m\":\"this circuit is no longer open\"\}")

    // stop is idempotent, and it is the only way out.
    let c9q: Circuit = attached(new Shell(), options_of())
    c9q.stop("protocol", "first")
    c9q.stop("limit", "second")
    r.eq("9.24 the first stop wins and the second writes nothing", drained(c9q),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"first\"\}")
    r.eq("9.25 and the kind is the first one", c9q.end_reason(), "protocol")
    c9q.accept(click(2), 3)
    r.eqi("9.26 an ended circuit ignores everything after", frame_count(c9q), 0)

    // ========================================================== § 10
    io.println("")
    io.println("-- 10. navigation, in both directions")

    // The rule, exhaustively. This is the one string a client sends that this
    // end turns into a request, so it is the one place an open redirect or an
    // SSRF could start.
    r.yes("10.1 a plain path", nav_target_is_local("/x"))
    r.yes("10.2 the root", nav_target_is_local("/"))
    r.yes("10.3 a path with a query", nav_target_is_local("/x?a=1"))
    r.yes("10.4 a path with a fragment", nav_target_is_local("/x#y"))
    r.yes("10.5 dots that are not a segment", nav_target_is_local("/a..b/c"))
    r.yes("10.6 a single dot segment", nav_target_is_local("/a/./b"))
    r.yes("10.7 .. inside the query, which is not the path",
          nav_target_is_local("/a?b=../c"))
    r.no("10.8 the empty string", nav_target_is_local(""))
    r.no("10.9 a relative path", nav_target_is_local("x"))
    r.no("10.10 an absolute url", nav_target_is_local("https://evil.example/"))
    r.no("10.11 scheme-relative, which a browser reads as another origin",
         nav_target_is_local("//evil.example/x"))
    r.no("10.12 a backslash, which several browsers normalise to a slash",
         nav_target_is_local("/a\\evil.example"))
    r.no("10.13 a newline", nav_target_is_local("/a\nb"))
    r.no("10.14 a nul", nav_target_is_local("/a\u{0}b"))
    r.no("10.15 DEL", nav_target_is_local("/a\u{7f}b"))
    r.no("10.16 a .. segment", nav_target_is_local("/a/../b"))
    r.no("10.17 a .. segment before the query", nav_target_is_local("/a/..?x=1"))
    r.no("10.18 a javascript: url", nav_target_is_local("javascript:alert(1)"))

    // Client-driven nav re-mounts the page for the new url.
    let c10: Circuit = new Circuit(CID, options_of(),
        fn(url: string) -> Option<Component> {
            if url == "/a" { return some(new Page("A")) }
            if url == "/b" { return some(new Page("B")) }
            return none
        })
    c10.guard = run
    c10.open(0)
    c10.accept(attach_message(CID, "/a"), 1)
    let _: List<string> = c10.take_outbox()
    r.eq("10.19 the first page", c10.html(), "<h1>A</h1>")
    c10.accept("\{\"t\":\"nav\",\"u\":\"/b\"\}", 2)
    r.eq("10.20 nav re-mounts and publishes the new page", drained(c10),
         "\{\"t\":\"batch\",\"b\":2,\"r\":[[\"o\",0,\"h1\"],[\"t\",1,\"B\"],[\"z\"]],\"u\":[\{\"c\":0,\"e\":[[\"in\",0,0]]\}],\"d\":[]\}")
    r.eq("10.21 and the page changed", c10.html(), "<h1>B</h1>")
    c10.accept("\{\"t\":\"nav\",\"u\":\"/nowhere\"\}", 3)
    r.eq("10.22 a nav to a url nothing answers ends the circuit", drained(c10),
         "\{\"t\":\"bye\",\"k\":\"notfound\",\"m\":\"no page answers that url\"\}")

    // Server-driven nav is refused by the same rule, and refuses without
    // ending the circuit — it is the server's own mistake, not the client's.
    let c10b: Circuit = attached(new Shell(), options_of())
    r.no("10.23 the server cannot navigate off-origin either",
         c10b.navigate("https://evil.example/"))
    r.eqi("10.24 and nothing was written", frame_count(c10b), 0)
    r.no("10.25 nor did it end the circuit", c10b.ending())
    r.yes("10.26 the control: a local target is written", c10b.navigate("/x"))
    r.eq("10.27 as a nav frame", drained(c10b), "\{\"t\":\"nav\",\"u\":\"/x\"\}")

    // ========================================================== § 11
    io.println("")
    io.println("-- 11. JS interop: a call out, and a result back")

    let shell11: Shell = new Shell()
    let c11: Circuit = attached(shell11, options_of())
    var seen: List<string> = []
    var args: List<string> = []
    args.push("#app")
    let call: int = c11.js_call("focus", args,
        fn(ok: bool, value: string) { seen.push("ok={ok} v={value}") })
    r.eqi("11.1 the first call id is 1", call, 1)
    r.eq("11.2 the call goes out naming a registered function, never a string to eval",
         drained(c11), "\{\"t\":\"js\",\"i\":1,\"f\":\"focus\",\"a\":[\"#app\"]\}")
    r.eqi("11.3 it is outstanding", c11.outstanding_calls(), 1)
    c11.accept("\{\"t\":\"js\",\"i\":1,\"ok\":true,\"v\":\"done\"\}", 2)
    r.eq("11.4 the continuation ran on the circuit fiber", seen.join(","),
         "ok=true v=done")
    r.eqi("11.5 and the call is retired", c11.outstanding_calls(), 0)
    r.eqi("11.6 a continuation that changed nothing publishes nothing",
          frame_count(c11), 0)

    // A result for a call this end never made is logged, not fatal.
    c11.accept("\{\"t\":\"js\",\"i\":77,\"ok\":true,\"v\":\"x\"\}", 3)
    r.no("11.7 a result for a call nobody made is not fatal", c11.ending())
    r.eq("11.8 and it is recorded", log_of(c11),
         "a js result arrived for call 77, which is not outstanding")
    // The same id twice: the second is no longer outstanding.
    c11.accept("\{\"t\":\"js\",\"i\":1,\"ok\":true,\"v\":\"again\"\}", 4)
    r.eq("11.9 a duplicate result does not run the continuation twice",
         seen.join(","), "ok=true v=done")

    // A continuation that dirties the page publishes a batch.
    let c11b: Circuit = attached(shell11, options_of())
    var noargs: List<string> = []
    let call2: int = c11b.js_call("read", noargs,
        fn(ok: bool, value: string) {
            shell11.inner.count = 9
            shell11.inner.notify()
        })
    let _: List<string> = c11b.take_outbox()
    c11b.accept("\{\"t\":\"js\",\"i\":1,\"ok\":true,\"v\":\"9\"\}", 2)
    r.eq("11.10 a continuation that dirties the page publishes", drained(c11b),
         "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 9\"],[\"so\"]]\}],\"d\":[]\}")

    // A continuation that panics is contained exactly like a handler.
    let shell11c: Shell = new Shell()
    let c11c: Circuit = attached(shell11c, options_of())
    let call3: int = c11c.js_call("boom", noargs,
        fn(ok: bool, value: string) { panic("the continuation blew up") })
    let _: List<string> = c11c.take_outbox()
    c11c.accept("\{\"t\":\"js\",\"i\":1,\"ok\":true,\"v\":\"\"\}", 2)
    r.eq("11.11 a panicking continuation is contained too",
         c11c.take_outbox()[0], "\{\"t\":\"err\",\"k\":\"panic\",\"m\":\"t1\"\}")
    r.no("11.12 and the circuit lives", c11c.ending())

    // ========================================================== § 12
    io.println("")
    io.println("-- 12. the set: opening, evicting, resuming, sweeping")

    var made: List<string> = []
    var set: CircuitSet = new CircuitSet(options_of(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            match facts.get("id") {
                some(id) => { made.push("{id}@{url}") }
                none => { made.push("?@{url}") }
            }
            return some(new Shell())
        })

    var facts: Map<string, string> = {}
    facts["id"] = "aaaaaaaaaaaaaaaa"
    let ha: int = set.open(facts, 0)
    r.eqi("12.1 the first handle", ha, 1)
    r.eqi("12.2 one circuit", set.count(), 1)
    r.eqi("12.3 and it can be found by id", set.handle_for("aaaaaaaaaaaaaaaa"), 1)
    r.eqi("12.4 an id nobody opened", set.handle_for("zzzz"), -1)

    // open() greets: the hello is queued and waiting for the writer fiber.
    match set.circuit(ha) {
        some(found) => {
            r.eq("12.5 open() said hello", drained(found),
                 "\{\"t\":\"hello\",\"v\":1,\"c\":\"aaaaaaaaaaaaaaaa\",\"mx\":65536\}")
        }
        none => { r.eq("12.5 open() said hello", "missing", "a circuit") }
    }

    // The three ways open() refuses.
    var shortid: Map<string, string> = {}
    shortid["id"] = "short"
    r.eqi("12.6 an id under 16 characters is refused", set.open(shortid, 0), -1)
    var noid: Map<string, string> = {}
    r.eqi("12.7 no id at all is refused", set.open(noid, 0), -1)
    r.eqi("12.8 the same id twice is refused", set.open(facts, 0), -1)
    r.eq("12.9 and each says why", set.faults.join(" | "),
         "a circuit id must be at least 16 characters | a circuit id must be at least 16 characters | a circuit with that id is already open")

    // The page factory is called with the handshake facts already bound, so a
    // Circuit never sees a Map off the wire.
    match set.circuit(ha) {
        some(found) => { found.accept(attach_message("aaaaaaaaaaaaaaaa", "/x"), 1) }
        none => {}
    }
    r.eq("12.10 the factory saw this connection's facts and the url",
         made.join(","), "aaaaaaaaaaaaaaaa@/x")

    // A full set evicts the oldest DISCONNECTED circuit, and refuses rather
    // than killing a live tab.
    var two: CircuitOptions = options_of()
    two.max_circuits = 2
    var small: CircuitSet = new CircuitSet(two,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var f1: Map<string, string> = {}
    f1["id"] = "1111111111111111"
    var f2: Map<string, string> = {}
    f2["id"] = "2222222222222222"
    var f3: Map<string, string> = {}
    f3["id"] = "3333333333333333"
    let h1: int = small.open(f1, 0)
    let h2: int = small.open(f2, 0)
    r.eqi("12.11 two circuits fill it", small.count(), 2)
    r.eqi("12.12 a third is refused while both are live", small.open(f3, 0), -1)
    r.eq("12.13 and it says so", small.faults.join(""),
         "this worker already holds 2 live circuits")
    r.yes("12.14 disconnecting one retains it", small.disconnect(h1, 10))
    let h3: int = small.open(f3, 11)
    r.yes("12.15 now the third opens", h3 > 0)
    r.eqi("12.16 still two", small.count(), 2)
    r.eqi("12.17 and the evicted one is gone", small.handle_for("1111111111111111"), -1)

    // resume finds a retained circuit and refuses an expired one.
    r.yes("12.18 disconnect the second", small.disconnect(h2, 12))
    r.eqi("12.19 resume finds it inside the window", small.resume("2222222222222222", 13), h2)
    r.eqi("12.20 and not past it", small.resume("2222222222222222", 12 + 30000), -1)
    r.eqi("12.21 which also forgot it", small.count(), 1)
    r.eqi("12.22 resume on an id nobody opened", small.resume("nope", 1), -1)

    // The sweep drops everything whose retention window has passed.
    var sweeper: CircuitSet = new CircuitSet(options_of(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var s1: Map<string, string> = {}
    s1["id"] = "aaaa111111111111"
    var s2: Map<string, string> = {}
    s2["id"] = "bbbb222222222222"
    let g1: int = sweeper.open(s1, 0)
    let g2: int = sweeper.open(s2, 0)
    let _: bool = sweeper.disconnect(g1, 0)
    r.eqi("12.23 a sweep inside the window drops nothing", sweeper.sweep(100), 0)
    r.eqi("12.24 past it, it drops the disconnected one", sweeper.sweep(30000), 1)
    r.eqi("12.25 and leaves the live one", sweeper.count(), 1)

    // An ended circuit is forgotten on disconnect rather than retained: there
    // is nothing to come back to.
    var ender: CircuitSet = new CircuitSet(options_of(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    var e1: Map<string, string> = {}
    e1["id"] = "cccc333333333333"
    let ge: int = ender.open(e1, 0)
    let _: List<string> = ender.accept(ge, "not json", 1)
    r.yes("12.26 the circuit ended", ender.ending(ge))
    r.no("12.27 disconnecting an ended circuit retains nothing",
         ender.disconnect(ge, 2))
    r.eqi("12.28 it is forgotten", ender.count(), 0)
    r.yes("12.29 and an unknown handle reads as ended", ender.ending(999))

    // ========================================================== § 13
    io.println("")
    io.println("-- 13. the seam: std types only, because latte.web cannot name a Circuit")

    var seam: CircuitSet = new CircuitSet(options_of(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Shell())
        })
    let open_fn: fn(Map<string, string>, int) -> int = seam.open_fn()
    let accept_fn: fn(int, string, int) -> List<string> = seam.accept_fn()
    let tick_fn: fn(int, int) -> List<string> = seam.tick_fn()
    let ending_fn: fn(int) -> bool = seam.ending_fn()
    let disconnect_fn: fn(int, int) -> bool = seam.disconnect_fn()
    let resume_fn: fn(string, int) -> int = seam.resume_fn()
    let wake_fn: fn(int) -> Channel<string> = seam.wake_fn()

    var sf: Map<string, string> = {}
    sf["id"] = CID
    let hs: int = open_fn(sf, 0)
    r.eqi("13.1 open through the closure", hs, 1)
    // Two frames: the hello `open` queued, and the batch attach published.
    // The closure is the only way `latte.web` ever sees either of them.
    r.eqi("13.2 attach through the closure comes back as a list of strings",
          accept_fn(hs, attach_message(CID, "/"), 1).len(), 2)
    r.no("13.3 ending through the closure", ending_fn(hs))
    r.eqi("13.4 a tick with nothing to do returns nothing",
          tick_fn(hs, 2).len(), 0)
    let wake: Channel<string> = wake_fn(hs)
    r.yes("13.5 the wake channel takes a marker without parking",
          wake.try_send("p"))
    match wake.try_receive() {
        some(marker) => { r.eq("13.6 and hands it back", marker, "p") }
        none => { r.eq("13.6 and hands it back", "nothing", "p") }
    }
    r.yes("13.7 disconnect through the closure", disconnect_fn(hs, 3))
    r.eqi("13.8 resume through the closure", resume_fn(CID, 4), hs)
    // An unknown handle answers a real one-slot channel rather than crashing:
    // the host's ticker may hold a handle whose circuit has just been swept.
    let orphan: Channel<string> = wake_fn(999)
    r.yes("13.9 an unknown handle's wake channel is a real channel",
          orphan.try_send("t"))
    r.no("13.10 with exactly one slot", orphan.try_send("t"))

    // ========================================================== § 14
    io.println("")
    io.println("-- 14. what Windows is owed")

    r.eq("14.1 the refusal names the program, not the emitter",
         NO_POLLER_MESSAGE,
         "latte: interactive mode needs a fiber network poller, which this platform does not have. Static rendering still works; map_pages without map_circuit.")

    // ========================================================== § 15
    //
    // The `seen` fence — BLOCKERS.md B11.
    //
    // § 3 is the hole itself: an inert click produces NOTHING, which over a
    // socket is indistinguishable from a server that has died. This section is
    // the answer, and every row here is about ORDER and COUNT, because a fence
    // that arrives instead of a batch, or twice, or after a `bye`, is a
    // different protocol from the one `js/latte.js` is written against.
    io.println("")
    io.println("-- 15. the seen fence: every accepted message is answered")

    let shell15: Shell = new Shell()
    let c15: Circuit = attached(shell15, options_of())

    // 15.1 is § 3.1 with a sequence on it. Same message, same nothing-happened,
    // and now a frame says so.
    c15.accept(click_seq(999, 7), 2)
    r.eq("15.1 an inert click is answered", drained(c15),
         "\{\"t\":\"seen\",\"n\":7\}")
    r.no("15.2 and the circuit lives", c15.ending())
    r.eqi("15.3 the handler still did not run", shell15.inner.count, 0)

    // The control, and it is the one that matters: the fence is sent AFTER
    // whatever else the message produced, not instead of it. A client whose
    // rule is "clear the deadline on seen" must never see a batch swallowed.
    c15.accept(click_seq(2, 8), 3)
    r.eq("15.4 a live click sends the batch FIRST, then the fence",
         drained(c15),
         // The batch is § 2.3's, byte for byte — this row is not re-deciding
         // the edit stream, it is asserting that the fence did not displace
         // it. `si 0` is a CHILD index and not the `b.text` frame's seq 2; my
         // first want said 2 and the server was right.
         "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 1\"],[\"so\"]]\}],\"d\":[]\}\n\{\"t\":\"seen\",\"n\":8\}")

    // A message with no sequence asks for no fence, and gets none. This is a
    // decision, not an oversight: `ack` is the message a client sends without
    // ever waiting for an answer, and fencing it would put a server frame on
    // the wire for every batch the client acknowledges, forever.
    c15.accept(click(2), 4)
    r.eqi("15.5 no sequence, no fence — only the batch", frame_count(c15), 1)
    c15.accept(ack(2), 5)
    r.eqi("15.6 an ack with no sequence is answered by nothing",
          frame_count(c15), 0)
    c15.accept(ack_seq(3, 9), 6)
    r.eq("15.7 an ack WITH a sequence is answered", drained(c15),
         "\{\"t\":\"seen\",\"n\":9\}")

    // The sequence is echoed, not counted. The server never invents one, so a
    // client may number its messages however it likes and still match them.
    c15.accept(click_seq(999, 4611686018427387904), 7)
    r.eq("15.8 the sequence is echoed exactly, whatever it is", drained(c15),
         "\{\"t\":\"seen\",\"n\":4611686018427387904\}")

    // Attach is fenced too, and its batch comes first for the same reason.
    let shell15b: Shell = new Shell()
    let c15b: Circuit = circuit_over(shell15b, options_of())
    c15b.open(0)
    let _hello15: List<string> = c15b.take_outbox()
    c15b.accept("\{\"t\":\"attach\",\"c\":\"{CID}\",\"u\":\"/\",\"n\":1\}", 1)
    let attach15: List<string> = c15b.take_outbox()
    r.eqi("15.9 attach answers with two frames", attach15.len(), 2)
    r.eq("15.10 the second is the fence", attach15[attach15.len() - 1],
         "\{\"t\":\"seen\",\"n\":1\}")

    // A `bye` is the LAST frame on a circuit. A fence after it would be a
    // frame after the last frame, so the fence is not sent when the message
    // ended the circuit — `latte.js` clears every outstanding deadline on a
    // `bye` instead.
    let shell15c: Shell = new Shell()
    let c15c: Circuit = attached(shell15c, options_of())
    c15c.accept("\{\"t\":\"nav\",\"u\":\"https://elsewhere.example/x\",\"n\":3\}", 2)
    r.eq("15.11 a message that ends the circuit is answered by the bye alone",
         drained(c15c),
         "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"a navigation target must be same-origin and path-only\"\}")

    // A refused message ends the circuit before the sequence is ever used, so
    // the same rule covers a protocol fault.
    let c15d: Circuit = attached(new Shell(), options_of())
    c15d.accept("\{\"t\":\"whatever\",\"n\":5\}", 2)
    r.eq("15.12 a refused message is answered by the bye alone", drained(c15d),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"unknown message kind\"\}")

    // A contained panic: the circuit SURVIVES, so the message is still
    // answered — err, then the boundary's batch, then the fence.
    let shell15e: Shell = new Shell()
    let c15e: Circuit = attached(shell15e, options_of())
    shell15e.inner.boom = true
    c15e.accept(click_seq(2, 11), 2)
    let after15e: List<string> = c15e.take_outbox()
    r.eqi("15.13 a contained panic answers with three frames", after15e.len(), 3)
    r.eq("15.14 err first", after15e[0], "\{\"t\":\"err\",\"k\":\"panic\",\"m\":\"t1\"\}")
    r.eq("15.15 the fence last", after15e[after15e.len() - 1],
         "\{\"t\":\"seen\",\"n\":11\}")
    r.no("15.16 and the circuit lives", c15e.ending())

    // An UNCONTAINED panic ends the circuit, so no fence — same rule as 15.11.
    let bare15: Bare = new Bare()
    let c15f: Circuit = attached(bare15, options_of())
    bare15.inner.boom = true
    c15f.accept(click_seq(2, 12), 2)
    r.eq("15.17 an uncontained panic is answered by the bye alone",
         drained(c15f), "\{\"t\":\"bye\",\"k\":\"panic\",\"m\":\"t1\"\}")

    // Resume replays, then fences. A reconnecting client is the one with the
    // most reason to want a definite end to its outstanding messages.
    let shell15g: Shell = new Shell()
    let c15g: Circuit = attached(shell15g, options_of())
    c15g.accept(click(2), 2)
    let _batch15g: List<string> = c15g.take_outbox()
    c15g.disconnected(3)
    c15g.accept("\{\"t\":\"resume\",\"c\":\"{CID}\",\"a\":0,\"n\":21\}", 4)
    let replay15: List<string> = c15g.take_outbox()
    // TWO batches, not one: `attached()` drains the WIRE but batch 1 is still
    // un-acked, so a resume from 0 replays the attach batch and the click
    // batch. Then the fence. My first want said two frames and was wrong.
    r.eqi("15.18 resume replays both un-acked batches and then fences",
          replay15.len(), 3)
    r.eq("15.19a the replay is in order", "{batch_number_of(replay15[0])},{batch_number_of(replay15[1])}",
         "1,2")
    r.eq("15.19 the fence is last", replay15[replay15.len() - 1],
         "\{\"t\":\"seen\",\"n\":21\}")

    // Two messages in flight, answered in the order they were sent. This is
    // what lets a client hold several deadlines at once and clear them by
    // number rather than by guessing which answer belongs to which question.
    let shell15h: Shell = new Shell()
    let c15h: Circuit = attached(shell15h, options_of())
    c15h.accept(click_seq(999, 31), 2)
    c15h.accept(click_seq(999, 32), 3)
    r.eq("15.20 two inert messages, two fences, in order", drained(c15h),
         "\{\"t\":\"seen\",\"n\":31\}\n\{\"t\":\"seen\",\"n\":32\}")

    io.println("")
    io.println("{r.checks} checks, {r.bad} bad")
}
