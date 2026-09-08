// tests/_w8b_rss.b — PLAN.md gate 11's fourth budget: resident memory per
// idle circuit. NOT A GATE. Scratch (`_` prefix), driven by `w8b_budgets.sh`.
//
// **Why this is a separate program from `_w8b_budget.b`.** Resident memory is
// the one number a Beans program cannot read about itself: there is no
// `getrusage` or `/proc/self/statm` in the standard library (0.1.40 —
// `std.process` runs processes, it does not describe this one). So the number
// has to be sampled from OUTSIDE, and this program's whole job is to hold
// still at two known points while a shell reads `ps -o rss=` at each.
//
// The handshake is stdin, and it is a handshake rather than a sleep on
// purpose: a sleep long enough to be safe on a loaded machine makes the probe
// slow, and one short enough to be quick makes it wrong. The shell writes a
// line when it has finished sampling.
//
//   1. build everything except the circuits, print BASE, wait
//   2. open N circuits on an ORDINARY page, each attached and rendered once,
//      print OPEN, wait
//   3. open N more on the SMALLEST page that is still a page, print TINY, wait
//   4. leave
//
// (RSS(open) - RSS(base)) / N is the answer, and the shell does that division
// because it is the one holding both numbers.
//
// **Why there is a third phase.** "22 KB per idle circuit" is not actionable
// on its own: a reader cannot tell whether that is what a circuit costs or
// what their page costs. Phase 3 opens the same number of circuits on a page
// with three nodes instead of thirty-odd, in a second set, on top of
// everything phase 2 is still holding. Its delta is the circuit's own floor;
// the difference between the two is the page.
//
// **What "idle" means here, exactly.** A circuit that has been opened,
// attached, has rendered its page once and has had its first batch taken off
// the outbox — so it holds a live component tree, the last frame the differ
// will compare against, and its own bookkeeping. It holds no socket: a socket
// is espresso's and `std.websocket`'s memory, not latte's, and 2,000 live TCP
// connections would measure this machine's kernel buffers instead of this
// framework's per-circuit cost. The number to read this against is therefore
// "what a retained, disconnected circuit costs", which is exactly what
// `CircuitOptions.retention_ms` keeps alive after a client drops.
//
// **Not under `BEANS_NO_POOL`.** The leaks sweep sets it because a leaked
// object inside a pooled slab is invisible; here the pool is part of the
// answer, because a deployment runs with it. The shell says which it used.
package main

import std.io
import {Builder, Circuit, CircuitOptions, CircuitSet, Component, InputEvent,
        MouseEvent} from latte
import {run} from latte.boundary
import {fresh_id} from latte.web

/// How many circuits to open. Large enough that a slab boundary, one hash
/// table growth or the allocator's own arenas cannot dominate the division.
const CIRCUITS: int = 2000

/// A page of ordinary size: a heading, two bound inputs, a click handler and
/// twenty-five keyed rows. Not the smallest page that would compile — a
/// component tree with one text node in it would make the answer look like a
/// number about `Circuit` and not about a page.
pub class Board extends Component {
    pub title: string = "board"
    pub name: string = ""
    pub note: string = ""
    pub count: int = 0
    pub rows: List<string> = []
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "board")

        b.open(2, "h1")
        b.text(3, self.title)
        b.close()

        b.open(4, "input")
        b.attr(5, "value", self.name)
        b.on_input(6, fn(e: InputEvent) { self.name = e.value })
        b.close()

        b.open(7, "input")
        b.attr(8, "value", self.note)
        b.on_input(9, fn(e: InputEvent) { self.note = e.value })
        b.close()

        b.open(10, "button")
        b.on_click(11, fn(e: MouseEvent) { self.count += 1 })
        b.text(12, "count {self.count}")
        b.close()

        b.open(13, "ul")
        for row: string in self.rows {
            b.region(14, row)
            b.open(0, "li")
            b.attr(1, "data-key", row)
            b.text(2, row)
            b.close()
            b.end_region()
        }
        b.close()

        b.close()
    }
}

