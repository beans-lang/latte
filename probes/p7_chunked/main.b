// Probe 7 — a chunked response through `encode_response_head_append`.
//
// The design for espresso's `context.begin_stream()` was to write the head
// through `encode_response_head_append` and return a writer that frames each
// chunk. This probe asks the function what it actually does, then writes a
// real chunked response on a real socket and reads it back with a real HTTP
// response parser.
//
// Phase A: what `encode_response_head_append` frames.
// Phase B: a chunked response on port 0, decoded by `http.ResponseParser`.
// Phase C: the same bytes fed one byte at a time — any byte split of the same
//          input must produce the same events, which is the property
//          `std.http` already holds itself to and the one a streamed response
//          has to hold too.
package main

import std.http
import std.io
import std.net
import std.thread

// --------------------------------------------------------------- phase A
fn head_of(status: int, reason: string, headers: http.Headers,
           body_len: int, keep_alive: bool) -> string {
    let target: Bytes = new Bytes(0)
    match http.encode_response_head_append(
            target, status, reason, headers, body_len, keep_alive) {
        ok(forbidden) => {
            return "ok(body_forbidden={forbidden}) [{target.to_string().replace("\r\n", "|")}]"
        }
        err(e) => { return "err({e.kind}) {e.msg}" }
    }
}

fn phase_a() -> bool {
    let plain: http.Headers = new http.Headers()
    plain.add("Content-Type", "text/html")
    io.println("A1 a 200 with a known length:")
    io.println("   {head_of(200, "OK", plain, 42, true)}")

    let chunked: http.Headers = new http.Headers()
    chunked.add("Content-Type", "text/html")
    chunked.add("Transfer-Encoding", "chunked")
    io.println("A2 asking it for a chunked head:")
    io.println("   {head_of(200, "OK", chunked, 0, true)}")

    io.println("A3 a 200 with length 0 — the closest it gets:")
    io.println("   {head_of(200, "OK", plain, 0, true)}")

    io.println("A4 a 204, which forbids a body:")
    io.println("   {head_of(204, "No Content", plain, 0, true)}")

    // The recorded answer is that it REFUSES a chunked head. A run where A2
    // succeeded would mean std.http grew a chunked encoder of its own — which
    // must fail here, not go unnoticed.
    return head_of(200, "OK", chunked, 0, true).starts_with("err(invalid)") &&
        head_of(200, "OK", plain, 42, true).contains("Content-Length: 42") &&
        head_of(204, "No Content", plain, 0, true).starts_with("ok(body_forbidden=true)")
}

// --------------------------------------------------------------- the writer
//
// What espresso has to write itself, because `encode_response_head_append`
// will not: a head whose framing is Transfer-Encoding rather than
// Content-Length, then each chunk, then the terminator.
//
// `http.field_is_safe` is the piece of std.http's write-side refusal that IS
// reachable from outside, and it is the one that matters — it is what stops a
// header value carrying a CR or an LF and splitting the response.
fn chunked_head(status: int, reason: string, headers: http.Headers,
                keep_alive: bool) -> Result<Bytes> {
    if status < 100 || status > 599 {
        return err("a response status must be 100..599", "invalid")
    }
    if !http.field_is_safe(reason) {
        return err("the reason phrase carries a control byte", "invalid")
    }
    if headers.has("Content-Length") || headers.has("Transfer-Encoding") {
        return err("the stream writer owns HTTP framing", "invalid")
    }
    if headers.has("Connection") {
        return err("the stream writer owns the Connection header", "invalid")
    }
    let out: Bytes = new Bytes(0)
    out.append_string("HTTP/1.1 ")
    out.append_int_text(status)
    out.push(32)
    out.append_string(reason)
    out.append_string("\r\n")
    out.append_string("Transfer-Encoding: chunked\r\n")
    if !keep_alive { out.append_string("Connection: close\r\n") }
    for index: int in 0..headers.count() {
        let name: string = headers.name_at(index)
        let value: string = headers.value_at(index)
        if !http.field_is_safe(name) || !http.field_is_safe(value) {
            return err("header {name} carries a control byte", "invalid")
        }
        out.append_string(name)
        out.append_string(": ")
        out.append_string(value)
        out.append_string("\r\n")
    }
    out.append_string("\r\n")
    return ok(move out)
}

