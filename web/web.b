// `latte.web` — the socket half of a circuit.
//
// This is the only package under `latte/` that knows there is a network. It
// owns the WebSocket handshake, the three fibers a live circuit needs, and the
// rule that keeps the frame stream intact: **one fiber writes.**
//
// It cannot name a single type in `circuit.b`. A package under `latte/` may
// not import its own module root (`error: a package cannot import its own
// module root`), so everything it drives arrives as closures over std types —
// `int`, `string`, `bool`, `List<string>`, `Map<string, string>` and
// `Channel<string>`. `CircuitSet` publishes exactly those; `CircuitSeam` below
// is the shape they arrive in, and an application's root file — which may
// import both — is where the two halves meet.
//
// ## The three fibers, and which one writes
//
// `probes/p1_duplex` measured this rather than assuming it, five runs a phase
// on both backends. Reading and writing one `websocket.Connection` from two
// fibers at once is safe and live. **Writing from two fibers is not**: a
// `send_text` that parks inside `flush()` has already pulled its bytes out of
// the framer, so a second fiber's frame lands in the middle of the first
// fiber's half-written frame and the peer reports `protocol`. Phase C failed
// every run.
//
// So:
//
//   * `read_loop` — brewed. Calls `receive()` and nothing else. Every text
//     message becomes one `"c" + text` marker on the wake channel. It never
//     calls `send_text`, `ping`, `pong` or `close`.
//   * `circuit_loop` — the connection fiber, and the ONLY writer. It parks in
//     `wake.receive()`, hands each marker to the circuit, and writes whatever
//     the circuit queued. The `hello`, every batch, every `err`, the `bye` and
//     the close frame all go out from here.
//   * `tick_loop` — brewed. Sleeps `poll_ms` and drops a tick marker. It
//     exists because a `Channel` has no `receive_timeout` and a fiber cannot
//     wait on two channels, and because the idle timeout and the retention
//     sweep need a clock that does not depend on the client sending anything.
//
// `close()` is a write too, so teardown belongs to the connection fiber like
// everything else. Nothing here closes a socket in a `deinit`.
//
// ## Cancellation cannot be used for teardown
//
// `spec/CONCURRENCY.md`: "compiled code's only park site today is join". A
// `cancel()` is therefore not observable at `receive()`, at `wake.receive()`
// or inside `sleep_millis`, and a brewed fiber parked in any of them would
// never see it — while normal scope exit *joins* every child. Both children
// must therefore be able to finish on their own:
//
//   * the ticker wakes every `poll_ms` and checks a flag;
//   * the reader is unstuck by the connection fiber closing the socket, and
//     bounded anyway by the read timeout set on the stream before the
//     handshake.
package web

import espresso
import std.http
import std.net
import std.random
import std.target
import std.time
import std.websocket

// ---------------------------------------------------------------- the markers
//
// These four bytes are the wake alphabet, and they are also `latte`'s
// `WAKE_PUSH` / `WAKE_TICK` / `WAKE_GONE` / `WAKE_MESSAGE`. They are spelled
// twice because neither package may import the other. `tests/circuit_live.b`
// asserts all four pairs are equal, so the drift is a failing test rather than
// a circuit that silently stops waking.

/// A cross-thread poster put a job in the inbox.
pub const WAKE_PUSH: string = "p"
/// The ticker fired.
pub const WAKE_TICK: string = "t"
/// The reader fiber is finished: the socket is gone.
pub const WAKE_GONE: string = "x"
/// A client message, immediately followed by its text.
pub const WAKE_MESSAGE: string = "c"

// ---------------------------------------------------------------- the seam

/// The closures `latte.web` drives a circuit through.
///
/// Every one of these comes off a `CircuitSet` — `open_fn()`, `accept_fn()`
/// and so on. `init` takes all nine because a seam you can half-wire is a seam
/// that fails at run time, in a fiber, with no stack worth reading.
pub class CircuitSeam {
    pub open: fn(Map<string, string>, int) -> int
    pub adopt: fn(int, string, int) -> int
    pub accept: fn(int, string, int) -> List<string>
    pub outbox: fn(int) -> List<string>
    pub tick: fn(int, int) -> List<string>
    pub ending: fn(int) -> bool
    pub disconnect: fn(int, int) -> bool
    pub resume: fn(string, int) -> int
    pub wake: fn(int) -> Channel<string>

    pub fn init(open: fn(Map<string, string>, int) -> int,
                adopt: fn(int, string, int) -> int,
                accept: fn(int, string, int) -> List<string>,
                outbox: fn(int) -> List<string>,
                tick: fn(int, int) -> List<string>,
                ending: fn(int) -> bool,
                disconnect: fn(int, int) -> bool,
                resume: fn(string, int) -> int,
                wake: fn(int) -> Channel<string>) {
        self.open = open
        self.adopt = adopt
        self.accept = accept
        self.outbox = outbox
        self.tick = tick
        self.ending = ending
        self.disconnect = disconnect
        self.resume = resume
        self.wake = wake
    }
}

