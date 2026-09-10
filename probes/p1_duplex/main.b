// Probe 1 — full duplex on ONE websocket.Connection from two fibers, under a
// slow reader.
//
// The latte circuit design has the espresso connection fiber writing edit
// batches while a brewed reader fiber
// calls receive() on the same Connection. Both drive wslay and both may park
// inside flush(). This probe answers whether that is safe, or whether a
// client that stops reading wedges the pair.
//
// The shape, per phase:
//
//   server (one worker)                  client (a real OS thread)
//   -------------------                  -------------------------
//   accept + upgrade                     connect + upgrade
//   brew reader_loop(conn, ...)          send `want` small text messages
//   writer_loop: send `count` x 16 KB    sleep `hold_ms` WITHOUT READING
//   join the reader                      then drain everything, verifying
//
// `count` x 16 KB is far more than a loopback socket will hold — measured at
// ~525 KB on this machine against a peer that never reads — so the writer is
// certain to be inside flush() while the client sleeps, with a message
// already waiting for the reader fiber. Whether the reader delivers it during
// that stall, or only after the client drains, is the answer.
//
// Every printed line is a derived fact.
package main

import std.encoding.base64
import std.http
import std.io
import std.net
import std.random
import std.thread
import std.time
import std.websocket

const SLICE_LEN: int = 16384
const SLICES: int = 16

// ---------------------------------------------------------------- the trace
//
// Shared by the two fibers. They sit on one worker and interleave only at
// park points, so plain fields are enough; no other OS thread touches this.
class Trace {
    pub start_ms: int = 0
    pub writer_sent: int = 0
    pub writer_done: bool = false
    pub writer_err: string = ""
    pub reader_got: int = 0
    pub reader_bad: int = 0
    pub reader_err: string = ""
    pub reader_first_ms: int = -1
    pub reader_first_writer_sent: int = -1
    pub reader_ran_while_writer_stuck: bool = false
    // 0 = the reader never writes, 1 = the reader calls send_text itself,
    // 2 = the reader hands its ack to the writer fiber through the outbox
    //     and only the writer fiber ever touches the socket (the send gate).
    pub ack: int = 0
    pub outbox: List<string> = []
    pub outbox_head: int = 0
}

// The reader fiber. In phase C it also writes, which is the second question:
// two fibers driving one framer and one socket.
fn reader_loop(conn: websocket.Connection, t: Trace, want: int) -> int {
    var seen: int = 0
    var live: bool = true
    for live && seen < want {
        match conn.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                seen += 1
                                if t.reader_first_ms < 0 {
                                    t.reader_first_ms =
                                        time.monotonic_millis() - t.start_ms
                                    t.reader_first_writer_sent = t.writer_sent
                                    // The probe in one field: the writer had
                                    // not finished, so it was stuck inside
                                    // flush() when this message was delivered.
                                    t.reader_ran_while_writer_stuck =
                                        !t.writer_done
                                }
                                if body != "c{seen}" { t.reader_bad += 1 }
                                t.reader_got = seen
                                if t.ack == 1 {
                                    match conn.send_text("a{seen}") {
                                        ok(_) => {}
                                        err(e) => {
                                            t.reader_err = "ack:{e.kind}"
                                            live = false
                                        }
                                    }
                                } else if t.ack == 2 {
                                    t.outbox.push("a{seen}")
                                }
                            }
                            binary(body) => { t.reader_bad += 1 }
                            ping(body) => {}
                            pong(body) => {}
                            closed(code, reason) => { live = false }
                        }
                    }
                    none => { live = false }
                }
            }
            err(e) => { t.reader_err = e.kind; live = false }
        }
    }
    return seen
}

