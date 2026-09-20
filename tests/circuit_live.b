// tests/circuit_live.b — the circuit, over a REAL SERVER on a REAL SOCKET.
//
// Everything else in this repo is Beans talking to Beans, or a browser talking
// to a fixture file. This is the one suite where bytes cross a TCP connection:
// an espresso application on **port 0**, a `latte.web` circuit endpoint on it,
// and a `std.websocket` client on its own OS thread that attaches, clicks,
// binds, reorders a keyed list, trips a contained panic, watches a value cross
// an OS thread boundary and land in a batch, drops the socket, comes back and
// is replayed.
//
// Three rules shape it, and each one is a bug this workspace has already paid
// for:
//
//   * **Port 0, never a fixed port.** A fixed port is a false green when
//     something else is listening and a false red on a busy machine.
//   * **Never assert a read boundary.** The 101 head and the frame behind it
//     arrive in ONE TCP segment natively and TWO under the interpreter.
//     Nothing here counts bytes or reads a fixed number of them: every read
//     is one WebSocket message through the framer.
//   * **The client is an OS thread, not a fiber.** Windows has no fiber
//     network poller, so a fiber peer deadlocks there and the leg times out
//     with nothing printed.
//
// **What makes this byte-deterministic.** The port is never printed. The
// circuit id is 256 random bits, so it is never printed either — what is
// printed is its shape (64 hex characters) and the answers to questions about
// it. Everything else on the wire is a function of the page and the messages,
// and every message this client sends it sends only after reading the answer
// to the one before, so no two frames can race. Timing appears nowhere.
package main

import github.com/beans-lang/espresso
import std.io
import std.net
import std.thread
import std.websocket
import {Builder, Circuit, CircuitOptions, CircuitSet, Component, ErrorBoundary,
        InputEvent, MouseEvent, Push, WAKE_GONE, WAKE_MESSAGE, WAKE_PUSH,
        WAKE_TICK, NO_POLLER_MESSAGE} from latte
import {run} from latte.boundary
import {CircuitEndpoint, CircuitSeam, EndpointOptions, has_fiber_poller,
        map_circuit} from latte.web

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

/// One page with every shape check 7 names: a click, a bound input, a keyed
/// list that MOVES rather than rebuilds, a paragraph a cross-thread job
/// writes, and a handler that panics.
pub class Board extends Component {
    pub count: int = 0
    pub name: string = ""
    pub rows: List<string> = ["a", "b", "c"]
    pub pushed: int = 0

    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "board")

        b.open(2, "button")
        b.on_click(3, fn(e: MouseEvent) { self.count += 1 })
        b.text(4, "Count: {self.count}")
        b.close()

        b.open(5, "input")
        b.attr(6, "value", self.name)
        b.on_input(7, fn(e: InputEvent) { self.name = e.value })
        b.close()

        b.open(8, "button")
        b.on_click(9, fn(e: MouseEvent) { self.rotate() })
        b.text(10, "rotate")
        b.close()

        b.open(11, "ul")
        for row: string in self.rows {
            b.region(12, row)
            b.open(0, "li")
            b.text(1, row)
            b.close()
            b.end_region()
        }
        b.close()

        b.open(13, "p")
        b.text(14, "pushed {self.pushed} for {self.name} rows {self.rows.join(",")}")
        b.close()

        b.open(15, "button")
        b.on_click(16, fn(e: MouseEvent) { panic("the live handler blew up") })
        b.text(17, "boom")
        b.close()

        b.close()
    }

    /// First row to the back. Three keys in, three keys out, all still there —
    /// so a differ that rebuilt the list instead of moving one child would
    /// produce different edits and the expected output would say so.
    fn rotate() {
        var next: List<string> = []
        for index: int in 1..self.rows.len() { next.push(self.rows[index]) }
        next.push(self.rows[0])
        self.rows = move next
    }
}