// ---------------------------------------------------------------- options

pub class EndpointOptions {
    /// Exact `Origin` values a handshake may carry.
    ///
    /// Empty refuses every request that carries one, which is the safe default
    /// for a control that exists to stop cross-site WebSocket hijacking: a
    /// deployment must name its own origin. A request with NO `Origin` header
    /// is allowed, because a browser always sends one — the attack this
    /// defends against is a page in a browser, and a client that sends no
    /// Origin is not one.
    pub origins: List<string> = []

    /// The largest client message the framer will assemble. The circuit has
    /// its own, smaller cap in `CircuitOptions.wire.max_message`; this one is
    /// the wire's, and it is what stops a 2 GB frame being buffered before
    /// anything has looked at it.
    pub max_message: int = 262144

    /// Offer permessage-deflate. It ships in 0.1.40 — `latte` turns it on and
    /// does not implement it.
    pub compress: bool = true

    /// How often the ticker wakes the circuit. It bounds the idle timeout, the
    /// retention sweep and how long teardown waits for the ticker to notice.
    pub poll_ms: int = 250

    /// Read and write deadlines on the socket, in ms.
    ///
    /// A peer that receives the close frame and then neither answers nor hangs
    /// up would otherwise leave the reader fiber parked forever, and normal
    /// scope exit joins it — so the connection fiber would never return. The
    /// deadline is the bound. It must be longer than `poll_ms` and longer than
    /// any gap a healthy client leaves between messages.
    pub socket_ms: int = 300000

    /// The cookie the circuit id is bound to. A reconnect may only pick up a
    /// circuit whose session matches.
    pub session_cookie: string = "sid"

    /// What to answer a handshake on a platform with no fiber network poller.
    /// The host sets it from `latte.NO_POLLER_MESSAGE`; it is not spelled here
    /// because a second copy of a sentence is a second thing to keep in step.
    pub no_poller_message: string = ""

    pub fn init() {}
}

/// Whether this target has a fiber network poller.
///
/// Windows has none: `net_fiber_prepare` is a no-op there, so a socket read
/// holds the worker thread instead of parking the fiber and every circuit past
/// the first waits for the one before it. Static rendering is unaffected.
pub fn has_fiber_poller() -> bool { return target.os() != "windows" }

// ---------------------------------------------------------------- the endpoint

/// The latte side of espresso's `app.map_upgrade(path, handler)`.
///
/// espresso runs the whole middleware pipeline — authentication, cookies, rate
/// limiting — before a handshake reaches here, and if a layer answers instead
/// of calling `next` the socket is never handed over.
pub class CircuitEndpoint implements espresso.UpgradeHandler {
    seam: CircuitSeam
    pub options: EndpointOptions

    pub fn init(seam: CircuitSeam, options: EndpointOptions) {
        self.seam = seam
        self.options = options
    }

    pub fn upgrade(context: espresso.HttpContext,
                   request: http.Request,
                   move stream: net.TcpStream) -> Result<bool> {
        if !has_fiber_poller() {
            return refuse(move stream, 503, "Service Unavailable",
                          self.options.no_poller_message)
        }
        var allowed: bool = true
        var offered: string = ""
        match context.request.headers.get("Origin") {
            some(value) => {
                offered = value
                allowed = false
                for known: string in self.options.origins {
                    if known == value { allowed = true }
                }
            }
            none => {}
        }
        if !allowed {
            return refuse(move stream, 403, "Forbidden",
                          "this origin may not open a circuit")
        }
        // Bound both directions before the framer owns the socket. See
        // `EndpointOptions.socket_ms`.
        let timed: Result<bool> =
            stream.set_timeouts(self.options.socket_ms, self.options.socket_ms)
        var facts: Map<string, string> = {}
        facts["id"] = fresh_id()?
        facts["session"] = context.request.cookie(self.options.session_cookie).or("")
        facts["origin"] = offered
        facts["path"] = context.request.path
        let socket: websocket.Connection = websocket.Connection.accept(
            move stream, request, self.options.max_message,
            self.options.compress)?
        return ok(serve(socket, self.seam, self.options, facts))
    }
}

/// Register a circuit endpoint on an espresso application.
pub fn map_circuit(app: espresso.WebApplication, path: string,
                   seam: CircuitSeam,
                   options: EndpointOptions) -> Result<bool> {
    return app.map_upgrade(path, new CircuitEndpoint(seam, options))
}

// ---------------------------------------------------------------- refusals