// The send gate. Only the writer fiber ever calls it, so every frame that
// reaches the socket was queued by one fiber; the reader hands work over as
// data instead of driving the framer itself. Re-reading len() each round
// matters: the reader may push more while a send parks.
fn drain_outbox(conn: websocket.Connection, t: Trace) -> bool {
    for t.outbox_head < t.outbox.len() {
        let queued: string = t.outbox[t.outbox_head]
        t.outbox_head += 1
        match conn.send_text(queued) {
            ok(_) => {}
            err(e) => { t.writer_err = "gate:{e.kind}"; return false }
        }
    }
    return true
}

fn writer_loop(conn: websocket.Connection, t: Trace, count: int,
               chunks: List<string>) -> int {
    var sent: int = 0
    for index: int in 0..count {
        if t.ack == 2 {
            if !drain_outbox(conn, t) { t.writer_done = true; return sent }
        }
        let which: int = index % SLICES
        let body: string = "m{index}|{which}|{chunks[which]}"
        match conn.send_text(body) {
            ok(_) => { sent += 1; t.writer_sent = sent }
            err(e) => {
                t.writer_err = e.kind
                t.writer_done = true
                return sent
            }
        }
    }
    t.writer_done = true
    return sent
}

// `brew` is legal only at a function's own scope, so the duplex pair lives in
// its own function rather than inside the match arm that produced `conn`.
fn duplex(conn: websocket.Connection, t: Trace, count: int,
          chunks: List<string>, want: int) -> int {
    t.start_ms = time.monotonic_millis()
    let reader: Brew<int> = brew reader_loop(conn, t, want)
    let sent: int = writer_loop(conn, t, count, chunks)
    match reader.join() {
        ok(n) => {}
        err(e) => { t.reader_err = "join:{e.kind}" }
    }
    // Anything the reader queued after the writer's last send still has to
    // go out, and it goes out on this fiber like everything else.
    if t.ack == 2 { let flushed: bool = drain_outbox(conn, t) }
    let farewell: Result<bool> = conn.close(1000, "done")
    return sent
}

// ---------------------------------------------------------------- the client
//
// A real OS thread, so its stall is the peer's and not the server worker's.
// Nothing but scalars crosses the boundary: a thread closure cannot capture a
// plain class, and `chunks` is a move-only List the server still needs. The
// payload check does not need it — every slice index recurs eight times in
// 128 messages, so each repeat is compared byte for byte against the first
// time that slice was seen. A splice, a truncation or a reorder all fail it.
class Verdict {
    pub failures: int = 0
    pub data_seen: int = 0
    pub acks_seen: int = 0
    pub first_bad: string = ""
    pub connected: bool = false
    pub seen_slices: Map<int, string> = {}
}

fn check_data(v: Verdict, body: string) {
    let parts: List<string> = body.split("|")
    if parts.len() != 3 {
        v.failures += 1
        if v.first_bad == "" { v.first_bad = "shape" }
        v.data_seen += 1
        return
    }
    if parts[0] != "m{v.data_seen}" {
        v.failures += 1
        if v.first_bad == "" { v.first_bad = "order:{parts[0]}" }
    }
    let payload: string = parts[2]
    if payload.len() != SLICE_LEN {
        v.failures += 1
        if v.first_bad == "" { v.first_bad = "length:{payload.len()}" }
    }
    match parts[1].to_int() {
        ok(which) => {
            if v.seen_slices.contains_key(which) {
                if v.seen_slices[which] != payload {
                    v.failures += 1
                    if v.first_bad == "" { v.first_bad = "payload:{which}" }
                }
            } else {
                v.seen_slices[which] = payload
            }
        }
        err(e) => {
            v.failures += 1
            if v.first_bad == "" { v.first_bad = "index" }
        }
    }
    v.data_seen += 1
}

