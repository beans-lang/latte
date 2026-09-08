// tests/_w8b_budget.b — PLAN.md gate 11's timing budgets. NOT A GATE.
//
//   "Budgets pinned in W8: render plus diff of a virtualised 50,000-row table,
//    event round trip at p50, bytes per batch before and after deflate,
//    resident memory per idle circuit."
//
// Scratch (`_` prefix), run by `w8b_budgets.sh`, which reads the machine's
// load first and refuses to call a number a measurement when the machine is
// busy. Three of the four are here; the fourth (resident memory) is
// `tests/_w8b_rss.b`, because it has to be sampled from outside the process.
//
// **Why this is scratch and not a suite.** Every number below is a duration,
// and a duration is not a golden. A gate that asserted one would go red on a
// loaded machine for a reason that is not a bug, and — worse — would go green
// on a fast machine after a real regression. RULES.md 3 wants both backends
// byte-identical against a golden; timings cannot be that. So this prints
// numbers, `w8b_budgets.sh` prints the load beside them, and `lanes/W8b.md`
// records them with the conditions. Re-run it to compare; do not gate on it.
//
// **What each number includes, said once.** `Circuit.accept(text, now)` is the
// whole server-side path for one client message: decode the JSON, find the
// handler or clamp the range, run the affected component's `render`, diff the
// new frame against the old, and serialize the edits into a batch string. The
// batch is then waiting in the outbox. That is what "render plus diff" costs
// in the only shape a user ever pays for it, and it is what B1 times.
//
// Sections:
//   B1  render plus diff of a virtualised 50,000-row table, and the
//       un-virtualised control that says what virtualisation bought
//   B2  event round trip at p50, over a real socket on a real kernel
//   B3  bytes per batch, before and after deflate, at 50,000-row scale
package main

import espresso
import std.compress
import std.io
import std.thread
import std.time
import std.websocket
import {Builder, Circuit, CircuitOptions, CircuitSet, Component, MouseEvent,
        Virtual, NO_POLLER_MESSAGE} from latte
import {run} from latte.boundary
import {CircuitSeam, EndpointOptions, has_fiber_poller, map_circuit} from latte.web

const ROWS: int = 50000
const ROW_HEIGHT: int = 32
const OVERSCAN: int = 4
const WINDOW: int = 30
const CID: string = "0123456789abcdef0123"

/// How many window moves B1 times. Large enough that one scheduling hiccup
/// cannot move the median, small enough that the whole probe is seconds.
const B1_MOVES: int = 400
/// How many round trips B2 times. Same reasoning, over a socket.
const B2_TRIPS: int = 400

// ============================================================== numbers

/// min / p50 / p90 / max of a list of nanosecond durations, as one line.
///
/// The MINIMUM is printed first and on purpose. On a machine with anything
/// else running, the median moves with the load and the minimum does not: it
/// is the closest thing to "what this costs when nothing is in the way".
/// p90 and max say how much the machine was in the way. A single mean would
/// hide both.
fn spread(name: string, samples: List<int>) {
    if samples.len() == 0 {
        io.println("{name}: no samples")
        return
    }
    var sorted: List<int> = []
    for value: int in samples { sorted.push(value) }
    sorted.sort()
    let n: int = sorted.len()
    let low: int = sorted[0]
    let p50: int = sorted[n / 2]
    let p90: int = sorted[(n * 9) / 10]
    let high: int = sorted[n - 1]
    io.println("{name}: n={n} min={low}ns p50={p50}ns p90={p90}ns max={high}ns")
    io.println("{name}: min={low / 1000}.{low % 1000 / 100}us p50={p50 / 1000}.{p50 % 1000 / 100}us p90={p90 / 1000}.{p90 % 1000 / 100}us max={high / 1000}.{high % 1000 / 100}us")
}

// ============================================================== the pages

/// A 50,000-row table, virtualised. The row body is deliberately ordinary —
/// a div, a class and a text node — because a row that rendered nothing would
/// make the window move look free.
pub class Sheet extends Component {
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "sheet")
        b.component<Virtual>(2, fn(list: Virtual) {
            list.count = ROWS
            list.row_height = ROW_HEIGHT
            list.overscan = OVERSCAN
            list.class_name = "sheet"
            list.row = fn(rb: Builder, index: int) {
                rb.open(0, "div")
                rb.attr(1, "class", "row")
                rb.text(2, "row {index}")
                rb.close()
            }
        })
        b.close()
    }
}

