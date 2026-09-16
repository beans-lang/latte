// tests/_w7_bytes.b — how many bytes a batch costs on the wire, with and
// without permessage-deflate. NOT A GATE. Scratch (`_` prefix), run by hand:
//
//     cd community-libs/latte && ../../beans/build/beansc run tests/_w7_bytes.b
//     cd community-libs/latte && ../../beans/build/beansc build tests/_w7_bytes.b -o /tmp/w7bytes && /tmp/w7bytes
//
// Whether a binary wire format is worth building depends on a real
// measurement: deflate over JSON may already take most of what binary would,
// and a second encoding on the wire is a permanent tax on every future
// protocol change. This file produces that number.
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

import github.com/beans-lang/espresso
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

fn click_message(handler: int) -> string {
    return "\{\"t\":\"ev\",\"h\":{handler},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":4,\"y\":9\}\}"
}

/// The slot id of the first click handler in a batch's reference pool.
///
/// It cannot be hard-coded: the id a builder assigns depends on the page, so
/// a fixed guess like `h:2` can land on nothing and leave every later click
/// unsent — every run would then measure ONE batch instead of twenty-one,
/// silently. A probe that quietly measures a tenth of its workload is worse
/// than one that fails.
fn click_slot(batch: string) -> int {
    let marker: string = "[\"h\","
    var from: int = 0
    for from < batch.len() {
        match batch.slice(from, batch.len()).find(marker) {
            none => { return -1 }
            some(at) => {
                let rest: string = batch.slice(from + at + marker.len(), batch.len())
                match rest.find("]") {
                    none => { return -1 }
                    some(end) => {
                        let row: string = rest.slice(0, end)
                        if row.find("\"click\"").is_some() {
                            match row.rfind(",") {
                                none => { return -1 }
                                some(comma) => {
                                    return row.slice(comma + 1, row.len()).to_int().or(-1)
                                }
                            }
                        }
                        from = from + at + marker.len()
                    }
                }
            }
        }
    }
    return -1
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
    pub slot: int = -1
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
    var slot: int = -1
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
                                    if out.first_batch == 0 {
                                        out.first_batch = body.len()
                                        slot = click_slot(body)
                                        out.slot = slot
                                    }
                                }
                                if circuit == "" { circuit = hello_id(body) }
                                if circuit != "" && sent == 0 {
                                    let _ok: Result<bool> =
                                        socket.send_text(attach_message(circuit))
                                    sent = 1
                                } else if sent > 0 && sent <= CLICKS && slot > 0 {
                                    let _ok: Result<bool> =
                                        socket.send_text(click_message(slot))
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
    pub frames: int = 0
    /// The size of every frame, header included, in arrival order. Frame 1 is
    /// the hello, frame 2 the attach batch, and 3.. the one-edit click
    /// batches — three shapes with very different compression, and an average
    /// over all of them would hide exactly the number a binary-wire-format
    /// decision would turn on.
    pub sizes: List<int> = []
    pub reads: int = 0
    pub wrote: int = 0
    pub script_len: int = 0
    pub last: string = ""
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
fn run_raw(port: int, path: string, offer: bool, slot: int, read_ms: int) -> RunRaw {
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
    // Every frame byte the server sent that this side has not yet accounted
    // for. Frames are COUNTED, never timed: the run stops when the expected
    // number of complete frames has arrived, so the byte total is a function
    // of the protocol and not of how fast this machine is. The read timeout
    // below is a safety net, and reaching it is reported as a fault.
    var frames: Bytes = new Bytes(0)
    var head_done: bool = false
    var counted: int = 0
    var attached: bool = false
    var quiet: bool = false
    let want: int = CLICKS + 2
    for !quiet {
        match stream.read_into(buffer) {
            err(problem) => { out.last = "{problem.kind}: {problem.msg}"; quiet = true }
            ok(got) => {
                out.reads += 1
                if got <= 0 { out.last = "zero read"; quiet = true }
                else {
                    if head_done {
                        counted += got
                        frames.append_range(buffer, 0, got)
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
                    if head_done && attached {
                        // Consume whole frames off the front. Server→client
                        // frames are unmasked, so a header is 2, 4 or 10 bytes
                        // and nothing here has to decompress anything to know
                        // where the next one starts.
                        var walking: bool = true
                        for walking {
                            let size: int = whole_frame_size(frames)
                            if size <= 0 || size > frames.len() { walking = false }
                            else {
                                out.frames += 1
                                out.sizes.push(size)
                                frames = frames.slice(size, frames.len())
                                if out.frames >= want { quiet = true; walking = false }
                            }
                        }
                    }
                    if head_done && !attached {
                        let id: string = first_frame_body(frames)
                        if id != "" {
                            var script: Bytes = new Bytes(0)
                            script.append(client_frame(attach_message(id)))
                            var written: int = 0
                            for written < CLICKS {
                                script.append(client_frame(click_message(slot)))
                                written += 1
                            }
                            out.script_len = script.len()
                            out.wrote = stream.write(script).or(-1)
                            attached = true
                            // The hello is frame one and it has already been
                            // read; count it and drop it here, so the walk
                            // above starts on the boundary it expects.
                            let size: int = whole_frame_size(frames)
                            if size > 0 && size <= frames.len() {
                                out.frames += 1
                                out.sizes.push(size)
                                frames = frames.slice(size, frames.len())
                            }
                        }
                    }
                }
            }
        }
    }
    if !attached { out.fault = "the hello never arrived whole" }
    else if out.frames < want {
        out.fault = "only {out.frames} of {want} frames arrived before the read timeout"
    }
    out.bytes = counted
    let _closed: Result<bool> = stream.close()
    return out
}

/// The total size of the frame at the front of `data`, header included, or 0
/// when the frame is not there whole yet.
///
/// Server→client frames are never masked, so the header is 2 bytes plus the
/// extended length. Nothing here reads the payload.
fn whole_frame_size(data: Bytes) -> int {
    if data.len() < 2 { return 0 }
    let flag: int = data.get(1)
    if flag >= 128 { return -1 }
    var header: int = 2
    var length: int = flag
    if flag == 126 {
        if data.len() < 4 { return 0 }
        header = 4
        length = data.get(2) * 256 + data.get(3)
    } else if flag == 127 {
        if data.len() < 10 { return 0 }
        header = 10
        length = 0
        for index: int in 2..10 { length = length * 256 + data.get(index) }
    }
    if data.len() < header + length { return 0 }
    return header + length
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
    if !compressed { return hello_id(payload.to_string()) }
    // RFC 7692 §7.2.2: the sender stripped the four bytes that end a sync
    // flush; put them back and the message is readable again.
    //
    // The STREAMING inflater, not `inflate_raw`. A sync-flushed block plus
    // those four bytes is NOT a terminated DEFLATE stream — there is no final
    // block — so the one-shot form refuses it with "the stream ends before its
    // data does". This is the same rule the real receiver follows.
    payload.push(0)
    payload.push(0)
    payload.push(255)
    payload.push(255)
    var opened: Result<compress.Inflater> =
        compress.Inflater.open(compress.Format.raw, 65536)
    if !opened.is_ok() { return "" }
    var reader: compress.Inflater = (move opened).expect("inflater")
    match reader.push(payload) {
        ok(plain) => { return hello_id(plain.to_string()) }
        err(problem) => { return "" }
    }
}

/// The three shapes, separately. An average over all twenty-two frames is
/// dominated by the one big one and says nothing about the shape a click
/// produces, which is the shape a binary encoding would have to beat.
fn report_shapes(tag: string, run: RunRaw) {
    if run.sizes.len() < 3 { return }
    var events: int = 0
    var smallest: int = run.sizes[2]
    var largest: int = run.sizes[2]
    for index: int in 2..run.sizes.len() {
        events += run.sizes[index]
        if run.sizes[index] < smallest { smallest = run.sizes[index] }
        if run.sizes[index] > largest { largest = run.sizes[index] }
    }
    let count: int = run.sizes.len() - 2
    io.println("{tag} hello          {run.sizes[0]}")
    io.println("{tag} attach batch   {run.sizes[1]}")
    io.println("{tag} {count} event batches  {events} total, {events / count} mean, {smallest}..{largest}")
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
    squeezed.anonymous_circuits = true
    squeezed.poll_ms = 50
    squeezed.socket_ms = 30000
    squeezed.compress = true
    squeezed.no_poller_message = NO_POLLER_MESSAGE

    var plain: EndpointOptions = new EndpointOptions()
    plain.anonymous_circuits = true
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
        io.println("   click slot      {a.slot}")

        let b: RunRaw = run_raw(port, "/plain", false, a.slot, 5000)
        io.println("")
        io.println("-- B. wire bytes, extension NOT offered")
        io.println("   fault           {b.fault}")
        io.println("   deflate agreed  {b.deflated}")
        io.println("   101 head bytes  {b.head_bytes}")
        io.println("   frame bytes     {b.bytes}")
        io.println("   frames read     {b.frames}")
        report_shapes("   B", b)

        let c: RunRaw = run_raw(port, "/ws", true, a.slot, 5000)
        io.println("")
        io.println("-- C. wire bytes, permessage-deflate offered and agreed")
        io.println("   fault           {c.fault}")
        io.println("   deflate agreed  {c.deflated}")
        io.println("   101 head bytes  {c.head_bytes}")
        io.println("   frame bytes     {c.bytes}")
        io.println("   frames read     {c.frames}")
        report_shapes("   C", c)

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