fn drain(conn: websocket.Connection, v: Verdict, count: int, want: int,
         ack: bool) {
    var live: bool = true
    let expect_acks: int = if ack { want } else { 0 }
    var rounds: int = 0
    for live && rounds < 1000000 &&
        (v.data_seen < count || v.acks_seen < expect_acks) {
        rounds += 1
        match conn.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                if body.starts_with("m") {
                                    check_data(v, body)
                                } else if body.starts_with("a") {
                                    v.acks_seen += 1
                                    if body != "a{v.acks_seen}" {
                                        v.failures += 1
                                        if v.first_bad == "" {
                                            v.first_bad = "ack-order"
                                        }
                                    }
                                } else {
                                    v.failures += 1
                                    if v.first_bad == "" { v.first_bad = "junk" }
                                }
                            }
                            binary(body) => {
                                v.failures += 1
                                if v.first_bad == "" { v.first_bad = "binary" }
                            }
                            ping(body) => {}
                            pong(body) => {}
                            closed(code, reason) => { live = false }
                        }
                    }
                    none => { live = false }
                }
            }
            err(e) => {
                v.failures += 1
                if v.first_bad == "" { v.first_bad = "recv:{e.kind}" }
                live = false
            }
        }
    }
}

fn client_side(port: int, count: int, want: int, hold_ms: int,
               compress: bool, ack: int) -> string {
    let v: Verdict = new Verdict()
    match websocket.Connection.connect_timeout(
            "127.0.0.1", port, "/circuit", 30000, compress) {
        ok(conn) => {
            v.connected = true
            for index: int in 1..want + 1 {
                match conn.send_text("c{index}") {
                    ok(_) => {}
                    err(e) => {
                        v.failures += 1
                        if v.first_bad == "" { v.first_bad = "send:{e.kind}" }
                    }
                }
            }
            // The slow reader: nothing is read for `hold_ms`, the server's
            // socket fills, and its writer is stuck inside flush().
            time.sleep_millis(hold_ms)
            drain(conn, v, count, want, ack != 0)
            let farewell: Result<bool> = conn.close(1000, "bye")
        }
        err(e) => {
            v.failures += 100
            v.first_bad = "connect:{e.kind}"
        }
    }
    let flag: int = if v.connected { 1 } else { 0 }
    return "{flag}|{v.data_seen}|{v.acks_seen}|{v.failures}|{v.first_bad}"
}

// ---------------------------------------------------------------- the server
fn read_upgrade(stream: net.TcpStream) -> Result<http.Request> {
    let parser: http.RequestParser = new http.RequestParser()
    var rounds: int = 0
    for rounds < 100 {
        rounds += 1
        let arrived: Bytes = stream.read(16384)?
        if arrived.len() == 0 {
            return err("the client closed during the upgrade", "eof")
        }
        let events: List<http.RequestEvent> = parser.feed(arrived)?
        var found: Option<http.Request> = none
        for event: http.RequestEvent in events {
            match event {
                head(value) => { found = some(value) }
                body(data) => {}
                trailers(fields) => {}
                done(keep_alive) => {}
                upgraded(value, remainder) => { found = some(value) }
            }
        }
        match found {
            some(value) => { return ok(value) }
            none => {}
        }
    }
    return err("no upgrade request arrived", "protocol")
}

fn upgrade(listener: net.TcpListener, compress: bool) -> Result<websocket.Connection> {
    let stream: net.TcpStream = listener.accept_timeout(30000)?
    // 30 s each way: never reached in a healthy run, and it turns a wedge
    // into a failed probe rather than a hung one.
    let tuned: Result<bool> = stream.set_timeouts(30000, 30000)
    let request: http.Request = read_upgrade(stream)?
    return websocket.Connection.accept(move stream, request, 8388608, compress)
}

