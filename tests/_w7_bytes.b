// tests/_w7_bytes.b — how many bytes a batch costs on the wire, with and
// without permessage-deflate. NOT A GATE. Scratch (`_` prefix), run by hand:
//
//     cd community-libs/latte && ../../beans/build/beansc run tests/_w7_bytes.b
//     cd community-libs/latte && ../../beans/build/beansc build tests/_w7_bytes.b -o /tmp/w7bytes && /tmp/w7bytes
//
// PLAN.md D3 makes wire v2 (binary) conditional on a measurement: "Deflate over
// JSON may already take most of what binary would, and a second encoding is a
// permanent tax on every protocol change. The gate is a real number from a real
// workload." This is that number.
//
// **What is measured, exactly.** Not a model of deflate — the bytes a real
// kernel delivered. Three runs against one real espresso server on port 0,
// each sending the SAME script over a real TCP connection:
//
//   A  a `std.websocket` client with compression OFF. Sums the length of each
//      decoded text message: the JSON the protocol actually produced.
//   B  a RAW `net.TcpStream` that writes its own HTTP upgrade with NO
//      `Sec-WebSocket-Extensions`, then counts every byte the server sends
//      after the 101. That is JSON plus WebSocket framing, on the wire.
//   C  the same raw socket, offering `permessage-deflate;
//      client_max_window_bits`, counting the same way. Same server, same page,
//      same script — the only difference is the extension.
//
// B and C send their client messages UNCOMPRESSED (RSV1 clear), which RFC 7692
// allows on a compressed connection, so hand-writing the frames needs no
// deflater on this side. It also means the client→server column is identical
// in both runs and is not the number this is about.
//
// The reading side has a read timeout and stops when it goes quiet. That is a
// TIMING dependency, and it is why this file is scratch and not a suite: a
// gate that stops reading on a timer is a gate that goes green on a slow
// machine for the wrong reason.
package main

import espresso
import std.io
import std.compress
import std.net
import std.thread
import std.websocket
import {Builder, Circuit, CircuitOptions, CircuitSet, Component,
        MouseEvent, NO_POLLER_MESSAGE} from latte
import {run} from latte.boundary
import {CircuitSeam, EndpointOptions, has_fiber_poller, map_circuit} from latte.web

// ============================================================== the page
//
// Two shapes in one page, because they compress very differently and a
// framework meets both: a counter whose batches are one short text edit, and a
// list whose FIRST batch is long and highly repetitive. Deflate is expected to
// do well on the second and badly on the first; a single-shape measurement
// would answer whichever question it happened to ask.

const ROWS: int = 200

pub class Board extends Component {
    pub count: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "board")
        b.open(2, "button")
        b.on_click(3, fn(e: MouseEvent) { self.count += 1 })
        b.text(4, "Count: {self.count}")
        b.close()
        b.open(5, "table")
        for index: int in 0..ROWS {
            b.region(6, "r{index}")
            b.open(0, "tr")
            b.open(1, "td")
            b.text(0, "row {index}")
            b.close()
            b.open(2, "td")
            b.text(0, "a value in column two")
            b.close()
            b.close()
            b.end_region()
        }
        b.close()
        b.close()
    }
}

// ============================================================== the script
//
// One attach and then `CLICKS` clicks. Every message is legal and every one of
// them changes the page, so the server answers each with exactly one batch —
// which is what makes "bytes per batch" a division and not an estimate.

const CLICKS: int = 20

fn attach_message(id: string) -> string {
    return "\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"/board\"\}"
}