/// The control: the SAME rows, not virtualised. One render of this is what a
/// framework that walked the whole collection would pay on every change.
///
/// It is here because "render plus diff of a virtualised 50,000-row table" is
/// a number with no meaning on its own — fast compared to what? A reader
/// comparing the two lines below can see what the window bought.
pub class Flat extends Component {
    pub rows: int = 2000
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "flat")
        for index: int in 0..self.rows {
            b.region(2, "{index}")
            b.open(0, "div")
            b.attr(1, "class", "row")
            b.text(2, "row {index}")
            b.close()
            b.end_region()
        }
        b.close()
    }
}

/// A counter, for the round trip: one click, one field, one text edit out.
pub class Counter extends Component {
    pub count: int = 0
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "counter")
        b.open(2, "button")
        b.on_click(3, fn(e: MouseEvent) { self.count += 1 })
        b.text(4, "bump")
        b.close()
        b.open(5, "p")
        b.attr(6, "id", "n")
        b.text(7, "count {self.count}")
        b.close()
        b.close()
    }
}

// ============================================================== messages

fn attach_message() -> string {
    return "\{\"t\":\"attach\",\"c\":\"{CID}\",\"u\":\"/\"\}"
}

fn range_message(h: int, start: int, count: int) -> string {
    return "\{\"t\":\"range\",\"h\":{h},\"s\":{start},\"c\":{count}\}"
}

fn click(handler: int) -> string {
    return "\{\"t\":\"ev\",\"h\":{handler},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":4,\"y\":9\}\}"
}

/// A client's acknowledgement of every batch up to `number`.
///
/// **Not optional, and the first run here proved it.** `CircuitOptions`
/// retains sent batches until they are acked and ends the circuit at
/// `max_unacked` (32) — so a probe that only reads batches and never
/// acknowledges them gets 32 answers and then a `bye`, and the loop after that
/// times a dead circuit. The first version of this file recorded 11 samples
/// out of 400 and would have reported them as the median. Every ack below is
/// sent OUTSIDE the timed region, because a real client sends one too and the
/// number being asked for is the batch, not the bookkeeping.
fn ack(number: int) -> string {
    return "\{\"t\":\"ack\",\"b\":{number}\}"
}

/// A circuit with `page` mounted and its first batch already taken, so what is
/// timed after this is an update and never a mount.
fn mounted(page: Component) -> Circuit {
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 100000000
    options.retention_ms = 100000000
    let made: Circuit = new Circuit(CID, options,
        fn(url: string) -> Option<Component> { return some(page) })
    made.guard = run
    made.open(0)
    made.accept(attach_message(), 1)
    let first: List<string> = made.take_outbox()
    made.accept(ack(made.batch_count()), 1)
    return made
}

/// The mounted `Virtual`'s component id, asked of the renderer rather than
/// assumed: the number depends on mount order and a wrong guess would address
/// the page instead and time a refusal.
fn list_id(c: Circuit) -> int {
    for id: int in c.renderer.ids() {
        match c.renderer.component(id) {
            some(component) => {
                match component as? Virtual {
                    some(_) => { return id }
                    none => {}
                }
            }
            none => {}
        }
    }
    return -1
}

/// The first click handler the page registered, the same way.
fn click_id(c: Circuit) -> int { return 1 }

/// The attach batch a fresh circuit sends for `page`, without disturbing the
/// circuit B1 is about to time.
fn first_batch_of(page: Component) -> string {
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 100000000
    options.retention_ms = 100000000
    let made: Circuit = new Circuit(CID, options,
        fn(url: string) -> Option<Component> { return some(page) })
    made.guard = run
    made.open(0)
    made.accept(attach_message(), 1)
    let out: List<string> = made.take_outbox()
    // The outbox holds the HELLO first — `open` queues it before any client
    // message arrives — so `out[0]` is 57 bytes of handshake and not the page.
    // The first run of this file reported that 57 as the cost of a first
    // paint, which is the shape of wrong answer a probe with no golden gives
    // you: plausible, printed, and about a different thing entirely.
    for message: string in out {
        if message.starts_with("\{\"t\":\"batch\"") { return message }
    }
    return ""
}

