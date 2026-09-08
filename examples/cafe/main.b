// `examples/cafe/main.b` — a whole latte application, wired the way a person
// would wire one.
//
//     beansc run examples/cafe/main.b -- serve 8080     # open http://127.0.0.1:8080/
//     beansc run examples/cafe/main.b -- check          # what the gate runs
//     beansc run examples/cafe/main.b                   # the same as `check`
//
// Run it from the latte module root: the client script is read from
// `js/latte.js`, relative to the working directory.
//
// **Why the default is `check` and not `serve`.** The examples leg builds and
// RUNS every entry under `examples/` on both backends and diffs stdout against
// a golden. An entry whose default was a listening socket would hang that leg
// for ever the day `main.args` went missing — green, because nothing would
// ever come back to be red. Failing towards the deterministic mode costs a
// person eight characters and cannot silence the gate.
//
// ## What this file is, and what it is not
//
// It is the seam nothing else in this repo has: a served **document** — with a
// doctype, a head, and a `<script src>` that boots a circuit — over a real
// espresso pipeline with latte's own CSP on it. Before it, `map_pages`
// answered a page *body*, no route served `js/latte.js`, and `'self'` in
// `script-src` pointed at nothing.
//
// `check` drives it through espresso's `TestHost`, so every request runs the
// real middleware, the real cookie code and the real HMAC — and then drives a
// circuit through the same seam closures `latte.web` hands to a socket. What
// it CANNOT do is open a WebSocket: that is `w9_smoke.sh`, which runs THIS
// program with `serve 0` and drives it from a real Chrome. The two halves are
// deliberately the same program, so "the example works" and "a browser can use
// it" are one claim rather than two.
package main

import espresso
import std.fs
import std.io
import std.os
import {Anonymous, Antiforgery, CircuitOptions, CircuitSet, Component,
        FormMap, PageHost, PageInstance, PageMap, PageMatch, PageRequest,
        PageResponse, Principal, ShellOptions, Signer, SeamSigner,
        NO_POLLER_MESSAGE, TOKEN_FIELD, open_page, render_shell, scan_forms,
        scan_pages, CLIENT_PATH as SHELL_CLIENT_PATH,
        SOCKET_PATH as SHELL_SOCKET_PATH, ROOT_ID} from latte
import {run} from latte.boundary
import {CircuitSeam, ClientOptions, EndpointOptions, HeaderOptions, WebRequest,
        WebReply, SESSION_COOKIE, CLIENT_PATH, SOCKET_PATH, fresh_id,
        has_fiber_poller, hmac_signer, map_asset, map_circuit, map_client,
        map_pages, same_bytes, security_headers} from latte.web
import {Shell, Drink, Menu, Order, OrderPage} from cafe.site

// ============================================================== the styling

/// The stylesheet, served from memory at `/app.css`.
///
/// A file and not an inline `<style>`, because `security_headers` ships
/// `style-src 'self'` with no `'unsafe-inline'` and an inline block would be
/// dropped by the policy latte itself sends. It is a Beans constant rather
/// than a second file on disk so the example has exactly one path that has to
/// exist — `js/latte.js` — instead of two.
const STYLESHEET: string = "body{font:16px/1.5 system-ui,sans-serif;margin:0;background:#fbf7f2;color:#2b2118}\n.page{max-width:44rem;margin:0 auto;padding:2rem 1rem}\nheader{border-bottom:2px solid #e0d3c3;padding-bottom:.75rem;margin-bottom:1.5rem}\nh1{margin:0 0 .5rem;font-size:1.5rem}\nnav a{margin-right:1rem;color:#8a5a2b}\nul{list-style:none;padding:0}\n.drink button{font:inherit;padding:.5rem .75rem;border:1px solid #d8c6b0;border-radius:.4rem;background:#fff;cursor:pointer}\n.drink.chosen button{background:#8a5a2b;color:#fff;border-color:#8a5a2b}\nlabel{display:block;margin:.5rem 0}\ninput{font:inherit;padding:.3rem}\n#problems li{color:#a12b1e}\n";

// ============================================================== the wiring