fn click_message() -> string {
    return "\{\"t\":\"ev\",\"h\":2,\"k\":\"click\",\"p\":\{\"b\":0,\"x\":4,\"y\":9\}\}"
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

fn is_batch(frame: string) -> bool {
    return frame.starts_with("\{\"t\":\"batch\"")
}

// ============================================================== run A
//
// The decoded JSON. A real `std.websocket` client, compression off, so what it
// hands back is exactly the text `encode_batch` produced.

pub class RunA {
    pub bytes: int = 0
    pub batches: int = 0
    pub first_batch: int = 0
    pub messages: int = 0
    pub fault: string = ""
    pub fn init() {}
}

fn run_a(port: int) -> RunA {
    let out: RunA = new RunA()
    var dialled: Result<websocket.Connection> =
        websocket.Connection.connect_timeout("127.0.0.1", port, "/plain",
                                             10000, false)
    if !dialled.is_ok() { out.fault = "the handshake failed"; return out }
    var socket: websocket.Connection = (move dialled).expect("socket")
    if socket.deflate().is_some() {
        out.fault = "run A must not be compressed"
        let _closed: Result<bool> = socket.close(1000, "done")
        return out
    }
    var circuit: string = ""
    var sent: int = 0
    var quiet: bool = false
    for !quiet {
        match socket.receive() {
            err(problem) => { quiet = true }
            ok(maybe) => {
                match maybe {
                    none => { quiet = true }
                    some(message) => {
                        match message {
                            text(body) => {
                                out.messages += 1
                                out.bytes += body.len()
                                if is_batch(body) {
                                    out.batches += 1
                                    if out.first_batch == 0 { out.first_batch = body.len() }
                                }
                                if circuit == "" { circuit = hello_id(body) }
                                if circuit != "" && sent == 0 {
                                    let _ok: Result<bool> =
                                        socket.send_text(attach_message(circuit))
                                    sent = 1
                                } else if sent > 0 && sent <= CLICKS {
                                    let _ok: Result<bool> =
                                        socket.send_text(click_message())
                                    sent += 1
                                }
                                if sent > CLICKS && out.batches >= CLICKS + 1 {
                                    quiet = true
                                }
                            }
                            binary(data) => { out.messages += 1 }
                            ping(data) => {}
                            pong(data) => {}
                            closed(code, reason) => { quiet = true }
                        }
                    }
                }
            }
        }
    }
    let _closed: Result<bool> = socket.close(1000, "done")
    return out
}

// ============================================================== runs B and C
//
// A raw socket. The upgrade is written by hand so the extension offer can be
// present or absent with nothing else changing, and every byte after the blank
// line that ends the 101 is counted.

/// One masked client text frame. Every message this script sends is under 126
/// bytes, so the short length form is the only one needed — and a wrong guess
/// there would be a malformed frame, not a silent miscount.
fn client_frame(body: string) -> Bytes {
    let payload: Bytes = Bytes.from(body)
    var frame: Bytes = new Bytes(0)
    frame.push(129)
    if payload.len() >= 126 {
        // Refuse rather than truncate: a longer message needs the 16-bit form
        // and this probe would otherwise send a frame the server reads as
        // garbage and answer with a close nobody looks at.
        frame.push(128)
        return move frame
    }
    frame.push(128 + payload.len())
    // A fixed mask. RFC 6455 wants an unpredictable one to defend against
    // intermediaries rewriting traffic; nothing here goes through one, and a
    // fixed mask keeps the byte count reproducible.
    let mask: List<int> = [18, 52, 86, 120]
    for index: int in 0..4 { frame.push(mask[index]) }
    for index: int in 0..payload.len() {
        frame.push(payload.get(index) ^ mask[index % 4])
    }
    return move frame
}

pub class RunRaw {
    pub bytes: int = 0
    pub head_bytes: int = 0
    pub deflated: bool = false
    pub fault: string = ""
    pub fn init() {}
}

/// `read_ms` bounds how long this waits for the server to go quiet. It is the
/// timing dependency named at the top of the file.
///
/// The circuit id has to come out of this run's OWN hello, because a circuit id
/// is per-connection. With the extension agreed that first frame is
/// DEFLATE-compressed, so this side inflates exactly one message — a fresh
/// context, RFC 7692's four sync bytes put back, `std.compress.inflate_raw`.
/// It is the receiver's rule applied once, not a second receiver.
fn run_raw(port: int, path: string, offer: bool, read_ms: int) -> RunRaw {
    let out: RunRaw = new RunRaw()
    var dialled: Result<net.TcpStream> =
        net.TcpStream.connect_timeout("127.0.0.1", port, 10000)
    if !dialled.is_ok() { out.fault = "connect failed"; return out }
    var stream: net.TcpStream = (move dialled).expect("stream")
    let _timed: Result<bool> = stream.set_timeouts(read_ms, 5000)

    var request: string =
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    if offer {
        request = "{request}Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n"
    }
    request = "{request}\r\n"
    let _wrote: Result<int> = stream.write_text(request)

    var buffer: Bytes = new Bytes(65536)
    var head: Bytes = new Bytes(0)
    var frames: Bytes = new Bytes(0)
    var head_done: bool = false
    var counted: int = 0
    var attached: bool = false
    var quiet: bool = false
    for !quiet {
        match stream.read_into(buffer) {
            err(problem) => { quiet = true }
            ok(got) => {
                if got <= 0 { quiet = true }
                else {
                    if head_done {
                        counted += got
                        if !attached { frames.append_range(buffer, 0, got) }
                    } else {
                        head.append_range(buffer, 0, got)
                        let text: string = head.to_string()
                        match text.find("\r\n\r\n") {
                            some(at) => {
                                head_done = true
                                out.head_bytes = at + 4
                                out.deflated =
                                    text.slice(0, at).find("permessage-deflate").is_some()
                                counted += head.len() - (at + 4)
                                frames.append_range(head, at + 4, head.len())
                            }
                            none => {}
                        }
                    }
                    if head_done && !attached {
                        let id: string = first_frame_body(frames)
                        if id != "" {
                            var script: Bytes = new Bytes(0)
                            script.append(client_frame(attach_message(id)))
                            var written: int = 0
                            for written < CLICKS {
                                script.append(client_frame(click_message()))
                                written += 1
                            }
                            let _sent: Result<int> = stream.write(script)
                            attached = true
                        }
                    }
                }
            }
        }
    }
    if !attached { out.fault = "the hello never arrived whole" }
    out.bytes = counted
    let _closed: Result<bool> = stream.close()
    return out
}

/// The circuit id out of the first server frame in `data`, or "" if the frame
/// is not there yet.
///
/// Only the shapes this probe can actually receive are handled, and anything
/// else answers "" rather than guessing: a server→client frame is unmasked, a
/// hello is one frame, and it is well under 126 bytes either way.
fn first_frame_body(data: Bytes) -> string {
    if data.len() < 2 { return "" }
    let first: int = data.get(0)
    let compressed: bool = (first & 64) != 0
    let length: int = data.get(1)
    if length >= 126 { return "" }
    if data.len() < 2 + length { return "" }
    var payload: Bytes = data.slice(2, 2 + length)
    io.println("   [frame0 {first} len {length} have {data.len()} rsv1 {compressed}]")
    if !compressed { return hello_id(payload.to_string()) }
    // RFC 7692 §7.2.2: the sender stripped the four bytes that end a sync
    // flush; put them back and it is a complete raw DEFLATE stream.
    payload.push(0)
    payload.push(0)
    payload.push(255)
    payload.push(255)
    match compress.inflate_raw(payload, 65536) {
        ok(plain) => { return hello_id(plain.to_string()) }
        err(problem) => { io.println("   [inflate {problem.msg}]"); return "" }
    }
}

// ============================================================== the server

fn main() {
    io.println("websocket bridge {websocket.available()}")
    io.println("fiber poller {has_fiber_poller()}")
    if !has_fiber_poller() {
        io.println("no poller on this platform; the measurement needs one")
        return
    }

    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    options.max_unacked = 1000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            if url != "/board" { return none }
            return some(new Board())
        })
    set.guard = run

    let seam: CircuitSeam = new CircuitSeam(
        set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
        set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
        set.wake_fn())

    var squeezed: EndpointOptions = new EndpointOptions()
    squeezed.poll_ms = 50
    squeezed.socket_ms = 30000
    squeezed.compress = true
    squeezed.no_poller_message = NO_POLLER_MESSAGE

    var plain: EndpointOptions = new EndpointOptions()
    plain.poll_ms = 50
    plain.socket_ms = 30000
    plain.compress = false
    plain.no_poller_message = NO_POLLER_MESSAGE

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    map_circuit(app, "/ws", seam, squeezed).expect("ws")
    map_circuit(app, "/plain", seam, plain).expect("plain")

    var server_options: espresso.ServerOptions = new espresso.ServerOptions()
    server_options.port = 0
    server_options.poll_timeout_ms = 25
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, server_options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()

    let visitor: Thread<bool> = thread.spawn(fn() -> bool {
        let a: RunA = run_a(port)
        io.println("")
        io.println("-- A. the JSON the protocol produced (no compression)")
        io.println("   fault           {a.fault}")
        io.println("   text messages   {a.messages}")
        io.println("   batches         {a.batches}")
        io.println("   json bytes      {a.bytes}")
        io.println("   first batch     {a.first_batch}")

        let b: RunRaw = run_raw(port, "/plain", false, 400)
        io.println("")
        io.println("-- B. wire bytes, extension NOT offered")
        io.println("   fault           {b.fault}")
        io.println("   deflate agreed  {b.deflated}")
        io.println("   101 head bytes  {b.head_bytes}")
        io.println("   frame bytes     {b.bytes}")

        let c: RunRaw = run_raw(port, "/ws", true, 400)
        io.println("")
        io.println("-- C. wire bytes, permessage-deflate offered and agreed")
        io.println("   fault           {c.fault}")
        io.println("   deflate agreed  {c.deflated}")
        io.println("   101 head bytes  {c.head_bytes}")
        io.println("   frame bytes     {c.bytes}")

        io.println("")
        io.println("-- the division")
        let frames: int = CLICKS + 2
        io.println("   server frames   {frames}  (hello + attach batch + {CLICKS} click batches)")
        if b.bytes > 0 {
            io.println("   B bytes/frame   {b.bytes / frames}")
        }
        if c.bytes > 0 {
            io.println("   C bytes/frame   {c.bytes / frames}")
        }
        if b.bytes > 0 && c.bytes > 0 {
            io.println("   C as % of B     {(c.bytes * 100) / b.bytes}")
            io.println("   saved bytes     {b.bytes - c.bytes}")
        }
        let stopped: bool = control.stop().or(false)
        return stopped
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    let _joined: bool = visitor.join()
    io.println("")
    io.println("upgrades {stats.upgrades} circuits still held {set.count()}")
}
