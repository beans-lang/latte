// tests/w7_live.b — permessage-deflate ASSERTED, and the `seen` fence over a
// real socket.
//
// Two things this suite exists for, and neither can be checked without bytes
// crossing a TCP connection:
//
//   1. **Deflate is negotiated.** `EndpointOptions.compress` has defaulted to
//      `true`, and `tests/circuit_live.b`'s client has offered the extension
//      all along, and NOTHING HAS EVER ASSERTED IT. That suite passes
//      byte for byte with the extension silently declined, because a declined
//      extension changes no JSON. § 1 makes it a fact, with the two controls
//      that tell "agreed" from "agreed for another reason": a client that does
//      not offer, and an endpoint that does not compress.
//
//   2. **The `seen` fence, over a real socket.** `tests/circuit.b` § 15 proves
//      the fence at the state machine. This proves it where it matters: a
//      client sitting in `receive()` after sending a message that changed
//      nothing, with no server frame ever telling it so. § 2.1 is that
//      message.
//
// The three rules `tests/circuit_live.b` was written under hold here too, and
// for the same reasons: **port 0**, never a fixed port; **never assert a read
// boundary** — every read is one WebSocket message through the framer;
// **the client is an OS thread**, because Windows has no fiber network poller
// and a fiber peer deadlocks there.
//
// Byte-determinism: the port is never printed and the circuit id is 256 random
// bits, so it is replaced with `<id>` wherever it appears. Everything else is a
// function of the page and the messages. Timing appears nowhere — every message
// is sent only after the answer to the one before has been read.
package main

import espresso
import std.io
import std.thread
import std.websocket
import {Builder, CircuitOptions, CircuitSet, Component, MouseEvent,
        NO_POLLER_MESSAGE} from latte
import {run} from latte.boundary
import {CircuitSeam, EndpointOptions, has_fiber_poller, map_circuit} from latte.web

// ============================================================== the report

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

// ============================================================== the page

pub class Counter extends Component {
    pub count: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "button")
        b.on_click(1, fn(e: MouseEvent) { self.count += 1 })
        b.text(2, "Count: {self.count}")
        b.close()
    }
}

// ============================================================== the client

class Peer {
    socket: websocket.Connection
    fn init(move socket: websocket.Connection) { self.socket = move socket }

