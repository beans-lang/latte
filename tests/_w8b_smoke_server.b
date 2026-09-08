// tests/_w8b_smoke_server.b — the real server the Playwright smoke drives.
//
// PLAN.md gate 11: "One Playwright smoke in real Chromium before a release."
//
// **What already existed, and what this adds.** The `browser-apply` leg runs
// `js/latte.js` in headless Chrome against fixtures `tests/js_cases.b` printed
// into a file, and it is the strongest applier check in the repo — 469 of them.
// `tests/circuit_live.b` runs a real espresso server on port 0 and drives it
// with a `std.websocket` client on an OS thread. Between them they prove the
// applier in a browser and the protocol on a socket, and **neither one joins
// the two**: no test in this repo has ever had a browser open a WebSocket to a
// latte circuit. Everything in the join is unproven by construction — the
// handshake a browser actually sends, the `Origin` header only a browser sets,
// the boot path in `latte.js` that reads its own `<script>` tag, and what the
// real DOM does with a real batch that came off a real socket.
//
// This file is the server half of that join. It is a leg input and not a
// gated suite (leading `_`, like `tests/_wasm_core.b`): it has no golden,
// because a server that stays up until a browser tells it to stop cannot
// print a fixed number of lines before it does. Its output is read by
// `w8b_smoke.sh`, which starts it, reads the port off stderr, runs
// `tests/w8b_smoke.js` in Chromium against it, and then asserts the summary
// this program prints on the way out.
//
// **Three things it does that no other program here does, each deliberate.**
//
//   1. **It serves a page shell that boots a circuit.** Nothing in `latte`
//      emits one yet — `map_pages` answers a body, and the `<script>` tag
//      carrying `data-latte-circuit` is named in PLAN.md § "the page shell"
//      and is not written. So this file writes one by hand. That is a
//      statement about the framework, not a shortcut: see `lanes/W8b.md`.
//
//   2. **It mints the circuit id at page render and hands it to the seam.**
//      `CircuitEndpoint.upgrade` mints a fresh id per socket, and
//      `latte.js` refuses a `hello` whose id differs from the one its page
//      carried. The seam is the documented place a host decides ids, so the
//      `open` closure below uses the id the page was served with, for the
//      FIRST socket only — a reconnect deliberately gets the endpoint's own
//      fresh id, because that is the state `CircuitSet.adopt` exists for.
//
//   3. **It names its own origin in `EndpointOptions.origins`.** A browser
//      always sends `Origin`; an empty allowlist refuses every handshake that
//      carries one, which is the right default and means a browser cannot
//      connect to a deployment that has not named itself. The list is filled
//      in after `bind`, because the port is the kernel's to choose.
//
// The port is printed, once, on a line of its own, because a harness outside
// this process has to find it and a fixed port is a false green when something
// else is listening.
//
// **Every `W8B-SMOKE-*` line goes to stderr, and that is not a style choice.**
// `std.io` is a builtin package whose whole surface is println / eprintln /
// print / eprint / read_line / read_all — there is no `flush`. On this host
// `rt_write` is `fwrite(..., stdout)`, and stdout to a pipe is fully buffered,
// so the port line would sit in a 64 KiB buffer until the process exits — that
// is, until after the harness gave up waiting for it. stderr is unbuffered, so
// the harness sees the port the moment `bind` returns.
package main

import espresso
import std.fs
import std.io
import {Builder, Circuit, CircuitOptions, CircuitSet, Component, InputEvent,
        MouseEvent, NO_POLLER_MESSAGE} from latte
import {run} from latte.boundary
import {CircuitSeam, EndpointOptions, fresh_id, has_fiber_poller,
        map_circuit} from latte.web

// ============================================================== the page

