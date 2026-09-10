// tests/w4_upgrade.b — the WebSocket upgrade is bound to the session cookie.
//
// Cross-site WebSocket hijacking: SameSite does not protect a handshake, so
// the upgrade checks `Origin` **and the circuit id must match the session
// cookie**. The Origin half was there. The session half was not, and it was
// missing in the way a refusal can sit in the code and never actually run:
//
//   * `EndpointOptions.session_cookie` said `"sid"`. `map_pages` sets
//     `latte_session`. So `context.request.cookie(...)` answered `none` for
//     every handshake ever made against this framework.
//   * A `none` became `facts["session"] = ""`, and `CircuitSet.adopt`'s
//     control — `session_of(target) != session_of(handle)` — then compared
//     `""` against `""` for every pair of circuits on the machine. Written,
//     reached, running, and unable to refuse anything.
//
// **Why this file exists at all, when `tests/circuit_live.b` § 13 already has
// a session pair.** That section drives `CircuitSet.adopt` directly, and says
// why: `websocket.Connection.connect` cannot send a `Cookie` header. Driving
// the set is a test of `circuit.b`. It cannot see a host that reads the wrong
// cookie name, because it never reads a cookie — it hands `facts["session"]`
// in by hand. Everything below goes over a real socket with a hand-written
// handshake, so the host's own read of the cookie is what is under test.
//
// **What each section would catch.**
//
//   § 1  the page half mints a session, and the socket half's default names
//        the SAME cookie. Flip `session_cookie` back to `"sid"` and 1.4 fails.
//   § 2  no cookie is refused, and the same handshake WITH one is accepted.
//        The pair is the point: one of them alone cannot tell "refused for the
//        right reason" from "this handshake was broken all along".
//   § 3  a cookie under another name is refused. This is the regression test
//        for the two-spellings bug specifically: it must be refused for
//        carrying no `latte_session`, not for carrying no cookie at all.
//   § 4  Origin and session are two refusals, not one. Each is shown with the
//        other satisfied.
//   § 5  the steal, end to end and over sockets: session s1 attaches and
//        drops, session s2 presents its circuit id and is refused, session s1
//        presents the same id and is served. Then the SAME three steps against
//        an endpoint with `anonymous_circuits = true`, where the theft
//        SUCCEEDS — so the cost of that option is a golden line rather than a
//        sentence in a doc comment.
//
// **What makes it byte-deterministic.** Ports are chosen by the kernel and
// never printed. A session id is 256 random bits and a circuit id is another
// 256, so neither is printed either — what is printed is their shape and the
// answers to questions about them. Batch bodies are never spelled out here:
// the wire format belongs to `wire.b` and inventing its bytes in this file
// would be asserting a photograph. What is asserted is that the replayed batch is
// **the same string** the circuit first sent, which is the property this suite
// is about.
package main

import espresso
import std.io
import std.net
import std.thread
import std.websocket
import {Builder, Component, CircuitOptions, CircuitSet, NO_POLLER_MESSAGE} from latte
import {run} from latte.boundary
import {CircuitSeam, EndpointOptions, has_fiber_poller, map_circuit, map_pages,
        NO_SESSION_MESSAGE, SESSION_COOKIE, WebReply, WebRequest} from latte.web

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

/// The smallest page that still mounts. This suite is about who may open a
/// circuit, not about what renders in one.
pub class Tiny extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "tiny")
        b.close()
    }
}

/// The static half, so the server mints a real `latte_session` cookie through
/// the real `map_pages` middleware and this file never invents one.
fn page_reply(request: WebRequest) -> Option<WebReply> {
    if request.path != "/page" { return none }
    var reply: WebReply = new WebReply()
    reply.body = "<p>hello</p>"
    return some(reply)
}

// ============================================================== raw HTTP
//
// Hand-written because the two clients std ships cannot do what this suite
// needs: `websocket.Connection.connect` writes its own handshake with no way
// to add a header, and nothing else can send `Cookie` and then keep the socket.