// ============================================================== B1

fn budget_one() -> List<string> {
    io.println("-- B1  render plus diff, virtualised 50,000-row table")
    let sheet: Sheet = new Sheet()
    let c: Circuit = mounted(sheet)
    let vid: int = list_id(c)
    if vid < 0 {
        io.println("B1: FAILED — no virtual list mounted")
        return []
    }
    io.println("B1: rows in the table {ROWS}, rows in the window {WINDOW}, row height {ROW_HEIGHT}, overscan {OVERSCAN}")

    // The whole page, once, so B3 can say what a first paint costs on a table
    // this size. A SECOND Sheet, not this one: a component belongs to the
    // circuit that mounted it, and handing the same instance to two circuits
    // would leave the one about to be timed in a state nothing here chose.
    let page_batch: string = first_batch_of(new Sheet())

    // Warm: the first move after a mount pays for whatever the allocator has
    // not seen yet, and it is not what a scrolling user pays.
    var warm: int = 0
    for step: int in 0..20 {
        c.accept(range_message(vid, 100 + step * WINDOW, WINDOW), 2 + step)
        let dropped: List<string> = c.take_outbox()
        c.accept(ack(c.batch_count()), 2 + step)
        warm += dropped.len()
    }

    var samples: List<int> = []
    var batches: List<string> = []
    var moved: int = 0
    for step: int in 0..B1_MOVES {
        // A DIFFERENT window every time. A repeated range renders nothing —
        // `Virtual.apply_range` answers false and marks nothing — so timing a
        // repeated range would time the refusal and call it a render.
        let start: int = 1000 + step * WINDOW
        let before: int = time.monotonic_nanos()
        c.accept(range_message(vid, start, WINDOW), 100 + step)
        let out: List<string> = c.take_outbox()
        let after: int = time.monotonic_nanos()
        if out.len() == 1 {
            samples.push(after - before)
            moved += 1
            if batches.len() < 4 { batches.push(out[0]) }
        }
        c.accept(ack(c.batch_count()), 100 + step)
    }
    io.println("B1: {moved} of {B1_MOVES} window moves produced exactly one batch")
    io.println("B1: the circuit is still alive at the end: {!c.ending()} (a dead one answers nothing and would be timed as fast)")
    spread("B1 window move (decode + render + diff + serialize)", samples)

    // The control. One full render of a flat list, no window, so the two lines
    // can be read against each other. 2,000 rows and not 50,000 because the
    // point is the per-row cost, and 50,000 rows of un-virtualised HTML is a
    // number about this machine's memory rather than about latte.
    let flat: Flat = new Flat()
    let started: int = time.monotonic_nanos()
    let fc: Circuit = mounted(flat)
    let elapsed: int = time.monotonic_nanos() - started
    let per_row: int = elapsed / flat.rows
    io.println("B1 control: one un-virtualised render of {flat.rows} rows took {elapsed}ns ({elapsed / 1000}us), {per_row}ns per row")
    io.println("B1 control: at that rate {ROWS} rows would be {(per_row * ROWS) / 1000000}ms, and the window above is the whole reason nobody pays it")
    io.println("")
    var all: List<string> = []
    all.push(page_batch)
    for batch: string in batches { all.push(batch) }
    return move all
}

// ============================================================== B2