/// Everything the smoke asserts, and nothing it does not.
///
/// `id` attributes on every interesting node because Playwright addresses the
/// DOM by selector, and a selector that matches by position would pass while
/// the applier put the right text in the wrong place.
pub class Board extends Component {
    pub count: int = 0
    pub name: string = ""
    pub rows: List<string> = ["alpha", "bravo", "charlie", "delta", "echo"]
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "board")

        b.open(2, "button")
        b.attr(3, "id", "bump")
        b.on_click(4, fn(e: MouseEvent) { self.count += 1 })
        b.text(5, "bump")
        b.close()

        b.open(6, "p")
        b.attr(7, "id", "count")
        b.text(8, "count {self.count}")
        b.close()

        b.open(9, "input")
        b.attr(10, "id", "name")
        b.attr(11, "value", self.name)
        b.on_input(12, fn(e: InputEvent) { self.name = e.value })
        b.close()

        b.open(13, "p")
        b.attr(14, "id", "greeting")
        b.text(15, "hello {self.name}")
        b.close()

        b.open(16, "button")
        b.attr(17, "id", "rotate")
        b.on_click(18, fn(e: MouseEvent) { self.rotate() })
        b.text(19, "rotate")
        b.close()

        // Five rows, not two. A keyed reorder over two elements is satisfied
        // by almost any wrong implementation; over five, a differ that
        // rebuilt the list instead of moving one child produces different
        // edits, and the smoke reads DOM node identity to tell them apart.
        b.open(20, "ul")
        b.attr(21, "id", "rows")
        for row: string in self.rows {
            b.region(22, row)
            b.open(0, "li")
            b.attr(1, "data-key", row)
            b.text(2, row)
            b.close()
            b.end_region()
        }
        b.close()

        b.close()
    }

    /// First row to the back. Five keys in, five keys out, all still there.
    fn rotate() {
        var next: List<string> = []
        for index: int in 1..self.rows.len() { next.push(self.rows[index]) }
        next.push(self.rows[0])
        self.rows = move next
    }
}

// ============================================================== the wiring

/// What the page route and the socket seam have to agree about.
///
/// One accept loop serves this process — `WebServer.bind` runs a single
/// worker and every connection is a fiber on it — so these plain fields are
/// read and written by one OS thread. A multi-worker host would need the id
/// in the session store instead, which is what a real deployment does.
pub class Wiring {
    pub set: Option<CircuitSet> = none
    /// The id the last page shell was served with, and not yet claimed by a
    /// socket. Empty means "the endpoint's own fresh id stands", which is
    /// what a reconnect must get.
    pub pending_id: string = ""
    pub pages_served: int = 0
    pub scripts_served: int = 0
    pub circuits_opened: int = 0
    pub adopted_id: string = ""
    /// Filled in after `bind`, because a `ServerControl` does not exist before
    /// one. `/_stop` uses it so the harness can end the run cleanly and read
    /// the summary; killing the process would lose every server-side fact.
    pub stopper: Option<espresso.ServerControl> = none
    pub stops: int = 0
    pub fn init() {}
}

/// The page shell. Hand-written; see the header.
///
/// `#latte-root` is empty on purpose. PLAN.md D5 is "replace on attach for
/// v1": the server sends the whole page in batch 1 and the applier builds it.
/// So a smoke that finds `count 0` in the DOM has proved that a batch crossed
/// a socket, and not that a template was substituted.
fn shell(circuit_id: string) -> string {
    return "<!doctype html>\n<html lang=\"en\">\n<head><meta charset=\"utf-8\"><title>latte smoke</title></head>\n<body>\n<div id=\"latte-root\"></div>\n<script src=\"/latte.js\" data-latte-circuit=\"{circuit_id}\" data-latte-ws=\"/_latte/ws\" data-latte-root=\"latte-root\"></script>\n</body>\n</html>\n"
}