/// 16 zero bytes, strict base64. `WebSocketTransport.accept` decodes the key
/// and requires exactly 16 bytes; the value itself is not a secret and a fixed
/// one keeps every handshake in this file identical apart from the headers
/// under test.
const WS_KEY: string = "AAAAAAAAAAAAAAAAAAAAAA=="

/// Read up to and including the blank line that ends an HTTP head, one byte at
/// a time.
///
/// One byte at a time on purpose: the 101 head and the `hello` frame behind it
/// arrive in ONE TCP segment natively and TWO under the interpreter — a
/// finding written up in `tests/circuit_live.b`. A buffered read would eat
/// the frame on one backend and not the other, and the socket handed to
/// `Connection.wrap` must start exactly at the first frame byte.
fn read_head(stream: net.TcpStream) -> string {
    var head: string = ""
    for index: int in 0..8192 {
        match stream.read_exact(1) {
            err(problem) => { return "{head}<read {problem.kind}>" }
            ok(byte) => {
                head = "{head}{byte.to_string()}"
                if head.ends_with("\r\n\r\n") { return head }
            }
        }
    }
    return "{head}<head too long>"
}

/// The status line's code, or -1.
fn status_of(head: string) -> int {
    if !head.starts_with("HTTP/1.1 ") { return -1 }
    let rest: string = head.slice(9, head.len())
    match rest.find(" ") {
        none => { return -1 }
        some(at) => { return rest.slice(0, at).to_int().or(-1) }
    }
}

/// The status line without its version, e.g. `403 Forbidden`.
fn status_line(head: string) -> string {
    match head.find("\r\n") {
        none => { return "<no status line>" }
        some(at) => {
            let line: string = head.slice(0, at)
            if !line.starts_with("HTTP/1.1 ") { return line }
            return line.slice(9, line.len())
        }
    }
}

/// The first value of `name` in a head, or `""`.
fn header_of(head: string, name: string) -> string {
    let marker: string = "\r\n{name}: "
    match head.find(marker) {
        none => { return "" }
        some(at) => {
            let rest: string = head.slice(at + marker.len(), head.len())
            match rest.find("\r\n") {
                none => { return rest }
                some(end) => { return rest.slice(0, end) }
            }
        }
    }
}

/// Write a WebSocket handshake. An empty `cookie` or `origin` omits the header
/// entirely, which is not the same as sending an empty one.
fn write_handshake(stream: net.TcpStream, port: int, cookie: string,
                   origin: string) -> bool {
    var request: string = "GET /_latte/ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
    request = "{request}Upgrade: websocket\r\nConnection: Upgrade\r\n"
    request = "{request}Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {WS_KEY}\r\n"
    if cookie != "" { request = "{request}Cookie: {cookie}\r\n" }
    if origin != "" { request = "{request}Origin: {origin}\r\n" }
    request = "{request}\r\n"
    return stream.write_text(request).is_ok()
}

/// A handshake that is expected NOT to become a circuit: `<status line> | <body>`.
fn refused(port: int, cookie: string, origin: string) -> string {
    var dialled: Result<net.TcpStream> =
        net.TcpStream.connect_timeout("127.0.0.1", port, 10000)
    if !dialled.is_ok() { return "<no connection>" }
    var stream: net.TcpStream = (move dialled).expect("connect")
    let timed: Result<bool> = stream.set_timeouts(10000, 10000)
    if !write_handshake(stream, port, cookie, origin) { return "<no request>" }
    let head: string = read_head(stream)
    var body: string = ""
    match stream.read_to_end(4096) {
        ok(rest) => { body = rest.to_string() }
        err(problem) => { body = "<body {problem.kind}>" }
    }
    let closed: Result<bool> = stream.close()
    return "{status_line(head)} | {body}"
}