/// The boundary the panic lands in. Without one the circuit ENDS, which is
/// § 5's control in `tests/circuit.b`; here the point is that a live socket
/// survives a handler that blew up.
pub class Shell extends ErrorBoundary {
    pub inner: Board = new Board()
    pub fn init() {
        super.init()
        self.body = fn(b: Builder) {
            b.component_made<Board>(0, fn() -> Board { return self.inner },
                                    fn(c: Board) {})
        }
    }
}

// ============================================================== the wiring
//
// `CircuitSet.init` takes the page factory, and the factory wants the set — so
// one of them has to be filled in afterwards. This holder is that
// afterwards, and it is also where the server records what only the server can
// see: how many circuits it opened, and whether the cross-thread post was
// taken.

pub class Wiring {
    pub set: Option<CircuitSet> = none
    pub pages: int = 0
    pub posted: bool = false
    pub last: Option<Shell> = none
    pub fn init() {}
}

/// Build the page, and — this is the cross-thread half of check 7 — hand a
/// `Push` to a REAL OS thread which posts a job back into the circuit's inbox.
///
/// `Push` is `unique … implements Send`, so it is moved into the thread's
/// closure. The job it posts is a `send fn(Circuit)`; it runs later, on the
/// circuit's own fiber, against state the posting thread never had a reference
/// to. The join is what makes the ordering a fact rather than a hope: by the
/// time this returns, the job is in the inbox and the `p` marker is in the
/// wake channel, so the batch it produces is the one after the page's.
fn make_page(wiring: Wiring, facts: Map<string, string>,
             url: string) -> Option<Component> {
    if url != "/board" { return none }
    let page: Shell = new Shell()
    wiring.pages += 1
    wiring.last = some(page)
    var id: string = ""
    match facts.get("id") { some(value) => { id = value } none => {} }
    match wiring.set {
        some(holder) => {
            match holder.circuit(holder.handle_for(id)) {
                some(live) => {
                    let handle: Push = live.push_handle()
                    let poster: Thread<bool> = thread.spawn(fn() move(handle) -> bool {
                        return handle.post(fn(c: Circuit) {
                            match c.page_component() {
                                some(component) => {
                                    match component as? Shell {
                                        some(shell) => {
                                            shell.inner.pushed += 1
                                            shell.inner.notify()
                                        }
                                        none => {}
                                    }
                                }
                                none => {}
                            }
                        })
                    })
                    wiring.posted = poster.join()
                }
                none => {}
            }
        }
        none => {}
    }
    return some(page)
}

// ============================================================== the client
//
// A real OS thread. It reads one WebSocket MESSAGE at a time through the
// framer, so nothing here depends on how the kernel split the bytes.

class Peer {
    socket: websocket.Connection
    pub lines: List<string> = []

    fn init(move socket: websocket.Connection) { self.socket = move socket }