/// Answer a handshake that must not become a circuit, and close.
///
/// The socket has already been handed over, so espresso will not write a
/// response for us — this is the whole answer, head and body.
fn refuse(move stream: net.TcpStream, status: int, phrase: string,
          body: string) -> Result<bool> {
    let head: string =
        "HTTP/1.1 {status} {phrase}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {body.len()}\r\nConnection: close\r\n\r\n"
    let wrote: Result<int> = stream.write_text("{head}{body}")
    let closed: Result<bool> = stream.close()
    return ok(false)
}

// ---------------------------------------------------------------- ids

/// 256 bits from the CSPRNG as 64 hex characters.
///
/// Hex rather than base64 because the id crosses JSON, an HTML attribute and a
/// log line, and a `+` or a `/` in any of those is one more escaping question
/// for no gain. `CircuitSet.open` refuses anything under 16 characters.
pub fn fresh_id() -> Result<string> {
    let raw: Bytes = random.bytes(32)?
    let digits: string = "0123456789abcdef"
    var out: string = ""
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        out = "{out}{digits.slice(byte / 16, byte / 16 + 1)}{digits.slice(byte % 16, byte % 16 + 1)}"
    }
    return ok(out)
}

// ---------------------------------------------------------------- the link
//
// Shared by the connection fiber and the two it brews. They sit on one worker
// and interleave only at park points, so plain fields are enough; no other OS
// thread touches this.

class Link {
    /// Set by the connection fiber when it is finished. The ticker checks it
    /// after every sleep, which is the only reason the ticker ever stops.
    pub done: bool = false
    /// Set by the reader when `receive()` said the socket is finished. The
    /// connection fiber reads it on every wake, so it learns even when the
    /// `x` marker could not be queued.
    pub reader_done: bool = false
    /// The read error's kind, for a host that wants it. Empty on a clean end.
    pub reader_error: string = ""
    pub messages: int = 0
    pub ticks: int = 0
    pub fn init() {}
}

// ---------------------------------------------------------------- the fibers

/// The reader. It calls `receive()` and NOTHING else — see the header.
fn read_loop(socket: websocket.Connection, wake: Channel<string>,
             link: Link) -> int {
    var seen: int = 0
    for !link.done {
        match socket.receive() {
            ok(maybe) => {
                match maybe {
                    some(message) => {
                        match message {
                            text(body) => {
                                seen += 1
                                link.messages = seen
                                // A blocking send is the backpressure: a
                                // client that floods stops being read, and
                                // TCP tells it so. `try_send` here would drop
                                // the message instead.
                                wake.send("{WAKE_MESSAGE}{body}")
                            }
                            binary(data) => {
                                // Wire v1 is text. A binary frame is not a
                                // message this end can read, and pretending
                                // otherwise would hand the circuit bytes it
                                // would then have to guess about.
                                link.reader_error = "binary"
                                link.done = true
                            }
                            ping(data) => {}
                            pong(data) => {}
                            closed(code, reason) => { link.done = true }
                        }
                    }
                    none => { link.done = true }
                }
            }
            err(problem) => {
                link.reader_error = problem.kind
                link.done = true
            }
        }
    }
    link.reader_done = true
    // Never a blocking send: the connection fiber may already have stopped
    // reading, and a reader parked here would never be joined.
    let queued: bool = wake.try_send(WAKE_GONE)
    return seen
}

/// The ticker. `try_send` so it can never park, and a flag so it can never
/// outlive the connection by more than one `poll_ms`.
fn tick_loop(wake: Channel<string>, link: Link, poll_ms: int) -> int {
    var ticks: int = 0
    for !link.done {
        time.sleep_millis(poll_ms)
        if link.done { break }
        let queued: bool = wake.try_send(WAKE_TICK)
        ticks += 1
        link.ticks = ticks
    }
    return ticks
}

/// Everything that reaches the wire goes through here, on one fiber.
fn write_frames(socket: websocket.Connection, frames: List<string>) -> bool {
    for frame: string in frames {
        match socket.send_text(frame) {
            ok(sent) => {}
            err(problem) => { return false }
        }
    }
    return true
}