/// A handshake that is expected to become a circuit.
fn upgraded(port: int, cookie: string, origin: string) -> Result<websocket.Connection> {
    var stream: net.TcpStream =
        net.TcpStream.connect_timeout("127.0.0.1", port, 10000)?
    stream.set_timeouts(10000, 10000)?
    if !write_handshake(stream, port, cookie, origin) {
        return err("the handshake request could not be written", "io")
    }
    let head: string = read_head(stream)
    if status_of(head) != 101 {
        return err("the server answered {status_line(head)}", "refused")
    }
    return websocket.Connection.wrap(move stream, false, 65536, none)
}

/// One ordinary HTTP GET, head and body, so the suite can read `Set-Cookie`.
fn http_get(port: int, path: string, cookie: string) -> string {
    var dialled: Result<net.TcpStream> =
        net.TcpStream.connect_timeout("127.0.0.1", port, 10000)
    if !dialled.is_ok() { return "<no connection>" }
    var stream: net.TcpStream = (move dialled).expect("connect")
    let timed: Result<bool> = stream.set_timeouts(10000, 10000)
    var request: string = "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
    if cookie != "" { request = "{request}Cookie: {cookie}\r\n" }
    request = "{request}Connection: close\r\n\r\n"
    if !stream.write_text(request).is_ok() { return "<no request>" }
    let head: string = read_head(stream)
    var body: string = ""
    match stream.read_to_end(65536) {
        ok(rest) => { body = rest.to_string() }
        err(problem) => { body = "" }
    }
    let closed: Result<bool> = stream.close()
    return "{head}{body}"
}

/// The `name=value` of a `Set-Cookie`, without its attributes.
fn set_cookie_pair(response: string) -> string {
    let raw: string = header_of(response, "Set-Cookie")
    match raw.find(";") {
        none => { return raw }
        some(at) => { return raw.slice(0, at) }
    }
}

fn cookie_name(pair: string) -> string {
    match pair.find("=") {
        none => { return "" }
        some(at) => { return pair.slice(0, at) }
    }
}

fn cookie_value(pair: string) -> string {
    match pair.find("=") {
        none => { return "" }
        some(at) => { return pair.slice(at + 1, pair.len()) }
    }
}

fn is_hex(text: string) -> bool {
    if text.len() == 0 { return false }
    let digits: string = "0123456789abcdef"
    for index: int in 0..text.len() {
        if digits.find(text.slice(index, index + 1)).is_none() { return false }
    }
    return true
}

// ============================================================== the peer

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
}

/// The `c` of a `hello`.
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

fn attach(id: string) -> string {
    return "\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"/tiny\"\}"
}

fn resume(id: string) -> string {
    return "\{\"t\":\"resume\",\"c\":\"{id}\",\"a\":0\}"
}