    /// The next text message, or a word saying what came instead. Never a byte
    /// count, never a fixed number of reads.
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

/// The `c` field of a `hello`, without believing anything else about it.
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

fn is_hex(text: string) -> bool {
    if text.len() == 0 { return false }
    let digits: string = "0123456789abcdef"
    for index: int in 0..text.len() {
        if digits.find(text.slice(index, index + 1)).is_none() { return false }
    }
    return true
}

/// `{"t":"batch","b":N,...}` → N, and -1 for anything else.
fn batch_number(frame: string) -> int {
    let marker: string = "\"t\":\"batch\",\"b\":"
    match frame.find(marker) {
        none => { return -1 }
        some(at) => {
            let rest: string = frame.slice(at + marker.len(), frame.len())
            match rest.find(",") {
                none => { return -1 }
                some(end) => { return rest.slice(0, end).to_int().or(-1) }
            }
        }
    }
}

fn click(handler: int) -> string {
    return "\{\"t\":\"ev\",\"h\":{handler},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":4,\"y\":9\}\}"
}

fn typed(handler: int, value: string) -> string {
    return "\{\"t\":\"ev\",\"h\":{handler},\"k\":\"input\",\"p\":\{\"v\":\"{value}\",\"c\":false\}\}"
}

fn ack(number: int) -> string { return "\{\"t\":\"ack\",\"b\":{number}\}" }

// ============================================================== the run

fn client(port: int, control: espresso.ServerControl) -> string {
    let r: Report = new Report()

    // ---- 1. the handshake -------------------------------------------------
    io.println("-- 1. a real socket, on a port the kernel chose")
    var dialled: Result<websocket.Connection> =
        websocket.Connection.connect_timeout("127.0.0.1", port, "/_latte/ws",
                                             10000, true)
    if !dialled.is_ok() {
        io.println("FAIL 1.0 the handshake did not complete")
        let stopped: bool = control.stop().or(false)
        return "1 check, 1 bad"
    }
    var opened: websocket.Connection = (move dialled).expect("handshake")
    let peer: Peer = new Peer(move opened)

    let hello: string = peer.next()
    let circuit_id: string = hello_id(hello)
    r.eq("1.1 the first frame is a hello at wire v1",
         hello.replace(circuit_id, "<id>"),
         "\{\"t\":\"hello\",\"v\":1,\"c\":\"<id>\",\"mx\":65536\}")
    r.eqi("1.2 the circuit id is 256 bits", circuit_id.len(), 64)
    r.yes("1.3 and hexadecimal", is_hex(circuit_id))

    // ---- 2. attach --------------------------------------------------------
    io.println("")
    io.println("-- 2. attach mounts the page and sends batch 1")
    r.yes("2.1 the attach went out",
          peer.send("\{\"t\":\"attach\",\"c\":\"{circuit_id}\",\"u\":\"/board\"\}"))
    let first: string = peer.next()
    r.eq("2.2 batch 1 is the whole page", first, PAGE_BATCH)
    r.yes("2.3 the ack went out", peer.send(ack(1)))

    // ---- 3. the cross-thread push ----------------------------------------
    io.println("")
    io.println("-- 3. a job posted from another OS thread reaches the wire")
    let pushed: string = peer.next()
    r.eq("3.1 batch 2 is the pushed value, and nothing else", pushed,
         "\{\"t\":\"batch\",\"b\":2,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"si\",4],[\"ut\",0,\"pushed 1 for  rows a,b,c\"],[\"so\"],[\"so\"]]\}],\"d\":[]\}")
    r.yes("3.2 the ack went out", peer.send(ack(2)))

    // ---- 4. a click -------------------------------------------------------
    io.println("")
    io.println("-- 4. a click is one text edit, not a page")
    r.yes("4.1 the click went out", peer.send(click(2)))
    // Two `si` and not one: the Board renders a wrapper `<div>`, so the
    // button is child 0 of child 0. Count them against `Board.render` — the
    // second step-in is the button, not a level the differ invented.
    r.eq("4.2 batch 3 updates one text node", peer.next(),
         "\{\"t\":\"batch\",\"b\":3,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"si\",0],[\"ut\",0,\"Count: 1\"],[\"so\"],[\"so\"]]\}],\"d\":[]\}")
    r.yes("4.3 the ack went out", peer.send(ack(3)))

    // ---- 5. a bind --------------------------------------------------------
    io.println("")
    io.println("-- 5. an input event binds a field")
    r.yes("5.1 the input went out", peer.send(typed(3, "ada")))
    // `si 0` the div, `si 1` the input, its attribute, back out, `si 4` the
    // paragraph, its text. Both edits are inside the scope they belong to and
    // the walk is in child order.
    r.eq("5.2 batch 4 writes the value attribute and the text that reads it",
         peer.next(),
         "\{\"t\":\"batch\",\"b\":4,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"si\",1],[\"sa\",6,\"value\",\"ada\"],[\"so\"],[\"si\",4],[\"ut\",0,\"pushed 1 for ada rows a,b,c\"],[\"so\"],[\"so\"]]\}],\"d\":[]\}")
    r.yes("5.3 the ack went out", peer.send(ack(4)))

    // ---- 6. a keyed move --------------------------------------------------
    io.println("")
    io.println("-- 6. a keyed reorder MOVES a child, it does not rebuild the list")
    r.yes("6.1 the rotate click went out", peer.send(click(4)))
    r.eq("6.2 batch 5 is two relocates and the row-order text", peer.next(), ROTATE_BATCH_5)
    // Twice, because one move can be right by accident on three items.
    r.yes("6.3 a second rotate went out", peer.send(click(4)))
    r.eq("6.4 batch 6 is two relocates again, from a different start", peer.next(), ROTATE_BATCH_6)

    // Deliberately NOT acked: 5 and 6 are what the replay in § 9 must carry.
    io.println("(batches 5 and 6 are left un-acked on purpose)")

    // ---- 7. the drop ------------------------------------------------------
    io.println("")
    io.println("-- 7. the socket goes away")
    r.yes("7.1 the close handshake completed", peer.bye())

    // ---- 8. the reconnect -------------------------------------------------
    io.println("")
    io.println("-- 8. a new socket resumes the retained circuit and is replayed")
    var again: Result<websocket.Connection> =
        websocket.Connection.connect_timeout("127.0.0.1", port, "/_latte/ws",
                                             10000, true)
    if !again.is_ok() {
        io.println("FAIL 8.0 the second handshake did not complete")
        let stopped: bool = control.stop().or(false)
        return "{r.checks} checks, {r.bad + 1} bad"
    }
    var reopened: websocket.Connection = (move again).expect("reconnect")
    let back: Peer = new Peer(move reopened)
    let second_hello: string = back.next()
    let second_id: string = hello_id(second_hello)
    r.eqi("8.1 the new socket is a new circuit with its own id",
          second_id.len(), 64)
    r.no("8.2 and it is NOT the one being resumed", second_id == circuit_id)

    // The client asks for the circuit it remembers, not the one it was just
    // offered. Nothing in a WebSocket handshake could have said which circuit
    // this is, so the server can only learn it here — that is what
    // `CircuitSet.adopt` is for.
    r.yes("8.3 the resume went out",
          back.send("\{\"t\":\"resume\",\"c\":\"{circuit_id}\",\"a\":4\}"))
    r.eq("8.4 batch 5 is replayed", back.next(), ROTATE_BATCH_5)
    r.eq("8.5 batch 6 is replayed", back.next(), ROTATE_BATCH_6)
    r.yes("8.6 the ack for the last replayed batch went out", back.send(ack(6)))

    // ---- 9. the state survived the drop -----------------------------------
    io.println("")
    io.println("-- 9. the page on the other end is the SAME page")
    r.yes("9.1 a click on the same handler id went out", back.send(click(2)))
    r.eq("9.2 the count carried on from where it was", back.next(),
         "\{\"t\":\"batch\",\"b\":7,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"si\",0],[\"ut\",0,\"Count: 2\"],[\"so\"],[\"so\"]]\}],\"d\":[]\}")
    r.yes("9.3 a second bind went out", back.send(typed(3, "bob")))
    // The one line that proves all three: the pushed value crossed a thread,
    // the bound name survived a disconnect, and two rotates left the rows in
    // the order a MOVE would leave them and a rebuild would not.
    r.eq("9.4 pushed, bound and rotated state all came back", back.next(),
         "\{\"t\":\"batch\",\"b\":8,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"si\",1],[\"sa\",6,\"value\",\"bob\"],[\"so\"],[\"si\",4],[\"ut\",0,\"pushed 1 for bob rows c,a,b\"],[\"so\"],[\"so\"]]\}],\"d\":[]\}")
    r.yes("9.5 the ack went out", back.send(ack(8)))

    // ---- 10. a contained panic --------------------------------------------
    io.println("")
    io.println("-- 10. a handler panics and the circuit lives")
    r.yes("10.1 the boom click went out", back.send(click(5)))
    r.eq("10.2 what the client is told is a trace id, never the message",
         back.next(), "\{\"t\":\"err\",\"k\":\"panic\",\"m\":\"t1\"\}")
    r.eq("10.3 the boundary renders in its place", back.next(),
         "\{\"t\":\"batch\",\"b\":9,\"r\":[[\"b\",0,true],[\"o\",0,\"div\"],[\"a\",1,\"class\",\"latte-error\"],[\"t\",2,\"Something went wrong.\"],[\"z\"],[\"B\"]],\"u\":[\{\"c\":0,\"e\":[[\"rm\",0],[\"in\",0,0]]\}],\"d\":[1]\}")

    // ---- 11. a limit ends the circuit with a bye, never a panic ----------
    io.println("")
    io.println("-- 11. a message the wire refuses ends the circuit politely")
    r.yes("11.1 a nonsense event name went out",
          back.send("\{\"t\":\"ev\",\"h\":1,\"k\":\"telepathy\",\"p\":\{\}\}"))
    r.eq("11.2 the last frame is a bye", back.next(),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"unknown event name\"\}")
    r.eq("11.3 and the socket is finished", back.next(), "<closed 1000>")

    // ---- 12. the controls beside § 8 --------------------------------------
    //
    // § 8 would look exactly the same if `resume` always worked, so these two
    // are the inputs adoption must NOT honour. Both are on their own fresh
    // socket, and each answers with one frame and ends.
    io.println("")
    io.println("-- 12. what adoption refuses")
    r.eq("12.1 a resume naming a circuit that does not exist is forbidden",
         one_shot(port, "\{\"t\":\"resume\",\"c\":\"{DEAD_ID}\",\"a\":0\}", ""),
         "\{\"t\":\"bye\",\"k\":\"forbidden\",\"m\":\"the circuit id does not match this connection\"\}")
    r.eq("12.2 a resume of THIS socket's own fresh circuit never attached",
         one_shot(port, "", "resume"),
         "\{\"t\":\"bye\",\"k\":\"protocol\",\"m\":\"resume on a circuit that never attached\"\}")
    // The positive control: the same fresh socket, attached instead of
    // resumed, is served. Without it "refused" cannot be told from "the
    // handshake was broken all along".
    r.yes("12.3 and the same fresh socket attaches fine",
          one_shot(port, "", "attach").starts_with("\{\"t\":\"batch\",\"b\":1,"))

    let stopped: bool = control.stop().or(false)
    return "{r.checks} checks, {r.bad} bad"
}

/// A circuit id that is well-formed and belongs to nobody.
const DEAD_ID: string =
    "00000000000000000000000000000000000000000000000000000000deadbeef"
const OTHER_ID: string =
    "11111111111111111111111111111111111111111111111111111111deadbeef"
const THIRD_ID: string =
    "22222222222222222222222222222222222222222222222222222222deadbeef"

/// Batch 5 and batch 6: two rotations of a three-key list.
///
/// Each is **two relocates inside the `<ul>` and one text edit for the `<p>`
/// that prints the row order**, and nothing else. A differ that dropped the
/// list and built a new one would send three removes and three inserts here,
/// which is the thing this row exists to refuse.
///
/// **Two moves and not one, on purpose.** `rotate()` sends the FIRST row to
/// the back, which is a rotate-LEFT, and `diff.b`'s keyed pass costs n-1 moves
/// for that and one move for a rotate-right — it scans forward from the
/// current position rather than running a longest-increasing-subsequence pass.
/// That asymmetry is written down at `diff.b`'s `keyed`, and `tests/diff.b`
/// already checks BOTH numbers exactly ("rotate left (9 edits)" / "rotate right
/// (5 edits)"), so it is a decision with an expected output and not a bug this suite
/// would be blessing. What this suite adds is that the moves survive a socket
/// and a replay.
const ROTATE_BATCH_5: string =
    "\{\"t\":\"batch\",\"b\":5,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"si\",3],[\"mv\",1,0],[\"mv\",2,1],[\"so\"],[\"si\",4],[\"ut\",0,\"pushed 1 for ada rows b,c,a\"],[\"so\"],[\"so\"]]\}],\"d\":[]\}"
const ROTATE_BATCH_6: string =
    "\{\"t\":\"batch\",\"b\":6,\"r\":[],\"u\":[\{\"c\":1,\"e\":[[\"si\",0],[\"si\",3],[\"mv\",1,0],[\"mv\",2,1],[\"so\"],[\"si\",4],[\"ut\",0,\"pushed 1 for ada rows c,a,b\"],[\"so\"],[\"so\"]]\}],\"d\":[]\}"

/// One fresh socket, one message, one answer, then gone.
///
/// `kind` is `"resume"` or `"attach"` when the message must name the id THIS
/// connection was just given; otherwise `first` is sent as written.
fn one_shot(port: int, first: string, kind: string) -> string {
    var dialled: Result<websocket.Connection> =
        websocket.Connection.connect_timeout("127.0.0.1", port, "/_latte/ws",
                                             10000, true)
    if !dialled.is_ok() { return "<no handshake>" }
    var opened: websocket.Connection = (move dialled).expect("one-shot")
    let peer: Peer = new Peer(move opened)
    let hello: string = peer.next()
    let id: string = hello_id(hello)
    var text: string = first
    if kind == "resume" { text = "\{\"t\":\"resume\",\"c\":\"{id}\",\"a\":0\}" }
    if kind == "attach" { text = "\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"/board\"\}" }
    if !peer.send(text) { return "<send failed>" }
    let answer: string = peer.next()
    let gone: bool = peer.bye()
    return answer
}

/// Batch 1, the whole page. It is spelled out rather than summarised because
/// the handler ids this suite then clicks — 1, 2, 3, 4 — are only true if this
/// is exactly what went out.
const PAGE_BATCH: string =
    "\{\"t\":\"batch\",\"b\":1,\"r\":[[\"b\",0,false],[\"p\",1],[\"c\",0,\"Board\",1],[\"P\"],[\"B\"],[\"o\",0,\"div\"],[\"a\",1,\"id\",\"board\"],[\"o\",2,\"button\"],[\"h\",3,\"click\",2],[\"t\",4,\"Count: 0\"],[\"z\"],[\"o\",5,\"input\"],[\"a\",6,\"value\",\"\"],[\"h\",7,\"input\",3],[\"z\"],[\"o\",8,\"button\"],[\"h\",9,\"click\",4],[\"t\",10,\"rotate\"],[\"z\"],[\"o\",11,\"ul\"],[\"g\",12,\"a\"],[\"o\",0,\"li\"],[\"t\",1,\"a\"],[\"z\"],[\"G\"],[\"g\",12,\"b\"],[\"o\",0,\"li\"],[\"t\",1,\"b\"],[\"z\"],[\"G\"],[\"g\",12,\"c\"],[\"o\",0,\"li\"],[\"t\",1,\"c\"],[\"z\"],[\"G\"],[\"z\"],[\"o\",13,\"p\"],[\"t\",14,\"pushed 0 for  rows a,b,c\"],[\"z\"],[\"o\",15,\"button\"],[\"h\",16,\"click\",5],[\"t\",17,\"boom\"],[\"z\"],[\"z\"]],\"u\":[\{\"c\":0,\"e\":[[\"in\",0,0]]\},\{\"c\":1,\"e\":[[\"in\",0,5]]\}],\"d\":[]\}"

/// § 13 — the control the socket cannot reach.
///
/// `adopt` refuses to hand a socket a circuit that belongs to another session,
/// and that is the whole value of binding a circuit id to a session: a stolen
/// id buys nothing. No client this suite can build reaches it, because
/// `websocket.Connection.connect` cannot set a `Cookie` header, so the check is
/// driven directly against a second `CircuitSet` — the same call
/// `latte.web.serve` makes, with the same arguments.
///
/// It is a PAIR. Refused-for-the-right-reason cannot be told from
/// refused-earlier-for-another without the accepted case beside it.
fn session_controls() -> string {
    let r: Report = new Report()
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            if url != "/board" { return none }
            return some(new Shell())
        })

    // One attached circuit, opened for session s1.
    var mine: Map<string, string> = {}
    mine["id"] = DEAD_ID
    mine["session"] = "s1"
    let held: int = set.open(mine, 0)
    let greeting: List<string> = set.outbox(held)
    let mounted: List<string> =
        set.accept(held, "\{\"t\":\"attach\",\"c\":\"{DEAD_ID}\",\"u\":\"/board\"\}", 0)
    r.eqi("13.1 the circuit to be stolen is attached and has a page",
          mounted.len(), 1)

    let resume: string = "\{\"t\":\"resume\",\"c\":\"{DEAD_ID}\",\"a\":0\}"

    // A new socket for a DIFFERENT session presents the id.
    var thief: Map<string, string> = {}
    thief["id"] = OTHER_ID
    thief["session"] = "s2"
    let stolen: int = set.open(thief, 1)
    r.eqi("13.2 a resume from another session does not move the socket",
          set.adopt(stolen, resume, 1), stolen)
    r.eq("13.3 and the set says why", set.faults.join(" | "),
         "a resume named a circuit that belongs to another session")

    // The control: the SAME id, from the session it was issued to, is adopted.
    var owner: Map<string, string> = {}
    owner["id"] = THIRD_ID
    owner["session"] = "s1"
    let coming_back: int = set.open(owner, 2)
    r.eqi("13.4 the same resume from the right session moves the socket",
          set.adopt(coming_back, resume, 2), held)
    r.eqi("13.5 and the fresh circuit it arrived on is retired, not retained",
          set.count(), 2)
    r.eqi("13.6 no second fault was recorded", set.faults.len(), 1)
    return "{r.checks} checks, {r.bad} bad"
}