/// The connection fiber's loop. It parks on the wake channel and writes.
fn circuit_loop(socket: websocket.Connection, handle: int,
                wake: Channel<string>, link: Link, seam: CircuitSeam) -> bool {
    var clean: bool = true
    var live: bool = true
    for live {
        // `none` means the channel is closed and empty, which the circuit that
        // owns it never does — but reading it as "the socket is finished" is
        // the only answer that cannot spin.
        var marker: string = WAKE_GONE
        match wake.receive() {
            some(queued) => { marker = queued }
            none => { marker = WAKE_GONE }
        }
        let now_ms: int = time.monotonic_millis()
        if marker == WAKE_GONE || link.reader_done {
            // Drain whatever the reader queued before it died: those messages
            // arrived and the circuit is entitled to them. Nothing is written
            // for them — the socket is gone — but an event that mutated state
            // must still have mutated it, or a resume would replay a page the
            // client had already changed.
            var pending: Option<string> = wake.try_receive()
            for pending.is_some() {
                match pending {
                    some(queued) => {
                        if queued.starts_with(WAKE_MESSAGE) {
                            let dropped: List<string> = seam.accept(
                                handle, queued.slice(1, queued.len()), now_ms)
                        }
                    }
                    none => {}
                }
                pending = wake.try_receive()
            }
            return true
        }
        var frames: List<string> = []
        if marker.starts_with(WAKE_MESSAGE) {
            frames = seam.accept(handle, marker.slice(1, marker.len()), now_ms)
        } else {
            // A tick, or a cross-thread poster's marker. `tick` drains the
            // inbox and settles whatever is pending either way, which is why a
            // dropped `p` marker costs nothing: the next tick does the work.
            frames = seam.tick(handle, now_ms)
        }
        if !write_frames(socket, frames) { return false }
        if seam.ending(handle) { live = false }
    }
    return clean
}

/// One circuit, from `hello` to teardown. The `brew`s live here because a
/// `brew` is refused inside a nested block and must sit at its function's own
/// scope.
fn serve(socket: websocket.Connection, seam: CircuitSeam,
         options: EndpointOptions, facts: Map<string, string>) -> bool {
    let opened_ms: int = time.monotonic_millis()
    let open: fn(Map<string, string>, int) -> int = seam.open
    var handle: int = open(facts, opened_ms)
    if handle < 0 {
        let farewell: Result<bool> = socket.close(1013, "no circuit")
        return false
    }

    // The `hello`, queued by `open`.
    let greeting: fn(int) -> List<string> = seam.outbox
    if !write_frames(socket, greeting(handle)) {
        let farewell: Result<bool> = socket.close(1011, "write failed")
        return false
    }

    // The first message is read on THIS fiber, before the reader exists,
    // because it is the one message that can move the socket to another
    // circuit — and the reader and the ticker are bound to the wake channel of
    // whichever circuit that turns out to be.
    var first: string = ""
    var alive: bool = false
    match socket.receive() {
        ok(maybe) => {
            match maybe {
                some(message) => {
                    match message {
                        text(body) => { first = body; alive = true }
                        binary(data) => {}
                        ping(data) => {}
                        pong(data) => {}
                        closed(code, reason) => {}
                    }
                }
                none => {}
            }
        }
        err(problem) => {}
    }
    if !alive {
        let dropped: fn(int, int) -> bool = seam.disconnect
        let kept: bool = dropped(handle, time.monotonic_millis())
        let farewell: Result<bool> = socket.close(1001, "no attach")
        return false
    }

    let adopt: fn(int, string, int) -> int = seam.adopt
    handle = adopt(handle, first, time.monotonic_millis())
    let accept: fn(int, string, int) -> List<string> = seam.accept
    if !write_frames(socket, accept(handle, first, time.monotonic_millis())) {
        let farewell: Result<bool> = socket.close(1011, "write failed")
        return false
    }
    let ending: fn(int) -> bool = seam.ending
    if ending(handle) {
        let farewell: Result<bool> = socket.close(1000, "circuit ended")
        return true
    }

    let wake_of: fn(int) -> Channel<string> = seam.wake
    let wake: Channel<string> = wake_of(handle)
    let link: Link = new Link()
    let reader: Brew<int> = brew read_loop(socket, wake, link)
    let ticker: Brew<int> = brew tick_loop(wake, link, options.poll_ms)

    let clean: bool = circuit_loop(socket, handle, wake, link, seam)

    // Teardown, in the one order that cannot deadlock.
    //
    //  1. the flag, so the ticker stops after at most one more sleep;
    //  2. drain the wake channel, so a reader parked in `wake.send` completes
    //     and then sees the flag — cancellation would NOT reach it;
    //  3. the close frame, which unsticks a reader parked in `receive()`. It
    //     is a write, so it belongs to this fiber and to no other;
    //  4. drain again, for anything the reader queued on its way out;
    //  5. join, which the scope would do at exit anyway.
    link.done = true
    var pending: Option<string> = wake.try_receive()
    for pending.is_some() { pending = wake.try_receive() }
    let farewell: Result<bool> = socket.close(if clean { 1000 } else { 1011 },
                                              if clean { "done" } else { "failed" })
    pending = wake.try_receive()
    for pending.is_some() { pending = wake.try_receive() }
    let read_count: Result<int> = reader.join()
    let tick_count: Result<int> = ticker.join()

    // The socket is gone; the circuit is retained so a reconnect can replay.
    let dropped: fn(int, int) -> bool = seam.disconnect
    let kept: bool = dropped(handle, time.monotonic_millis())
    return clean
}