/// The three steps of a theft, as one function, so the bound endpoint and the
/// anonymous one are driven by **the same code** and differ only in the option.
///
/// `mine` and `theirs` are the two clients' cookie headers; both are empty for
/// the anonymous run, which is exactly the condition under test.
///
/// Answers `<what the thief got> || <what the owner got back>`.
fn steal(r: Report, port: int, tag: string, mine: string, theirs: string) -> string {
    var owner_socket: Result<websocket.Connection> = upgraded(port, mine, "")
    if !owner_socket.is_ok() {
        r.yes("{tag}.1 the owner's handshake completed", false)
        return "<no owner>"
    }
    let owner: Peer = new Peer((move owner_socket).expect("owner"))
    let greeting: string = owner.next()
    let id: string = hello_id(greeting)
    r.eqi("{tag}.1 the owner's circuit id is 256 bits", id.len(), 64)
    r.yes("{tag}.2 the owner attached", owner.send(attach(id)))
    let first: string = owner.next()
    r.yes("{tag}.3 and was sent batch 1",
          first.starts_with("\{\"t\":\"batch\",\"b\":1,") && first.contains("tiny"))

    // The owner drops. The circuit stays retained, which is the only state in
    // which a resume — honest or not — has anything to pick up.
    let gone: bool = owner.bye()

    var thief_socket: Result<websocket.Connection> = upgraded(port, theirs, "")
    if !thief_socket.is_ok() {
        r.yes("{tag}.4 the thief's handshake completed", false)
        return "<no thief>"
    }
    let thief: Peer = new Peer((move thief_socket).expect("thief"))
    let thief_hello: string = thief.next()
    r.no("{tag}.4 the thief was given a different circuit",
         hello_id(thief_hello) == id)
    let stolen: bool = thief.send(resume(id))
    let answer: string = thief.next()
    let thief_gone: bool = thief.bye()

    // The positive control, and it is not optional: "the thief was refused"
    // and "a resume never works here" print the same line.
    var back_socket: Result<websocket.Connection> = upgraded(port, mine, "")
    if !back_socket.is_ok() {
        r.yes("{tag}.5 the owner's second handshake completed", false)
        return "{answer} || <no return>"
    }
    let back: Peer = new Peer((move back_socket).expect("back"))
    let back_hello: string = back.next()
    r.yes("{tag}.5 the owner's resume went out", back.send(resume(id)))
    let replayed: string = back.next()
    r.yes("{tag}.6 and it is replayed the very batch it already had",
          replayed == first)
    let back_gone: bool = back.bye()
    return "{answer} || {replayed}"
}

// ============================================================== phase one

fn bound_client(port: int, control: espresso.ServerControl) -> string {
    let r: Report = new Report()

    // ---- 1. the two halves agree on the cookie ---------------------------
    io.println("-- 1. map_pages mints the cookie the endpoint reads")
    let page: string = http_get(port, "/page", "")
    r.eqi("1.1 the page is served", status_of(page), 200)
    let pair: string = set_cookie_pair(page)
    let session: string = cookie_value(pair)
    r.eq("1.2 the cookie is the one latte sets", cookie_name(pair), SESSION_COOKIE)
    r.yes("1.3 its value is 256 random bits in hex",
          session.len() == 64 && is_hex(session))
    // The check that the two-spellings bug could not survive. It compares the
    // socket half's DEFAULT against the name the page half actually wrote on
    // the wire — not two constants in this file.
    let defaults: EndpointOptions = new EndpointOptions()
    r.eq("1.4 and the circuit endpoint's default names that same cookie",
         defaults.session_cookie, cookie_name(pair))
    r.no("1.5 an endpoint does not allow anonymous circuits by default",
         defaults.anonymous_circuits)

    // ---- 2. the refusal, and the control beside it ------------------------
    io.println("")
    io.println("-- 2. a handshake with no session is refused")
    r.eq("2.1 no cookie at all", refused(port, "", ""),
         "403 Forbidden | {NO_SESSION_MESSAGE}")
    var control_socket: Result<websocket.Connection> =
        upgraded(port, "{SESSION_COOKIE}={session}", "")
    r.yes("2.2 the SAME handshake carrying the session is upgraded",
          control_socket.is_ok())
    if control_socket.is_ok() {
        let peer: Peer = new Peer((move control_socket).expect("control"))
        let greeting: string = peer.next()
        r.yes("2.3 and the circuit says hello",
              greeting.starts_with("\{\"t\":\"hello\",\"v\":1,"))
        let gone: bool = peer.bye()
    } else {
        r.yes("2.3 and the circuit says hello", false)
    }

    // ---- 3. the regression test for the wrong name -----------------------
    io.println("")
    io.println("-- 3. a session under another name is not a session")
    r.eq("3.1 the value latte minted, sent as `sid`", refused(port, "sid={session}", ""),
         "403 Forbidden | {NO_SESSION_MESSAGE}")
    r.eq("3.2 an empty latte_session is refused like an absent one",
         refused(port, "{SESSION_COOKIE}=", ""),
         "403 Forbidden | {NO_SESSION_MESSAGE}")

    // ---- 4. two refusals, not one ----------------------------------------
    //
    // Each is shown with the other's condition satisfied, so neither can be
    // standing in front of the other and answering for it.
    io.println("")
    io.println("-- 4. Origin and session refuse separately")
    r.eq("4.1 a good session from an origin the endpoint does not know",
         refused(port, "{SESSION_COOKIE}={session}", "https://evil.example"),
         "403 Forbidden | this origin may not open a circuit")
    r.eq("4.2 no session, from an origin that IS allowed",
         refused(port, "", "http://127.0.0.1:{port}"),
         "403 Forbidden | {NO_SESSION_MESSAGE}")
    var both: Result<websocket.Connection> =
        upgraded(port, "{SESSION_COOKIE}={session}", "http://127.0.0.1:{port}")
    r.yes("4.3 and both together are upgraded", both.is_ok())
    if both.is_ok() {
        let peer: Peer = new Peer((move both).expect("both"))
        let greeting: string = peer.next()
        let gone: bool = peer.bye()
    }

    // ---- 5. the steal, over sockets --------------------------------------
    io.println("")
    io.println("-- 5. one session's circuit id is worth nothing to another")
    let second: string = http_get(port, "/page", "")
    let other: string = cookie_value(set_cookie_pair(second))
    r.no("5.0 the second visitor got a different session", other == session)
    let outcome: string = steal(r, port, "5",
                                "{SESSION_COOKIE}={session}",
                                "{SESSION_COOKIE}={other}")
    match outcome.find(" || ") {
        none => { r.eq("5.7 the thief was told why", outcome, "<no split>") }
        some(at) => {
            r.eq("5.7 the thief was told why", outcome.slice(0, at),
                 "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"the circuit id does not match this connection\"\}")
        }
    }

    let stopped: bool = control.stop().or(false)
    return "{r.checks} checks, {r.bad} bad"
}