fn main() {
    if !has_fiber_poller() {
        // Windows has no fiber network poller, so every circuit past the
        // first waits for the one before it and this program would hang with
        // nothing printed. Say so and leave; the harness treats a missing
        // PORT line as a failure, and this line tells it why.
        io.eprintln("W8B-SMOKE-UNAVAILABLE {NO_POLLER_MESSAGE}")
        return
    }

    var applier: string = ""
    match fs.read("js/latte.js") {
        ok(text) => { applier = text }
        err(problem) => {
            io.eprintln("W8B-SMOKE-UNAVAILABLE cannot read js/latte.js: {problem.kind}")
            return
        }
    }

    let wiring: Wiring = new Wiring()
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            if url != "/" { return none }
            wiring.pages_served += 1
            return some(new Board())
        })
    set.guard = run
    wiring.set = some(set)

    // The seam. Every closure but `open` is the set's own; `open` is the one
    // place a host decides what id a socket's circuit gets, and this host
    // decides it is the id the page was served with — once.
    let open_here: fn(Map<string, string>, int) -> int =
        fn(facts: Map<string, string>, now_ms: int) -> int {
            var mine: Map<string, string> = {}
            match facts.get("id") { some(value) => { mine["id"] = value } none => {} }
            match facts.get("session") { some(value) => { mine["session"] = value } none => {} }
            match facts.get("origin") { some(value) => { mine["origin"] = value } none => {} }
            match facts.get("path") { some(value) => { mine["path"] = value } none => {} }
            if wiring.pending_id != "" {
                mine["id"] = wiring.pending_id
                wiring.adopted_id = wiring.pending_id
                wiring.pending_id = ""
            }
            wiring.circuits_opened += 1
            return set.open(mine, now_ms)
        }

    let seam: CircuitSeam = new CircuitSeam(
        open_here, set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
        set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
        set.wake_fn())

    var endpoint: EndpointOptions = new EndpointOptions()
    endpoint.poll_ms = 100
    endpoint.socket_ms = 30000
    endpoint.no_poller_message = NO_POLLER_MESSAGE

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")

    // The static half, as middleware rather than routes, because latte's own
    // host half is middleware and this keeps the two in one shape. A request
    // it does not answer falls through to `next`, so the upgrade route still
    // works.
    app.use(fn(context: espresso.HttpContext,
               next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        let path: string = context.request.target
        if path == "/" {
            let id: string = fresh_id()?
            wiring.pending_id = id
            context.response.text_body(200, "OK", shell(id), "text/html; charset=utf-8")
            return ok(true)
        }
        // Chrome asks for this on every navigation with no prompting, and a
        // 404 for it would land in the console assertion as noise that has
        // nothing to do with latte.
        if path == "/favicon.ico" {
            context.response.text_body(204, "No Content", "",
                                       "image/x-icon")
            return ok(true)
        }
        if path == "/_stop" {
            wiring.stops += 1
            match wiring.stopper {
                some(control) => { let asked: bool = control.stop().or(false) }
                none => {}
            }
            context.response.text_body(200, "OK", "stopping\n",
                                       "text/plain; charset=utf-8")
            return ok(true)
        }
        if path == "/latte.js" {
            wiring.scripts_served += 1
            context.response.text_body(200, "OK", applier,
                                       "text/javascript; charset=utf-8")
            return ok(true)
        }
        return next(context)
    }).expect("static")

    map_circuit(app, "/_latte/ws", seam, endpoint).expect("circuit")

    var server_options: espresso.ServerOptions = new espresso.ServerOptions()
    server_options.port = 0
    server_options.poll_timeout_ms = 25
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, server_options).expect("server")
    let port: int = server.port().expect("port")

    // The allowlist, now that the kernel has chosen. Both spellings, because
    // a browser sends the host exactly as it was typed and `localhost` and
    // `127.0.0.1` are different origins.
    endpoint.origins = ["http://127.0.0.1:{port}", "http://localhost:{port}"]

    wiring.stopper = some(server.control())

    // One line, first, on the unbuffered stream: the harness blocks on it.
    io.eprintln("W8B-SMOKE-PORT {port}")

    let stats: espresso.ServerStats = server.run().expect("run")

    // The summary. Everything here is a server-side fact the browser could
    // not have faked, and the harness asserts on it.
    io.eprintln("W8B-SMOKE-UPGRADES {stats.upgrades}")
    io.eprintln("W8B-SMOKE-PAGES {wiring.pages_served}")
    io.eprintln("W8B-SMOKE-SCRIPTS {wiring.scripts_served}")
    io.eprintln("W8B-SMOKE-CIRCUITS {wiring.circuits_opened}")
    io.eprintln("W8B-SMOKE-STOPS {wiring.stops}")
    io.eprintln("W8B-SMOKE-HELD {set.count()}")
    io.eprintln("W8B-SMOKE-FAULTS {set.faults.len()}")
    for fault: string in set.faults { io.eprintln("W8B-SMOKE-FAULT {fault}") }
    io.eprintln("W8B-SMOKE-DONE")
}