/// The smallest thing that is still a page: one element and one text node.
/// Phase 3 mounts this, and the difference between its delta and the Board's
/// is what a page of ordinary size costs on top of a circuit.
pub class Tiny extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.text(1, "tiny")
        b.close()
    }
}

fn make_rows() -> List<string> {
    var out: List<string> = []
    for index: int in 0..25 { out.push("row {index}") }
    return move out
}

/// Open `count` circuits on `set`, each attached and rendered once. Answers
/// how many really opened, which is never assumed: `CircuitSet.open` refuses
/// past `max_circuits` and records a fault, and dividing by the number asked
/// for rather than the number opened is how a wrong answer gets printed.
fn fill(set: CircuitSet, count: int, url: string, handles: List<int>) -> int {
    var opened: int = 0
    for index: int in 0..count {
        var facts: Map<string, string> = {}
        let id: string = fresh_id().or("")
        if id == "" { return opened }
        facts["id"] = id
        facts["session"] = "session-{index}"
        facts["origin"] = ""
        facts["path"] = url
        let handle: int = set.open(facts, 0)
        if handle < 0 { continue }
        // Attach, so the page is really mounted and really rendered once, and
        // the first batch is taken off the outbox the way a live client's
        // would be. A circuit that never attached holds no component tree and
        // would answer a much smaller and much less useful number.
        let batches: List<string> = set.accept(handle,
            "\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"{url}\"\}", 0)
        handles.push(handle)
        opened += 1
    }
    return opened
}

fn main() {
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 100000000
    options.retention_ms = 100000000
    // `max_circuits` defaults to 1,000 per worker, which is a POLICY about how
    // much one worker should hold and not a fact about what a circuit costs.
    // The first run of this probe opened 1,000 and recorded 1,000 faults for
    // the rest, and the division would have been over the wrong number. The
    // cap is raised here because this program is asking what one costs.
    options.max_circuits = CIRCUITS + 16
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            var page: Board = new Board()
            page.rows = make_rows()
            return some(page)
        })
    set.guard = run

    // Everything the program will ever need is built by now except the
    // circuits themselves: the set, the factory, the runtime's own arenas.
    // Whatever the sample below reads is the floor this measurement subtracts.
    io.eprintln("W8B-RSS-BASE circuits=0")
    let _wait: Option<string> = io.read_line()

    var handles: List<int> = []
    let opened: int = fill(set, CIRCUITS, "/", handles)
    io.eprintln("W8B-RSS-OPEN circuits={opened} held={set.count()} faults={set.faults.len()}")
    let _wait2: Option<string> = io.read_line()

    // Phase 3, in a SECOND set, on top of everything the first is still
    // holding. Its delta is the circuit's own floor, because the only thing
    // that changed is the size of the page.
    var tiny_options: CircuitOptions = new CircuitOptions()
    tiny_options.idle_ms = 100000000
    tiny_options.retention_ms = 100000000
    tiny_options.max_circuits = CIRCUITS + 16
    let tiny_set: CircuitSet = new CircuitSet(tiny_options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Tiny())
        })
    tiny_set.guard = run
    var tiny_handles: List<int> = []
    let tiny_opened: int = fill(tiny_set, CIRCUITS, "/tiny", tiny_handles)
    io.eprintln("W8B-RSS-TINY circuits={tiny_opened} held={tiny_set.count()} faults={tiny_set.faults.len()}")
    let _wait3: Option<string> = io.read_line()

    // Both lists are read here so nothing above can be dead-stored away: every
    // circuit must still be reachable at the moment the shell sampled.
    io.eprintln("W8B-RSS-DONE board={handles.len()} tiny={tiny_handles.len()} held={set.count()}+{tiny_set.count()}")
}