// A zero-length chunk IS the terminator: `0\r\n\r\n` is how a chunked body
// ends, so writing an empty piece silently truncates the response and
// everything after it is read as trailers or as the next message. The first
// version of this probe did exactly that and the byte-split check is what
// showed it. A stream writer must refuse an empty chunk, not emit one — a
// component that rendered nothing is a chunk that is not sent.
fn chunk_of(body: string) -> Result<Bytes> {
    if body.len() == 0 {
        return err("a zero-length chunk terminates the body; do not write one",
                   "invalid")
    }
    let out: Bytes = new Bytes(0)
    out.append_string(hex_of(body.len()))
    out.append_string("\r\n")
    out.append_string(body)
    out.append_string("\r\n")
    return ok(move out)
}

fn hex_of(value: int) -> string {
    if value == 0 { return "0" }
    let digits: string = "0123456789abcdef"
    var left: int = value
    var out: string = ""
    for left > 0 {
        let nibble: int = left % 16
        out = "{digits.slice(nibble, nibble + 1)}{out}"
        left = left / 16
    }
    return out
}

fn last_chunk(trailer_name: string, trailer_value: string) -> Bytes {
    let out: Bytes = new Bytes(0)
    out.append_string("0\r\n")
    if trailer_name != "" {
        out.append_string(trailer_name)
        out.append_string(": ")
        out.append_string(trailer_value)
        out.append_string("\r\n")
    }
    out.append_string("\r\n")
    return move out
}