/// Everything one process holds. One accept loop serves this application —
/// `WebServer.bind` runs a single worker and every connection is a fiber on it
/// — so plain fields are read and written by one OS thread.
pub class Cafe {
    pub pages: PageMap = new PageMap()
    pub forms: FormMap = new FormMap()
    pub host: Option<PageHost> = none
    pub set: Option<CircuitSet> = none
    pub shell: ShellOptions = new ShellOptions()
    /// `PageHost` needs a clock for the antiforgery expiry. A real deployment
    /// passes `time.unix_seconds()`; `check` passes a number it chose, so the
    /// token is a pure function of inputs this file picked and no test here
    /// reads a wall clock.
    pub now: int = 1000
    pub who: Principal = new Anonymous()
    pub stopper: Option<espresso.ServerControl> = none
    pub pages_served: int = 0
    pub scripts_served: int = 0
    pub stops: int = 0
    pub fn init() {}

    /// The page a circuit renders for a URL.
    ///
    /// It goes through the SAME `PageMap` and `open_page` the static half
    /// uses, so a circuit cannot answer a route the server does not have and
    /// cannot skip the authorization `open_page` re-checks. `session` is the
    /// handshake's, and it is what a form rendered on a circuit mints its
    /// token against.
    pub fn page_for(session: string, url: string) -> Option<Component> {
        match self.pages.find("GET", path_only(url)) {
            none => { return none }
            some(found) => {
                let instance: PageInstance = open_page(found, self.who, none)
                if !instance.ok() { return none }
                return instance.root()
            }
        }
    }
}

fn path_only(url: string) -> string {
    match url.find("?") {
        some(at) => { return url.slice(0, at) }
        none => { return url }
    }
}

/// Scan, check, and refuse to go any further if anything is wrong.
///
/// A latte application that starts with a bad page table serves the pages that
/// happened to survive, and the refusal that matters is the one it skipped.
/// Everything is decided here, once, before a socket exists.
fn start() -> Result<Cafe, string> {
    var cafe: Cafe = new Cafe()
    cafe.pages = scan_pages()
    cafe.forms = scan_forms(cafe.pages)
    if cafe.pages.report() != "" { return err(cafe.pages.report()) }
    if cafe.forms.report() != "" { return err(cafe.forms.report()) }

    // The signing key. A real deployment reads it from its configuration; a
    // constant here would be a key in a public repository, so this one is
    // fresh per process and says so.
    var key: string = ""
    match fresh_id() {
        ok(value) => { key = value }
        err(problem) => { return err("no CSPRNG: {problem.kind}") }
    }
    let signer: Signer = new SeamSigner(hmac_signer(key), same_bytes())
    cafe.host = some(new PageHost(cafe.pages, cafe.forms,
                                  new Antiforgery(signer, 900)))

    cafe.shell.title = "The Cafe"
    cafe.shell.stylesheets = ["/app.css"]

    let faults: List<string> = cafe.shell.faults()
    if faults.len() > 0 { return err(faults.join(" | ")) }

    var options: CircuitOptions = new CircuitOptions()
    options.idle_ms = 600000
    options.retention_ms = 600000
    let set: CircuitSet = new CircuitSet(options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            var session: string = ""
            match facts.get("session") { some(value) => { session = value } none => {} }
            return cafe.page_for(session, url)
        })
    // Every event handler runs inside this, so a panic in a click becomes an
    // error boundary's render rather than a dead worker.
    set.guard = run
    cafe.set = some(set)
    return ok(cafe)
}