/// One event round trip, on a real socket: the client writes an `ev` frame and
/// blocks until the batch comes back. Everything in between is real — the
/// kernel, the framer, the fiber park and wake, the render, the diff and the
/// write back.
fn budget_two(port: int, control: espresso.ServerControl) -> string {
    var dialled: Result<websocket.Connection> =
        websocket.Connection.connect_timeout("127.0.0.1", port, "/_latte/ws",
                                             10000, true)
    if !dialled.is_ok() {
        let stopped: bool = control.stop().or(false)
        return "B2: FAILED — the handshake did not complete"
    }
    var socket: websocket.Connection = (move dialled).expect("handshake")

    // hello
    let hello: string = next_text(socket)
    let circuit_id: string = hello_id(hello)
    if circuit_id == "" {
        let stopped: bool = control.stop().or(false)
        return "B2: FAILED — no circuit id in the hello: {hello}"
    }
    let sent: Result<bool> =
        socket.send_text("\{\"t\":\"attach\",\"c\":\"{circuit_id}\",\"u\":\"/\"\}")
    let first: string = next_text(socket)

    // Warm the path: the first few trips pay for the deflate context, the
    // fiber's first park and whatever the allocator has not seen.
    //
    // The ack after every batch is REQUIRED, not politeness: the circuit ends
    // at `max_unacked` (32) un-acked batches, so a client that only reads gets
    // 32 answers and then a `bye`, and every trip after that is timed against
    // a dead circuit. It is sent outside the timed region below because a real
    // client sends one too and what is being asked for is the batch.
    var batch_no: int = 1
    for step: int in 0..20 {
        let asked: Result<bool> = socket.send_text(click(1))
        let back: string = next_text(socket)
        batch_no = batch_number(back, batch_no)
        let acked: Result<bool> = socket.send_text("\{\"t\":\"ack\",\"b\":{batch_no}\}")
    }

    var samples: List<int> = []
    var lost: int = 0
    var last_bad: string = ""
    for step: int in 0..B2_TRIPS {
        let before: int = time.monotonic_nanos()
        let asked: Result<bool> = socket.send_text(click(1))
        let back: string = next_text(socket)
        let after: int = time.monotonic_nanos()
        if back.starts_with("\{\"t\":\"batch\"") {
            samples.push(after - before)
        } else {
            lost += 1
            last_bad = back
        }
        batch_no = batch_number(back, batch_no)
        let acked: Result<bool> = socket.send_text("\{\"t\":\"ack\",\"b\":{batch_no}\}")
    }
    io.println("-- B2  event round trip over a real socket")
    io.println("B2: {samples.len()} trips measured, {lost} answers that were not a batch")
    if lost > 0 { io.println("B2: the last answer that was not a batch: {last_bad}") }
    io.println("B2: first batch was {first.len()} bytes; the timed batches are one text edit each")
    spread("B2 click -> batch, wire to wire", samples)
    io.println("")

    let closed: Result<bool> = socket.close(1000, "done")
    let stopped: bool = control.stop().or(false)
    return "B2 done"
}

fn next_text(socket: websocket.Connection) -> string {
    match socket.receive() {
        err(problem) => { return "<err {problem.kind}>" }
        ok(maybe) => {
            match maybe {
                none => { return "<end>" }
                some(message) => {
                    return match message {
                        text(body) => body,
                        binary(data) => "<binary {data.len()}>",
                        ping(data) => "<ping>",
                        pong(data) => "<pong>",
                        closed(code, reason) => "<closed {code}>",
                    }
                }
            }
        }
    }
}

/// The `b` field of a batch, or `fallback` when the frame is not one.
fn batch_number(frame: string, fallback: int) -> int {
    let marker: string = "\"b\":"
    match frame.find(marker) {
        none => { return fallback }
        some(at) => {
            let rest: string = frame.slice(at + marker.len(), frame.len())
            var digits: string = ""
            for index: int in 0..rest.len() {
                let ch: string = rest.slice(index, index + 1)
                if ch < "0" || ch > "9" { break }
                digits = "{digits}{ch}"
            }
            if digits == "" { return fallback }
            return digits.to_int().or(fallback)
        }
    }
}

fn hello_id(frame: string) -> string {
    let marker: string = "\"c\":\""
    match frame.find(marker) {
        none => { return "" }
        some(at) => {
            let rest: string = frame.slice(at + marker.len(), frame.len())
            match rest.find("\"") {
                none => { return "" }
                some(end) => { return rest.slice(0, end) }
            }
        }
    }
}

// ============================================================== B3