// --------------------------------------------------------------- the server
fn read_request(stream: net.TcpStream) -> Result<http.Request> {
    let parser: http.RequestParser = new http.RequestParser()
    var rounds: int = 0
    for rounds < 100 {
        rounds += 1
        let arrived: Bytes = stream.read(16384)?
        if arrived.len() == 0 { return err("the client went away", "eof") }
        var found: Option<http.Request> = none
        for event: http.RequestEvent in parser.feed(arrived)? {
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
    return err("no request arrived", "protocol")
}

// Writes the head and each chunk as its OWN send, so the response really does
// leave the server in pieces — a single joined write would prove nothing about
// streaming.
fn serve_chunked(listener: net.TcpListener, pieces: List<string>,
                 tally: Tally) -> Result<int> {
    let stream: net.TcpStream = listener.accept_timeout(20000)?
    let tuned: Result<bool> = stream.set_timeouts(20000, 20000)
    let request: http.Request = read_request(stream)?
    let headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "text/html")
    let head: Bytes = chunked_head(200, "OK", headers, false)?
    var wrote: int = stream.write_all(head)?
    for piece: string in pieces {
        match chunk_of(piece) {
            ok(framed) => { wrote += stream.write_all(framed)?; tally.sent += 1 }
            err(e) => { tally.refused += 1 }
        }
    }
    wrote += stream.write_all(last_chunk("X-Latte-Chunks", "{tally.sent}"))?
    let shut: Result<bool> = stream.shutdown_write()
    let closed: Result<bool> = stream.close()
    return ok(wrote)
}

class Tally {
    pub sent: int = 0
    pub refused: int = 0
    pub fn init() {}
}

// --------------------------------------------------------------- the client
class Seen {
    pub status: int = 0
    pub chunked: bool = false
    pub body: string = ""
    pub body_events: int = 0
    pub trailer: string = ""
    pub done: bool = false
    pub raw: Bytes = new Bytes(0)
    pub error: string = ""
}

fn absorb(seen: Seen, events: List<http.ResponseEvent>) {
    for event: http.ResponseEvent in events {
        match event {
            head(response) => {
                seen.status = response.status
                seen.chunked = response.chunked
            }
            body(data) => {
                seen.body = "{seen.body}{data.to_string()}"
                seen.body_events += 1
            }
            trailers(fields) => {
                for index: int in 0..fields.count() {
                    seen.trailer = "{fields.name_at(index)}={fields.value_at(index)}"
                }
            }
            done(keep_alive) => { seen.done = true }
            upgraded(response, remainder) => { seen.error = "unexpected upgrade" }
        }
    }
}

fn client_side(port: int) -> string {
    let seen: Seen = new Seen()
    match net.TcpStream.connect_timeout("127.0.0.1", port, 20000) {
        ok(stream) => {
            let tuned: Result<bool> = stream.set_timeouts(20000, 20000)
            let asked: Result<int> = stream.write_text(
                "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let parser: http.ResponseParser = new http.ResponseParser()
            var rounds: int = 0
            for rounds < 10000 && !seen.done {
                rounds += 1
                match stream.read(4096) {
                    ok(arrived) => {
                        if arrived.len() == 0 {
                            match parser.finish() {
                                ok(events) => { absorb(seen, events) }
                                err(e) => { seen.error = "finish:{e.kind}" }
                            }
                            rounds = 10000
                        } else {
                            seen.raw.append(arrived)
                            match parser.feed(arrived) {
                                ok(events) => { absorb(seen, events) }
                                err(e) => { seen.error = "feed:{e.kind}"; rounds = 10000 }
                            }
                        }
                    }
                    err(e) => { seen.error = "read:{e.kind}"; rounds = 10000 }
                }
            }
            let closed: Result<bool> = stream.close()
            // Phase C: the same bytes, one at a time, through a fresh parser.
            let split: Seen = new Seen()
            let byte_parser: http.ResponseParser = new http.ResponseParser()
            var index: int = 0
            for index < seen.raw.len() {
                match byte_parser.feed_range(seen.raw, index, index + 1) {
                    ok(events) => { absorb(split, events) }
                    err(e) => { split.error = "split:{e.kind}"; index = seen.raw.len() }
                }
                index += 1
            }
            if !split.done {
                match byte_parser.finish() {
                    ok(events) => { absorb(split, events) }
                    err(e) => { split.error = "splitfinish:{e.kind}" }
                }
            }
            let same: bool = split.status == seen.status &&
                split.chunked == seen.chunked && split.body == seen.body &&
                split.trailer == seen.trailer && split.done == seen.done &&
                split.error == ""
            let chunked_flag: int = if seen.chunked { 1 } else { 0 }
            let done_flag: int = if seen.done { 1 } else { 0 }
            let same_flag: int = if same { 1 } else { 0 }
            return "{seen.status}|{chunked_flag}|{seen.body}|{seen.body_events}|{seen.trailer}|{done_flag}|{same_flag}|{seen.error}|{seen.raw.len()}"
        }
        err(e) => { return "0|0||0||0|0|connect:{e.kind}|0" }
    }
}

fn phase_b() -> bool {
    var pieces: List<string> = []
    pieces.push("<latte-chunk for=\"s1\">first</latte-chunk>")
    pieces.push("<latte-chunk for=\"s2\">second</latte-chunk>")
    pieces.push("")
    let filler: string = "x".repeat(5000)
    pieces.push("<latte-chunk for=\"s3\">third, long enough to cross a read boundary on its own: {filler}</latte-chunk>")
    var joined: string = ""
    var non_empty: int = 0
    for piece: string in pieces {
        joined = "{joined}{piece}"
        if piece.len() > 0 { non_empty += 1 }
    }

    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<string> = thread.spawn(fn() -> string {
                return client_side(port)
            })
            let tally: Tally = new Tally()
            var wrote: int = -1
            match serve_chunked(listener, pieces, tally) {
                ok(count) => { wrote = count }
                err(e) => { io.println("B serve failed: {e.kind}: {e.msg}") }
            }
            let report: string = visitor.join()
            let f: List<string> = report.split("|")
            let status: int = f[0].to_int().expect("status")
            let chunked: bool = f[1] == "1"
            let body: string = f[2]
            let body_events: int = f[3].to_int().expect("events")
            let trailer: string = f[4]
            let done: bool = f[5] == "1"
            let same: bool = f[6] == "1"

            io.println("B1 the client saw 200 and chunked framing: {status == 200 && chunked}")
            io.println("B2 the body reassembled byte for byte: {body == joined}")
            io.println("B3 the writer refused the empty chunk: {tally.refused == 1 && tally.sent == non_empty}")
            io.println("B4 the body arrived in more than one event: {body_events > 1}")
            io.println("B5 the trailer came through: {trailer == "X-Latte-Chunks={non_empty}"}")
            io.println("B6 the parser saw the message end: {done}")
            io.println("C  every byte split gave the same events: {same}")
            if f[7] != "" { io.println("   client error: {f[7]}") }
            if wrote < 0 { io.println("   server did not finish") }
            return status == 200 && chunked && body == joined &&
                tally.refused == 1 && tally.sent == non_empty &&
                body_events > 1 && trailer == "X-Latte-Chunks={non_empty}" &&
                done && same && f[7] == "" && wrote > 0
        }
        err(e) => { io.println("B bind failed: {e.kind}") }
    }
    return false
}