    fn next() -> string {
        match self.socket.receive() {
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

    fn send(text: string) -> bool { return self.socket.send_text(text).is_ok() }
    fn bye() -> bool { return self.socket.close(1000, "done").is_ok() }
    fn squeezed() -> bool { return self.socket.deflate().is_some() }
    /// The agreed parameters, as one line, or "none".
    fn agreement() -> string {
        match self.socket.deflate() {
            none => { return "none" }
            some(params) => {
                return "server_takeover={!params.server_no_context_takeover} client_takeover={!params.client_no_context_takeover} server_bits={params.server_max_window_bits} client_bits={params.client_max_window_bits}"
            }
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

fn dial(port: int, path: string, offer: bool) -> Option<Peer> {
    var dialled: Result<websocket.Connection> =
        websocket.Connection.connect_timeout("127.0.0.1", port, path, 10000, offer)
    if !dialled.is_ok() { return none }
    var opened: websocket.Connection = (move dialled).expect("handshake")
    return some(new Peer(move opened))
}

const PAGE_BATCH: string =
    "\{\"t\":\"batch\",\"b\":1,\"r\":[[\"o\",0,\"button\"],[\"h\",1,\"click\",1],[\"t\",2,\"Count: 0\"],[\"z\"]],\"u\":[\{\"c\":0,\"e\":[[\"in\",0,0]]\}],\"d\":[]\}"

fn client(port: int, control: espresso.ServerControl) -> string {
    let r: Report = new Report()

    // ---- 1. permessage-deflate, asserted -----------------------------------
    //
    // The assertion is made on the CLIENT's connection, and that is not a
    // convenience: `accept_deflate_response` sets it only when the SERVER
    // answered with a `Sec-WebSocket-Extensions` header it could read, so a
    // client-side `some` is proof about both ends of the handshake.
    io.println("-- 1. permessage-deflate is negotiated, and the two controls")

    match dial(port, "/_latte/ws", true) {
        none => { r.eq("1.1 the compressed handshake completed", "no", "yes") }
        some(peer) => {
            r.yes("1.1 the client offered and the server agreed", peer.squeezed())
            // 32 KiB windows and context takeover in both directions is what
            // `negotiate_deflate` answers a browser's usual offer with. It is
            // recorded because it is the memory bill: a DEFLATE context at 15
            // bits is about a third of a megabyte per direction, and
            // `websocket.Connection.accept` has no way to ask for less.
            r.eq("1.2 the agreed parameters", peer.agreement(),
                 "server_takeover=true client_takeover=true server_bits=15 client_bits=15")
            // The extension is not just agreed, it is USED: this page batch
            // came back through the inflater.
            let hello: string = peer.next()
            let id: string = hello_id(hello)
            r.eqi("1.3 the hello arrived whole through the inflater", id.len(), 64)
            r.yes("1.4 the attach went out",
                  peer.send("\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"/counter\"\}"))
            r.eq("1.5 and a compressed batch decompresses to the page",
                 peer.next(), PAGE_BATCH)
            let _bye: bool = peer.bye()
        }
    }

    // CONTROL A — the same endpoint, a client that offers nothing. Without it
    // "the server agreed" could not be told from "the server forces it".
    match dial(port, "/_latte/ws", false) {
        none => { r.eq("1.6 the plain handshake completed", "no", "yes") }
        some(peer) => {
            r.no("1.6 a client that does not offer gets no compression",
                 peer.squeezed())
            r.eq("1.7 and no agreement", peer.agreement(), "none")
            let _hello: string = peer.next()
            let _bye: bool = peer.bye()
        }
    }

    // CONTROL B — a client that offers, on an endpoint whose `compress` is
    // off. This is the one that would catch `EndpointOptions.compress` being
    // ignored: 1.1 passes whether the option is read or hard-coded to true.
    match dial(port, "/_latte/plain", true) {
        none => { r.eq("1.8 the declining handshake completed", "no", "yes") }
        some(peer) => {
            r.no("1.8 an endpoint with compress off declines the offer",
                 peer.squeezed())
            r.eq("1.9 and no agreement", peer.agreement(), "none")
            let _hello: string = peer.next()
            let _bye: bool = peer.bye()
        }
    }

    // ---- 2. the seen fence, over the socket --------------------------------
    io.println("")
    io.println("-- 2. a message that changed nothing is answered")

    match dial(port, "/_latte/ws", true) {
        none => { r.eq("2.0 the handshake completed", "no", "yes") }
        some(peer) => {
            let hello: string = peer.next()
            let id: string = hello_id(hello)
            r.yes("2.1 attached",
                  peer.send("\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"/counter\"\}"))
            r.eq("2.2 batch 1 is the page", peer.next(), PAGE_BATCH)

            // THE MESSAGE THE SEEN FENCE ANSWERS. Slot 999 is bound to nothing,
            // so nothing is marked and no batch is published. Before the fence
            // this read blocked until the socket's read deadline and then
            // answered `<err timeout>`.
            r.yes("2.3 an event on a slot the page does not have goes out",
                  peer.send("\{\"t\":\"ev\",\"h\":999,\"k\":\"click\",\"p\":\{\"b\":0,\"x\":4,\"y\":9\},\"n\":7\}"))
            r.eq("2.4 and it is ANSWERED rather than met with silence",
                 peer.next(), "\{\"t\":\"seen\",\"n\":7\}")

            // The control beside it: the same message on the slot that IS
            // bound sends the batch first and the fence after.
            r.yes("2.5 a real click goes out",
                  peer.send("\{\"t\":\"ev\",\"h\":1,\"k\":\"click\",\"p\":\{\"b\":0,\"x\":4,\"y\":9\},\"n\":8\}"))
            r.eq("2.6 the batch comes first", peer.next(),
                 "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":0,\"e\":[[\"si\",0],[\"ut\",0,\"Count: 1\"],[\"so\"]]\}],\"d\":[]\}")
            r.eq("2.7 and the fence after it", peer.next(),
                 "\{\"t\":\"seen\",\"n\":8\}")

            // An inert message with NO sequence is answered by nothing at all,
            // which is still the behaviour and is a decision (a client that
            // asks for no fence gets none). Proved without hanging: a fenced
            // message follows it, and the next frame is THAT message's fence —
            // so the unfenced one produced no frame.
            r.yes("2.8 an unfenced inert event goes out",
                  peer.send("\{\"t\":\"ev\",\"h\":999,\"k\":\"click\",\"p\":\{\"b\":0,\"x\":4,\"y\":9\}\}"))
            r.yes("2.9 and a fenced ack behind it",
                  peer.send("\{\"t\":\"ack\",\"b\":2,\"n\":9\}"))
            r.eq("2.10 the next frame is the ack's fence, so the event sent none",
                 peer.next(), "\{\"t\":\"seen\",\"n\":9\}")

            let _bye: bool = peer.bye()
        }
    }

    let stopped: bool = control.stop().or(false)
    io.println("")
    io.println("server stopped {stopped}")
    return "{r.checks} checks, {r.bad} bad"
}

// ============================================================== the server

fn main() {
    io.println("websocket bridge {websocket.available()}")
    io.println("fiber poller {has_fiber_poller()}")

    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            if url != "/counter" { return none }
            return some(new Counter())
        })
    set.guard = run

    let seam: CircuitSeam = new CircuitSeam(
        set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
        set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
        set.wake_fn())

    // Two endpoints on one application, differing in exactly one field. That
    // is what makes 1.8 a control rather than a second suite.
    // `websocket.Connection.connect` cannot send a `Cookie` header, so no
    // client this suite can build has a session — and since 2026-09-08 an
    // endpoint refuses a handshake it cannot bind to one. This suite is about
    // the circuit, not the binding; `tests/w4_upgrade.b` owns the binding and
    // asserts, in § 5, exactly what this line costs.
    var squeezed: EndpointOptions = new EndpointOptions()
    squeezed.anonymous_circuits = true
    squeezed.poll_ms = 50
    squeezed.socket_ms = 30000
    squeezed.no_poller_message = NO_POLLER_MESSAGE

    var plain: EndpointOptions = new EndpointOptions()
    plain.anonymous_circuits = true
    plain.poll_ms = 50
    plain.socket_ms = 30000
    plain.compress = false
    plain.no_poller_message = NO_POLLER_MESSAGE

    io.println("compress defaults to {squeezed.compress}")

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    map_circuit(app, "/_latte/ws", seam, squeezed).expect("ws")
    map_circuit(app, "/_latte/plain", seam, plain).expect("plain")

    var server_options: espresso.ServerOptions = new espresso.ServerOptions()
    server_options.port = 0
    server_options.poll_timeout_ms = 25
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, server_options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return client(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println("")
    io.println(visitor.join())
    io.println("")
    io.println("upgrades {stats.upgrades}")
}