// ============================================================== phase two

fn anonymous_client(port: int, control: espresso.ServerControl) -> string {
    let r: Report = new Report()

    io.println("-- 6. what anonymous_circuits costs, asserted rather than described")
    r.eq("6.0 a handshake with no cookie is accepted here",
         "{upgraded(port, "", "").is_ok()}", "true")
    let outcome: string = steal(r, port, "6", "", "")
    match outcome.find(" || ") {
        none => { r.eq("6.7 the thief was handed the page", outcome, "<no split>") }
        some(at) => {
            let taken: string = outcome.slice(0, at)
            // The theft SUCCEEDS: with every anonymous client holding the same
            // `""` identity, `adopt` compares `"" != ""`, moves the socket, and
            // replays a stranger's mounted page onto it. This line is the
            // reason the option defaults to false.
            r.yes("6.7 the thief was handed the owner's own batch 1",
                  taken.starts_with("\{\"t\":\"batch\",\"b\":1,") && taken.contains("tiny"))
        }
    }

    let stopped: bool = control.stop().or(false)
    return "{r.checks} checks, {r.bad} bad"
}

// ============================================================== the run

fn make_set() -> CircuitSet {
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            if url != "/tiny" { return none }
            return some(new Tiny())
        })
    set.guard = run
    return set
}

fn seam_of(set: CircuitSet) -> CircuitSeam {
    return new CircuitSeam(
        set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
        set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
        set.wake_fn())
}