/// Bytes per batch, before and after deflate, at 50,000-row scale.
///
/// **This is a MODEL and W7's number is the measurement.** `lanes/W7.md`
/// counted the bytes a real kernel delivered, with the extension really
/// negotiated, over a 200-row table: 27,839 bytes uncompressed against
/// 1,719-1,722 compressed, 6.2%, six runs. Nothing here replaces that.
///
/// What this adds is the case W7 left open in D3: "if W8's 50,000-row budget
/// shows the per-frame batch dominated by payload rather than structure,
/// measure again". So these are the batches a 50,000-row virtual table
/// actually produces, run through `compress.deflate_raw` at zlib's default
/// level — per message, with a FRESH context each time, which is the
/// pessimistic bound. A real permessage-deflate connection keeps the context
/// between messages (W7 measured `server_takeover=true`) and does better than
/// this on every message after the first.
fn budget_three(batches: List<string>) {
    io.println("-- B3  bytes per batch, before and after deflate (50,000-row table)")
    if batches.len() == 0 {
        io.println("B3: no batches to measure")
        return
    }
    // batches[0] is the ATTACH batch — the whole page, which a client pays
    // once. The rest are window moves, which it pays on every scroll. They are
    // different questions and are not averaged together.
    var raw_total: int = 0
    var packed_total: int = 0
    var index: int = 0
    var moves: int = 0
    for batch: string in batches {
        let raw: Bytes = Bytes.from(batch)
        var label: string = "window move {index}"
        if index == 0 { label = "attach (the whole page)" }
        match compress.deflate_raw(raw, 6) {
            err(problem) => {
                io.println("B3: {label} would not deflate: {problem.kind}")
            }
            ok(packed) => {
                let ratio: int = (packed.len() * 1000) / raw.len()
                io.println("B3: {label}: {raw.len()} B raw -> {packed.len()} B deflated ({ratio / 10}.{ratio % 10}%)")
                if index > 0 {
                    raw_total += raw.len()
                    packed_total += packed.len()
                    moves += 1
                }
            }
        }
        index += 1
    }
    if moves > 0 {
        let ratio: int = (packed_total * 1000) / raw_total
        io.println("B3: {moves} window-move batch(es), {raw_total} B raw -> {packed_total} B deflated ({ratio / 10}.{ratio % 10}%), fresh context per message")
        io.println("B3: mean per window move {raw_total / moves} B raw, {packed_total / moves} B deflated")
    }
    io.println("B3: the wire measurement is lanes/W7.md — 27839 B -> 1719-1722 B, 6.2%, six runs over a real socket, 200-row table")
    io.println("")
}

// ============================================================== main

fn main() {
    io.println("latte timing budgets — PLAN.md gate 11")
    io.println("websocket bridge {websocket.available()} fiber poller {has_fiber_poller()}")
    io.println("")

    let batches: List<string> = budget_one()
    budget_three(batches)

    if !has_fiber_poller() {
        io.println("-- B2  SKIPPED: this target has no fiber network poller, so a")
        io.println("   circuit endpoint cannot serve here. NOT MEASURED: the event")
        io.println("   round trip. B1 and B3 above are unaffected — they never open")
        io.println("   a socket. {NO_POLLER_MESSAGE}")
        return
    }

    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return some(new Counter())
        })
    set.guard = run

    let seam: CircuitSeam = new CircuitSeam(
        set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
        set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
        set.wake_fn())

    // `websocket.Connection.connect` cannot send a `Cookie` header, so the
    // client below has no session and W4's binding would refuse it. This probe
    // measures the circuit, not the binding — `tests/w4_upgrade.b` owns that,
    // and `tests/_w8b_smoke_server.b` proves it from a real browser.
    var endpoint: EndpointOptions = new EndpointOptions()
    endpoint.anonymous_circuits = true
    endpoint.poll_ms = 100
    endpoint.socket_ms = 30000
    endpoint.no_poller_message = NO_POLLER_MESSAGE

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    map_circuit(app, "/_latte/ws", seam, endpoint).expect("circuit")

    var server_options: espresso.ServerOptions = new espresso.ServerOptions()
    server_options.port = 0
    server_options.poll_timeout_ms = 5
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, server_options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return budget_two(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println(visitor.join())
    io.println("circuits held {set.count()} faults {set.faults.len()} upgrades {stats.upgrades}")
}