fn main() {
    io.println("websocket bridge {websocket.available()}")
    io.println("fiber poller {has_fiber_poller()}")

    // The wake alphabet is spelled in two packages that may not import each
    // other. If these ever disagree the circuit stops waking, silently.
    let alphabet: string = "{WAKE_PUSH}{WAKE_TICK}{WAKE_GONE}{WAKE_MESSAGE}"
    io.println("wake alphabet {alphabet} same in latte.web {alphabet == "ptxc"}")

    let wiring: Wiring = new Wiring()
    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            return make_page(wiring, facts, url)
        })
    set.guard = run
    wiring.set = some(set)

    let seam: CircuitSeam = new CircuitSeam(
        set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
        set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
        set.wake_fn())

    // `websocket.Connection.connect` cannot send a `Cookie` header, so no
    // client this suite can build has a session — and since 2026-09-08 an
    // endpoint refuses a handshake it cannot bind to one. This suite is about
    // the circuit, not the binding; `tests/w4_upgrade.b` owns the binding and
    // asserts, in § 5, exactly what this line costs.
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
    server_options.poll_timeout_ms = 50
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
    io.println("-- 13. the session binding, driven without a socket")
    let controls: string = session_controls()
    io.println(controls)
    io.println("")
    io.println("pages built {wiring.pages} cross-thread post taken {wiring.posted}")
    io.println("circuits still held {set.count()} set faults {set.faults.len()}")
    io.println("upgrades {stats.upgrades}")
}