/// Mount the whole application on an espresso app.
///
/// The order is the whole design of the pipeline:
///
///  1. `security_headers` FIRST, so it is outermost and sets its headers after
///     everything else has answered — a page, a 404, a 500, a stylesheet.
///  2. the assets, which are exact paths and answer before anything looks at
///     a route table.
///  3. `map_pages`, which owns latte's route table and falls through to `next`
///     for a path no `@page` claims.
///  4. `map_circuit`, on espresso's upgrade table, which the whole pipeline
///     above runs before.
fn mount(app: espresso.WebApplication, cafe: Cafe, secure: bool,
         endpoint: EndpointOptions) -> Result<bool> {
    app.use(security_headers(new HeaderOptions()))?

    var client: ClientOptions = new ClientOptions()
    map_client(app, client)?
    map_asset(app, "/app.css", STYLESHEET, "text/css; charset=utf-8",
              "no-cache")?

    var host: PageHost = new PageHost(cafe.pages, cafe.forms,
                                      new Antiforgery(new SeamSigner(
                                          hmac_signer(""), same_bytes()), 900))
    match cafe.host { some(found) => { host = found } none => {} }

    map_pages(app, fn(request: WebRequest) -> Option<WebReply> {
        var asked: PageRequest = new PageRequest()
        asked.method = request.method
        asked.path = request.path
        asked.body = request.body
        asked.session = request.session
        asked.who = cafe.who
        let answer: PageResponse = host.handle(asked, cafe.now)
        // A 404 with no allowed methods is "latte has no page here" — hand it
        // back to espresso so the application's own routes still work.
        if answer.status == 404 && answer.allowed.len() == 0 { return none }

        var reply: WebReply = new WebReply()
        reply.status = answer.status
        reply.allow = answer.allowed.join(", ")
        if answer.status != 200 {
            reply.body = answer.detail()
            reply.content_type = "text/plain; charset=utf-8"
            return some(reply)
        }
        cafe.pages_served += 1
        // The one line this whole lane exists for: a page body becomes a
        // document.
        match render_shell(cafe.shell, answer.body) {
            ok(document) => { reply.body = document }
            err(problem) => {
                reply.status = 500
                reply.body = problem
                reply.content_type = "text/plain; charset=utf-8"
            }
        }
        return some(reply)
    }, secure)?

    var endpoint: EndpointOptions = new EndpointOptions()
    endpoint.poll_ms = 100
    endpoint.socket_ms = 60000
    endpoint.no_poller_message = NO_POLLER_MESSAGE

    var set: CircuitSet = new CircuitSet(new CircuitOptions(),
        fn(facts: Map<string, string>, url: string) -> Option<Component> { return none })
    match cafe.set { some(found) => { set = found } none => {} }
    let seam: CircuitSeam = new CircuitSeam(
        set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
        set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
        set.wake_fn())
    map_circuit(app, SOCKET_PATH, seam, endpoint)?
    return ok(true)
}

// ============================================================== main

fn main() {
    let args: List<string> = os.args()
    var command: string = "check"
    if args.len() > 0 { command = args[0] }
    if command == "serve" {
        var port: int = 8080
        if args.len() > 1 {
            match args[1].to_int() { ok(value) => { port = value } err(_) => {} }
        }
        serve(port)
        return
    }
    if command != "check" {
        io.println("usage: main [check | serve <port>]")
        return
    }
    check()
}

// ============================================================== serve

/// The server a person runs. Port 0 lets the kernel choose, which is what
/// `w9_smoke.sh` uses so two runs on one machine never collide.
///
/// Every `CAFE-*` line goes to **stderr**, and that is not a style choice.
/// `std.io` has no `flush`, stdout to a pipe is fully buffered, and the port
/// line would sit in a 64 KiB buffer until the process exits — that is, until
/// after the harness gave up waiting for it. stderr is unbuffered.
fn serve(port: int) {
    if !has_fiber_poller() {
        // Windows has no fiber network poller, so every circuit past the first
        // waits for the one before it and this would hang with nothing
        // printed. Say so and leave.
        io.eprintln("CAFE-UNAVAILABLE {NO_POLLER_MESSAGE}")
        return
    }
    match start() {
        err(problem) => { io.eprintln("CAFE-REFUSED {problem}") }
        ok(cafe) => { listen(cafe, port) }
    }
}