// `expect_intact` is what makes this a test rather than a printout: phase C is
// SUPPOSED to corrupt the stream, so a run where it came out clean is as much
// a change in the answer as one where phase A broke.
fn phase(name: string, chunks: List<string>, count: int, want: int,
         hold_ms: int, compress: bool, ack: int, expect_intact: bool) -> bool {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let t: Trace = new Trace()
            t.ack = ack
            let visitor: Thread<string> = thread.spawn(fn() -> string {
                return client_side(port, count, want, hold_ms, compress, ack)
            })
            var sent: int = -1
            match upgrade(listener, compress) {
                ok(conn) => { sent = duplex(conn, t, count, chunks, want) }
                err(e) => { io.println("{name}: upgrade failed {e.kind}") }
            }
            let report: string = visitor.join()
            let fields: List<string> = report.split("|")
            let data_seen: int = fields[1].to_int().expect("data")
            let acks_seen: int = fields[2].to_int().expect("acks")
            let failures: int = fields[3].to_int().expect("failures")

            io.println("[{name}]")
            io.println("  the writer sent every message: {sent == count}")
            io.println("  the reader delivered every message: {t.reader_got == want}")
            io.println("  the reader saw no wrong body: {t.reader_bad == 0}")
            io.println("  the reader ran while the writer was stuck: {t.reader_ran_while_writer_stuck}")
            io.println("  the reader answered before the client drained: {t.reader_first_ms >= 0 && t.reader_first_ms < hold_ms / 2}")
            io.println("  the client got every data message, in order and whole: {data_seen == count && failures == 0}")
            if ack != 0 {
                io.println("  the client got every ack, in order: {acks_seen == want}")
            }
            if t.writer_err != "" { io.println("  writer error: {t.writer_err}") }
            if t.reader_err != "" { io.println("  reader error: {t.reader_err}") }
            if fields[4] != "" { io.println("  client saw: {fields[4]}") }

            let intact: bool = data_seen == count && failures == 0
            let live: bool = t.reader_got == want && t.reader_bad == 0 &&
                t.reader_ran_while_writer_stuck &&
                t.reader_first_ms >= 0 && t.reader_first_ms < hold_ms / 2
            if !live { return false }
            if intact != expect_intact { return false }
            if expect_intact {
                let acks_ok: bool = ack == 0 || acks_seen == want
                return sent == count && acks_ok
            }
            return true
        }
        err(e) => { io.println("{name}: bind failed {e.kind}") }
    }
    return false
}

fn build_chunks() -> List<string> {
    // base64 of CSPRNG bytes: ASCII, so send_text takes it, and near enough to
    // incompressible that permessage-deflate cannot shrink the phase-B payload
    // to fit in a socket buffer. Sixteen non-overlapping 16 KB slices, so a
    // 32 KB deflate window with context takeover never sees a repeat.
    let want_bytes: int = (SLICE_LEN * SLICES * 3) / 4 + 16
    var pool: string = ""
    match random.bytes(want_bytes) {
        ok(raw) => { pool = base64.encode(raw) }
        err(e) => { io.println("random failed {e.kind}") }
    }
    var out: List<string> = []
    for index: int in 0..SLICES {
        out.push(pool.slice(index * SLICE_LEN, (index + 1) * SLICE_LEN))
    }
    return move out
}

fn main() {
    let chunks: List<string> = build_chunks()
    io.println("chunks {chunks.len()} of {chunks[0].len()} bytes")
    // 128 x 16 KB = 2 MB against a loopback socket that holds about 525 KB.
    let a: bool = phase("A plain, the reader never writes", chunks, 128, 3, 2000, false, 0, true)
    let b: bool = phase("B permessage-deflate on", chunks, 128, 3, 2000, true, 0, true)
    let c: bool = phase("C both fibers write the socket", chunks, 128, 3, 2000, false, 1, false)
    // D is C with one line changed: the reader queues its ack instead of
    // sending it, and the writer fiber drains that queue. Same messages, same
    // volume, same stall — only the number of fibers that touch the framer
    // differs. C failing and D passing is what makes "one writer" the rule
    // rather than a guess.
    let d: bool = phase("D same acks through a send gate", chunks, 128, 3, 2000, false, 2, true)
    if a && b && c && d {
        io.println("probe p1_duplex: ok")
    } else {
        io.println("probe p1_duplex: FAILED a={a} b={b} c={c} d={d}")
    }
}