// --------------------------------------------------------------- phase D
//
// Keep-alive. espresso serves keep-alive connections, so a streamed response
// has to end cleanly enough that the NEXT request on the same socket is read
// as a request and not as more body. A writer that forgets the terminator
// wedges the connection instead of failing, which is the worst shape of bug.
fn serve_two_chunked(listener: net.TcpListener) -> Result<int> {
    let stream: net.TcpStream = listener.accept_timeout(20000)?
    let tuned: Result<bool> = stream.set_timeouts(20000, 20000)
    var served: int = 0
    for round: int in 0..2 {
        let request: http.Request = read_request(stream)?
        let headers: http.Headers = new http.Headers()
        headers.add("Content-Type", "text/html")
        let head: Bytes = chunked_head(200, "OK", headers, true)?
        let wrote: int = stream.write_all(head)?
        let piece: Bytes = chunk_of("response-{round}")?
        let body: int = stream.write_all(piece)?
        let tail: int = stream.write_all(last_chunk("", ""))?
        served += 1
    }
    let closed: Result<bool> = stream.close()
    return ok(served)
}

fn client_two(port: int) -> string {
    match net.TcpStream.connect_timeout("127.0.0.1", port, 20000) {
        ok(stream) => {
            let tuned: Result<bool> = stream.set_timeouts(20000, 20000)
            let parser: http.ResponseParser = new http.ResponseParser()
            var bodies: string = ""
            var finished: int = 0
            var alive: bool = true
            for round: int in 0..2 {
                if !alive { return "{bodies}|{finished}|dead" }
                let asked: Result<int> = stream.write_text(
                    "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
                let seen: Seen = new Seen()
                var rounds: int = 0
                for rounds < 10000 && !seen.done {
                    rounds += 1
                    match stream.read(4096) {
                        ok(arrived) => {
                            if arrived.len() == 0 { alive = false; rounds = 10000 }
                            else {
                                match parser.feed(arrived) {
                                    ok(events) => { absorb(seen, events) }
                                    err(e) => { return "{bodies}|{finished}|feed:{e.kind}" }
                                }
                            }
                        }
                        err(e) => { return "{bodies}|{finished}|read:{e.kind}" }
                    }
                }
                if seen.done { finished += 1; bodies = "{bodies}{seen.body};" }
            }
            let closed: Result<bool> = stream.close()
            return "{bodies}|{finished}|"
        }
        err(e) => { return "|0|connect:{e.kind}" }
    }
}

fn phase_d() -> bool {
    match net.TcpListener.bind("127.0.0.1", 0) {
        ok(listener) => {
            let port: int = listener.port().expect("port")
            let visitor: Thread<string> = thread.spawn(fn() -> string {
                return client_two(port)
            })
            var served: int = -1
            match serve_two_chunked(listener) {
                ok(count) => { served = count }
                err(e) => { io.println("D serve failed: {e.kind}: {e.msg}") }
            }
            let report: string = visitor.join()
            let f: List<string> = report.split("|")
            let finished: int = f[1].to_int().expect("finished")
            io.println("D1 two chunked responses on one keep-alive connection: {served == 2 && finished == 2}")
            io.println("D2 each body was read as its own message: {f[0] == "response-0;response-1;"}")
            if f[2] != "" { io.println("   client error: {f[2]}") }
            return served == 2 && finished == 2 &&
                f[0] == "response-0;response-1;" && f[2] == ""
        }
        err(e) => { io.println("D bind failed: {e.kind}") }
    }
    return false
}

fn main() {
    let a: bool = phase_a()
    let b: bool = phase_b()
    let d: bool = phase_d()
    if a && b && d { io.println("probe p7_chunked: ok") }
    else { io.println("probe p7_chunked: FAILED a={a} b={b} d={d}") }
}