fn listen(cafe: Cafe, port: int) {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("the app builds")

    var endpoint: EndpointOptions = new EndpointOptions()
    match mount(app, cafe, false, endpoint) {
        err(problem) => { io.eprintln("CAFE-REFUSED {problem.msg}"); return }
        ok(_) => {}
    }

    // Two routes that are not pages. They reach the router because `map_pages`
    // hands a path no `@page` claims back to `next`.
    app.get("/_stop", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        cafe.stops += 1
        match cafe.stopper {
            some(control) => { let asked: bool = control.stop().or(false) }
            none => {}
        }
        return espresso.text("stopping\n")
    }).expect("the stop route")
    // Chrome asks for this on every navigation with no prompting, and a 404
    // would land in a console assertion as noise that has nothing to do with
    // latte.
    app.get("/favicon.ico", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        return espresso.no_content()
    }).expect("the favicon route")

    var server_options: espresso.ServerOptions = new espresso.ServerOptions()
    server_options.port = port
    server_options.poll_timeout_ms = 25
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, server_options).expect("the socket binds")
    let chosen: int = server.port().expect("the port is known")

    // The origin allowlist, now that the kernel has chosen. Both spellings,
    // because a browser sends the host exactly as it was typed and `localhost`
    // and `127.0.0.1` are different origins. An EMPTY list refuses every
    // handshake that carries an `Origin` — the right default, and the reason a
    // browser cannot reach a deployment that has not named itself.
    endpoint.origins = ["http://127.0.0.1:{chosen}",
                        "http://localhost:{chosen}"]
    cafe.stopper = some(server.control())

    // One line, first, on the unbuffered stream: a harness blocks on it.
    io.eprintln("CAFE-PORT {chosen}")

    let stats: espresso.ServerStats = server.run().expect("the server runs")

    // The summary. Every number here is a server-side fact a browser could not
    // have faked, and `w9_smoke.sh` asserts on them.
    io.eprintln("CAFE-PAGES {cafe.pages_served}")
    io.eprintln("CAFE-UPGRADES {stats.upgrades}")
    io.eprintln("CAFE-STOPS {cafe.stops}")
    match cafe.set {
        some(held) => {
            io.eprintln("CAFE-HELD {held.count()}")
            io.eprintln("CAFE-FAULTS {held.faults.len()}")
            for fault: string in held.faults { io.eprintln("CAFE-FAULT {fault}") }
        }
        none => {}
    }
    io.eprintln("CAFE-DONE")
}

// ============================================================== check

/// One assertion, in the shape every suite in this repo uses.
class Report {
    pub checks: int = 0
    pub failures: int = 0
    pub fn init() {}

    pub fn eq(what: string, got: string, want: string) {
        self.checks += 1
        if got == want { io.println("ok {what}") }
        else {
            self.failures += 1
            io.println("FAIL {what}")
            io.println("     got  {got}")
            io.println("     want {want}")
        }
    }
    pub fn eqi(what: string, got: int, want: int) {
        self.eq(what, "{got}", "{want}")
    }
    pub fn yes(what: string, got: bool) { self.eq(what, "{got}", "true") }
    pub fn no(what: string, got: bool) { self.eq(what, "{got}", "false") }
}

/// The antiforgery token, replaced by a fixed word.
///
/// The token is `{expiry}.{HMAC}` over a session that is 256 random bits, so
/// it is different on every run and cannot be in a golden. Its *shape* is
/// asserted separately; what the golden holds is the page around it.
fn mask_token(html: string) -> string {
    let marker: string = "name=\"{TOKEN_FIELD}\" value=\""
    match html.find(marker) {
        none => { return html }
        some(at) => {
            let head: string = html.slice(0, at + marker.len())
            let rest: string = html.slice(at + marker.len(), html.len())
            match rest.find("\"") {
                none => { return html }
                some(end) => { return "{head}TOKEN{rest.slice(end, rest.len())}" }
            }
        }
    }
}

fn header_of(reply: espresso.TestResponse, name: string) -> string {
    match reply.headers.get(name) {
        some(value) => { return value }
        none => { return "" }
    }
}

/// The session cookie's value out of a `Set-Cookie`, or `""`.
fn session_in(reply: espresso.TestResponse) -> string {
    let raw: string = header_of(reply, "Set-Cookie")
    let marker: string = "{SESSION_COOKIE}="
    match raw.find(marker) {
        none => { return "" }
        some(at) => {
            let rest: string = raw.slice(at + marker.len(), raw.len())
            match rest.find(";") {
                none => { return rest }
                some(end) => { return rest.slice(0, end) }
            }
        }
    }
}