fn main() {
    io.println("websocket bridge {websocket.available()}")
    io.println("fiber poller {has_fiber_poller()}")
    io.println("")

    // ---------------- phase one: sessions required (the default) ----------
    let bound_set: CircuitSet = make_set()
    var endpoint: EndpointOptions = new EndpointOptions()
    endpoint.poll_ms = 100
    endpoint.socket_ms = 30000
    endpoint.origins = ["http://127.0.0.1:0"]
    endpoint.no_poller_message = NO_POLLER_MESSAGE

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    map_pages(app, page_reply, false).expect("pages")
    map_circuit(app, "/_latte/ws", seam_of(bound_set), endpoint).expect("circuit")

    var server_options: espresso.ServerOptions = new espresso.ServerOptions()
    server_options.port = 0
    server_options.poll_timeout_ms = 50
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, server_options).expect("server")
    let port: int = server.port().expect("port")
    // The allowed origin can only be written once the kernel has chosen the
    // port, and `origins` is read on every handshake, so setting it here is
    // what makes § 4's pair a pair.
    endpoint.origins = ["http://127.0.0.1:{port}"]
    let control: espresso.ServerControl = server.control()
    let visitor: Thread<string> = thread.spawn(fn() -> string {
        return bound_client(port, control)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println("")
    io.println(visitor.join())
    // Decided, not read off a run. `stats.upgrades` counts every hand-off to
    // an `UpgradeHandler` — refused or not (`espresso/server.b:1205`) — and
    // this phase makes TEN of them: five that must be refused (2.1, 3.1, 3.2,
    // 4.1, 4.2) and five that must be upgraded (2.2, 4.3, and the owner, the
    // thief and the owner's return in § 5). Five circuits are opened by those
    // five upgrades and the owner's returning socket is adopted onto the
    // circuit it already had, which retires the fresh one it arrived on — so
    // four are still held. The single fault is `adopt` refusing the thief, and
    // it is the whole point of the phase: a run where every check above passes
    // and this says 0 is a run where nothing was refused.
    let tally: Report = new Report()
    tally.eqi("A. ten handshakes reached the endpoint", stats.upgrades, 10)
    tally.eqi("B. five of them became circuits, one of which was adopted away",
              bound_set.count(), 4)
    tally.eq("C. and adopt refused exactly one resume",
             bound_set.faults.join(" | "),
             "a resume named a circuit that belongs to another session")

    // ---------------- phase two: the option, and what it costs ------------
    io.println("")
    let open_set: CircuitSet = make_set()
    var loose: EndpointOptions = new EndpointOptions()
    loose.poll_ms = 100
    loose.socket_ms = 30000
    loose.anonymous_circuits = true
    loose.no_poller_message = NO_POLLER_MESSAGE

    let second_builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let second_app: espresso.WebApplication = second_builder.build().expect("app")
    map_circuit(second_app, "/_latte/ws", seam_of(open_set), loose).expect("circuit")

    var second_options: espresso.ServerOptions = new espresso.ServerOptions()
    second_options.port = 0
    second_options.poll_timeout_ms = 50
    let second_server: espresso.WebServer =
        espresso.WebServer.bind(second_app, second_options).expect("server")
    let second_port: int = second_server.port().expect("port")
    let second_control: espresso.ServerControl = second_server.control()
    let second_visitor: Thread<string> = thread.spawn(fn() -> string {
        return anonymous_client(second_port, second_control)
    })
    let second_stats: espresso.ServerStats = second_server.run().expect("run")
    io.println("")
    io.println(second_visitor.join())
    // Four hand-offs, none refused: 6.0's throwaway plus the owner, the thief
    // and the owner's return. Two circuits survive — 6.0's and the owner's —
    // because BOTH the thief's and the owner's fresh circuits were adopted
    // away onto the owner's. And `faults` is empty, which is the finding: the
    // one control that stands between two clients never ran.
    let loose_tally: Report = new Report()
    loose_tally.eqi("D. four handshakes reached the endpoint",
                    second_stats.upgrades, 4)
    loose_tally.eqi("E. two circuits survive, both adoptions having landed on one",
                    open_set.count(), 2)
    loose_tally.eqi("F. and NOTHING was refused — the session control never ran",
                    open_set.faults.len(), 0)
}