fn attribute_after(html: string, marker: string) -> string {
    match html.find(marker) {
        none => { return "" }
        some(at) => {
            let rest: string = html.slice(at + marker.len(), html.len())
            match rest.find("\"") {
                none => { return "" }
                some(end) => { return rest.slice(0, end) }
            }
        }
    }
}

fn token_in(html: string) -> string {
    return attribute_after(html, "name=\"{TOKEN_FIELD}\" value=\"")
}

fn is_hex(text: string, want: int) -> bool {
    if text.len() != want { return false }
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        let digit: bool = byte >= 48 && byte <= 57
        let lower: bool = byte >= 97 && byte <= 102
        if !digit && !lower { return false }
    }
    return true
}

fn cookie_headers(session: string) -> espresso.http.Headers {
    var headers: espresso.http.Headers = new espresso.http.Headers()
    headers.add("Cookie", "{SESSION_COOKIE}={session}")
    return move headers
}

fn form_headers(session: string) -> espresso.http.Headers {
    var headers: espresso.http.Headers = cookie_headers(session)
    headers.add("Content-Type", "application/x-www-form-urlencoded")
    return move headers
}

/// The handler id the batch bound for `event`, or -1.
///
/// A handler edit is `["h",<seq>,"click",<id>]`, so this reads the wire the
/// same way the browser does rather than assuming the slot numbering. It is
/// how `check` clicks without a DOM.
fn handler_for(batch: string, event: string) -> int {
    let marker: string = "[\"h\","
    var at: int = 0
    for at < batch.len() {
        match batch.slice(at, batch.len()).find(marker) {
            none => { return -1 }
            some(offset) => {
                let start: int = at + offset + marker.len()
                let rest: string = batch.slice(start, batch.len())
                let wanted: string = "\"{event}\","
                match rest.find("]") {
                    none => { return -1 }
                    some(close) => {
                        let body: string = rest.slice(0, close)
                        match body.find(wanted) {
                            some(name_at) => {
                                let digits: string = body.slice(
                                    name_at + wanted.len(), body.len())
                                match digits.to_int() {
                                    ok(value) => { return value }
                                    err(_) => { return -1 }
                                }
                            }
                            none => {}
                        }
                        at = start
                    }
                }
            }
        }
    }
    return -1
}

fn check() {
    let r: Report = new Report()
    io.println("== the cafe ==")
    io.println("")
    io.println("-- 0. the application starts")
    match start() {
        err(problem) => {
            io.println("FAIL the application did not start: {problem}")
            io.println("")
            io.println("1 checks, 1 bad")
            return
        }
        ok(cafe) => { drive(r, cafe) }
    }
    io.println("")
    io.println("{r.checks} checks, {r.failures} bad")
}

fn drive(r: Report, cafe: Cafe) {
    r.eq("0.1 the page scan refused nothing", cafe.pages.report(), "")
    r.eq("0.2 the form scan refused nothing", cafe.forms.report(), "")
    r.eq("0.3 the shell options have no faults",
         cafe.shell.faults().join(" | "), "")
    // The two spellings of one path. `latte.web` may not import its own module
    // root, so `CLIENT_PATH` and `SOCKET_PATH` exist twice; a drift is a page
    // whose script is a 404 and a socket that never connects, and this is what
    // makes it a failing check instead.
    r.eq("0.4 latte and latte.web agree where the client is served",
         SHELL_CLIENT_PATH, CLIENT_PATH)
    r.eq("0.5 latte and latte.web agree where the socket is",
         SHELL_SOCKET_PATH, SOCKET_PATH)

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("the app builds")
    var endpoint: EndpointOptions = new EndpointOptions()
    match mount(app, cafe, false, endpoint) {
        err(problem) => { io.println("FAIL mount: {problem.msg}"); return }
        ok(_) => {}
    }
    let host: espresso.TestHost = new espresso.TestHost(app)
    section_shell(r, cafe, host)
    section_client(r, cafe, host)
    section_form(r, cafe, host)
    section_circuit(r, cafe)
    match host.close() {
        ok(_) => {}
        err(problem) => { io.println("FAIL closing the host: {problem.msg}") }
    }
}
