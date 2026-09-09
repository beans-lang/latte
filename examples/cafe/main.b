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
// it CANNOT do is open a WebSocket: that is `w8b_cafe.sh`, which runs THIS
// program with `serve 0` and drives it from a real Chrome. The two halves are
// deliberately the same program, so "the example works" and "a browser can use
// it" are one claim rather than two.
package main

import espresso
import std.fs
import std.http
import std.io
import std.os
import {Anonymous, Antiforgery, CircuitOptions, CircuitSet, Component,
        FormComponent, FormMap, FormState, PageHost, PageInstance, PageMap,
        PageMatch, PageRequest,
        PageResponse, Principal, ShellOptions, Signer, SeamSigner,
        NO_POLLER_MESSAGE, TOKEN_FIELD, is_safe_method, open_page,
        render_shell, scan_forms,
        scan_pages, CLIENT_PATH as SHELL_CLIENT_PATH,
        SOCKET_PATH as SHELL_SOCKET_PATH, ROOT_ID} from latte
import {run} from latte.boundary
import {CircuitSeam, ClientOptions, EndpointOptions, HeaderOptions, WebRequest,
        WebReply, SESSION_COOKIE, CLIENT_PATH, SOCKET_PATH, fresh_id,
        has_fiber_poller, hmac_signer, map_asset, map_circuit, map_client,
        map_pages, same_bytes, security_headers} from latte.web
import {Shell, Drink, Menu, Basket, OrderPage} from cafe.site

// ============================================================== the styling

/// The stylesheet, served from memory at `/app.css`.
///
/// A file and not an inline `<style>`, because `security_headers` ships
/// `style-src 'self'` with no `'unsafe-inline'` and an inline block would be
/// dropped by the policy latte itself sends. It is a Beans constant rather
/// than a second file on disk so the example has exactly one path that has to
/// exist — `js/latte.js` — instead of two.
/// A `List` of raw literals joined, and not one string, because a `{` in an
/// ordinary Beans string starts an interpolation — CSS is almost nothing but
/// braces, and `r"…"` is the literal that has none.
fn stylesheet() -> string {
    let rules: List<string> = [
        r"body{font:16px/1.5 system-ui,sans-serif;margin:0;background:#fbf7f2;color:#2b2118}",
        r".page{max-width:44rem;margin:0 auto;padding:2rem 1rem}",
        r"header{border-bottom:2px solid #e0d3c3;padding-bottom:.75rem;margin-bottom:1.5rem}",
        r"h1{margin:0 0 .5rem;font-size:1.5rem}",
        r"nav a{margin-right:1rem;color:#8a5a2b}",
        r"ul{list-style:none;padding:0}",
        r".drink button{font:inherit;padding:.5rem .75rem;border:1px solid #d8c6b0;border-radius:.4rem;background:#fff;cursor:pointer}",
        r".drink.chosen button{background:#8a5a2b;color:#fff;border-color:#8a5a2b}",
        r"label{display:block;margin:.5rem 0}",
        r"input{font:inherit;padding:.3rem}",
        r"#problems li{color:#a12b1e}"
    ]
    return "{rules.join("\n")}\n"
}
// ============================================================== the wiring

/// Everything one process holds. One accept loop serves this application —
/// `WebServer.bind` runs a single worker and every connection is a fiber on it
/// — so plain fields are read and written by one OS thread.
pub class Cafe {
    pub pages: PageMap = new PageMap()
    pub forms: FormMap = new FormMap()
    pub host: Option<PageHost> = none
    /// The same `Antiforgery` `PageHost` checks a post against. Held here as
    /// well because `page_for` renders a form page too — see there.
    pub anti: Option<Antiforgery> = none
    pub set: Option<CircuitSet> = none
    pub shell: ShellOptions = new ShellOptions()
    /// The shell for a response a circuit could not produce. See `mount`.
    pub static_shell: ShellOptions = new ShellOptions()
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
    ///
    /// **The token is minted here or the form is dead.** `PageHost.handle`
    /// gives every safe request's form page a fresh `FormState` with a token
    /// bound to that request's session; a circuit renders the same page
    /// through `open_page` and never touched `PageHost`, so without this the
    /// form the browser ends up holding carries `value=""` and the post it
    /// makes is answered `400 the form carried no antiforgery token`.
    pub fn page_for(session: string, url: string) -> Option<Component> {
        match self.pages.find("GET", path_only(url)) {
            none => { return none }
            some(found) => {
                let instance: PageInstance = open_page(found, self.who, none)
                if !instance.ok() { return none }
                // `instance.component` and not `instance.root()`: the root is
                // the outermost LAYOUT when the page has one, and the form is
                // the page. This is the same pair of lines `PageHost.handle`
                // runs before it renders a safe request.
                match instance.component {
                    some(page) => {
                        match page as? FormComponent {
                            some(form_page) => {
                                match self.anti {
                                    some(anti) => {
                                        form_page.state = new FormState()
                                        form_page.state.token = anti.issue(
                                            session, form_page.form_id(), self.now)
                                    }
                                    // `start` sets it before a socket can
                                    // exist. A page served with no token at
                                    // all is a form that cannot post, so it is
                                    // refused rather than rendered.
                                    none => { return none }
                                }
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
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
    // ONE `Antiforgery`, shared. The circuit's page factory mints tokens the
    // HTTP half will check, so a second instance would only be right for as
    // long as nobody changed a lifetime in one of the two places.
    let anti: Antiforgery = new Antiforgery(signer, 900)
    cafe.anti = some(anti)
    cafe.host = some(new PageHost(cafe.pages, cafe.forms, anti))

    cafe.shell.title = "The Cafe"
    cafe.shell.stylesheets = ["/app.css"]
    cafe.static_shell.title = cafe.shell.title
    cafe.static_shell.stylesheets = ["/app.css"]
    cafe.static_shell.circuit = false

    var faults: List<string> = cafe.shell.faults()
    for problem: string in cafe.static_shell.faults() { faults.push(problem) }
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
    map_asset(app, "/app.css", stylesheet(), "text/css; charset=utf-8",
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
        // A page a circuit could not produce is served WITHOUT one.
        //
        // `Cafe.page_for` answers a URL by looking the route up as a GET and
        // rendering a fresh page: that is all a circuit's `attach` carries —
        // a url. This body is the answer to a POST, and it holds what the
        // post produced: the field errors, or the receipt. A circuit that
        // attached to it would replace all of that with the pristine form,
        // and latte has no mechanism yet for carrying state across a
        // prerender into the attach that follows, so there is nothing for it
        // to carry the post across with. `ShellOptions.circuit = false` is
        // exactly this case: the client script is still served — enhanced
        // navigation and streamed chunks want it — and no socket is opened,
        // so the answer the user is reading stays on the screen. The next
        // navigation is a GET and gets a circuit again.
        var used: ShellOptions = cafe.shell
        if !is_safe_method(asked.method) { used = cafe.static_shell }
        // This is the line that turns a page body into a document.
        match render_shell(used, answer.body) {
            ok(document) => { reply.body = document }
            err(problem) => {
                reply.status = 500
                reply.body = problem
                reply.content_type = "text/plain; charset=utf-8"
            }
        }
        return some(reply)
    }, secure)?

    endpoint.poll_ms = 100
    endpoint.socket_ms = 60000
    // The message a handshake gets on a platform with no fiber network poller.
    // The host sets it from latte's constant rather than spelling a second
    // copy of the sentence.
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
/// `w8b_cafe.sh` uses so two runs on one machine never collide.
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
    // have faked, and `w8b_cafe.sh` asserts on them.
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

fn cookie_headers(session: string) -> http.Headers {
    var headers: http.Headers = new http.Headers()
    headers.add("Cookie", "{SESSION_COOKIE}={session}")
    return move headers
}

fn form_headers(session: string) -> http.Headers {
    var headers: http.Headers = cookie_headers(session)
    headers.add("Content-Type", "application/x-www-form-urlencoded")
    return move headers
}

/// Every handler id the batch bound for `event`, in wire order.
///
/// A handler edit is `["h",<seq>,"click",<id>]`, so this reads the batch the
/// way the browser does rather than assuming how slots are numbered. It is how
/// `check` clicks with no DOM.
fn handlers_for(batch: string, event: string) -> List<int> {
    var found: List<int> = []
    let marker: string = "[\"h\","
    let wanted: string = "\"{event}\","
    var at: int = 0
    for at < batch.len() {
        var offset: int = -1
        match batch.slice(at, batch.len()).find(marker) {
            some(where) => { offset = where }
            none => { at = batch.len(); continue }
        }
        let start: int = at + offset + marker.len()
        let rest: string = batch.slice(start, batch.len())
        var close: int = -1
        match rest.find("]") {
            some(where) => { close = where }
            none => { at = batch.len(); continue }
        }
        let body: string = rest.slice(0, close)
        match body.find(wanted) {
            some(name_at) => {
                match body.slice(name_at + wanted.len(), body.len()).to_int() {
                    ok(value) => { found.push(value) }
                    err(_) => {}
                }
            }
            none => {}
        }
        at = start
    }
    return move found
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

// ---------------------------------------------------------------- § 1 shell

/// The document, whole, and the four headers that make it safe.
///
/// The document is PRINTED, in full, into the golden. It is the whole point
/// of this example — the one thing a reader most needs to see — and an
/// assertion that it "contains a script tag" would pass on a page that also
/// carried an inline one.
fn section_shell(r: Report, cafe: Cafe, host: espresso.TestHost) {
    io.println("")
    io.println("-- 1. GET / is a document, not a fragment")
    match host.get("/") {
        err(problem) => { r.eq("1.0 GET /", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("1.1 status", reply.status, 200)
            r.eq("1.2 content type", header_of(reply, "Content-Type"),
                 "text/html; charset=utf-8")
            // The policy, whole. A test that checked one directive would pass
            // a policy that had lost the other seven.
            r.eq("1.3 the content security policy",
                 header_of(reply, "Content-Security-Policy"),
                 "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
            r.eq("1.4 nosniff", header_of(reply, "X-Content-Type-Options"),
                 "nosniff")
            r.eq("1.5 no framing", header_of(reply, "X-Frame-Options"), "DENY")
            r.eq("1.6 referrer", header_of(reply, "Referrer-Policy"),
                 "no-referrer")

            let session: string = session_in(reply)
            r.yes("1.7 a session cookie was minted, 256 bits of it",
                  is_hex(session, 64))
            let cookie: string = header_of(reply, "Set-Cookie")
            r.yes("1.8 the cookie is HttpOnly", cookie.contains("HttpOnly"))
            r.yes("1.9 the cookie is SameSite=Lax",
                  cookie.contains("SameSite=Lax"))
            // `map_pages(app, …, false)`: a TestHost is not TLS, and a browser
            // silently drops a `Secure` cookie over http. The example chose
            // this in the code that mounts it, and the check names the choice.
            r.no("1.10 and NOT Secure, because this app serves plain http",
                 cookie.contains("Secure"))

            let document: string = reply.text()
            r.yes("1.11 it is a document", document.starts_with("<!doctype html>\n"))
            r.yes("1.12 the client is loaded from latte's own path",
                  document.contains(
                      "<script src=\"{SHELL_CLIENT_PATH}\" defer data-latte-boot=\"1\" data-latte-ws=\"{SHELL_SOCKET_PATH}\" data-latte-root=\"{ROOT_ID}\"></script>"))
            // The three things `security_headers` promises the page has none
            // of. A `script-src 'self'` with no `'unsafe-inline'` makes each of
            // these a silently dead page.
            r.no("1.13 no inline script", document.contains("<script>"))
            r.no("1.14 no inline style", document.contains("<style"))
            r.no("1.15 no on* handler attribute", document.contains(" onclick"))
            r.no("1.16 no circuit id in the page at all",
                 document.contains("data-latte-circuit"))
            r.yes("1.17 the page body is inside the root element",
                  document.contains("<div id=\"{ROOT_ID}\"><div class=\"page\">"))

            io.println("")
            io.println("--- the document ---")
            io.println(document)
            io.println("--- end of the document ---")
        }
    }
}

// --------------------------------------------------------------- § 2 client

/// The route that makes `script-src 'self'` mean something.
///
/// The path is taken OUT OF THE DOCUMENT rather than written here, so this
/// section proves the shell and the route agree rather than proving each of
/// them agrees with a constant in this file.
fn section_client(r: Report, cafe: Cafe, host: espresso.TestHost) {
    io.println("")
    io.println("-- 2. the client script is served, and cached honestly")

    var served_from: string = ""
    match host.get("/") {
        err(_) => {}
        ok(page) => { served_from = attribute_after(page.text(), "<script src=\"") }
    }
    r.eq("2.1 the page points at the path the asset route claims",
         served_from, CLIENT_PATH)

    var on_disk: int = -1
    match fs.read("js/latte.js") {
        ok(text) => { on_disk = text.len() }
        err(problem) => { io.println("FAIL cannot read js/latte.js: {problem.kind}") }
    }

    var tag: string = ""
    match host.get(served_from) {
        err(problem) => { r.eq("2.2 GET the client", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("2.2 status", reply.status, 200)
            r.eq("2.3 content type", header_of(reply, "Content-Type"),
                 "text/javascript; charset=utf-8")
            r.eqi("2.4 the bytes are the file's, all of them",
                  reply.text().len(), on_disk)
            r.eq("2.5 revalidate rather than cache blind",
                 header_of(reply, "Cache-Control"), "no-cache")
            tag = header_of(reply, "ETag")
            r.yes("2.6 it carries a strong entity tag",
                  tag.len() > 2 && tag.starts_with("\"") && tag.ends_with("\""))
            r.eq("2.7 nosniff reaches the script too, so the type has to be right",
                 header_of(reply, "X-Content-Type-Options"), "nosniff")
        }
    }

    // The conditional request, with its positive control beside it: a matching
    // tag must be 304 AND a non-matching one must be 200. Without the second,
    // a route that answered 304 to everything would pass the first.
    var conditional: http.Headers = new http.Headers()
    conditional.add("If-None-Match", tag)
    match host.send_with_headers("GET", served_from, conditional, "") {
        err(problem) => { r.eq("2.8 a matching tag", "err {problem.msg}", "304") }
        ok(reply) => {
            r.eqi("2.8 a matching tag is 304", reply.status, 304)
            r.eqi("2.9 and carries no body", reply.text().len(), 0)
        }
    }
    var stale: http.Headers = new http.Headers()
    stale.add("If-None-Match", "\"0-0\"")
    match host.send_with_headers("GET", served_from, stale, "") {
        err(problem) => { r.eq("2.10 a stale tag", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("2.10 a stale tag gets the whole file", reply.status, 200)
            r.eqi("2.11 all of it", reply.text().len(), on_disk)
        }
    }

    match host.post(served_from, "") {
        err(problem) => { r.eq("2.12 POST", "err {problem.msg}", "405") }
        ok(reply) => {
            r.eqi("2.12 POST to a static asset is 405", reply.status, 405)
            r.eq("2.13 and says what it does answer",
                 header_of(reply, "Allow"), "GET, HEAD")
        }
    }

    match host.get("/app.css") {
        err(problem) => { r.eq("2.14 GET the stylesheet", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("2.14 the stylesheet is served by the same route", reply.status, 200)
            r.eq("2.15 as css", header_of(reply, "Content-Type"),
                 "text/css; charset=utf-8")
        }
    }
}

// ----------------------------------------------------------------- § 3 form

/// The form, with no JavaScript anywhere: a GET, a good POST, a bad POST, and
/// three refusals — each with the accepted case beside it in the same section.
fn section_form(r: Report, cafe: Cafe, host: espresso.TestHost) {
    io.println("")
    io.println("-- 3. the order form, with JavaScript switched off")

    var session: string = ""
    var token: string = ""
    match host.get("/order/4") {
        err(problem) => { r.eq("3.0 GET /order/4", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("3.1 status", reply.status, 200)
            session = session_in(reply)
            let document: string = reply.text()
            token = token_in(document)
            match token.find(".") {
                none => { r.eq("3.2 the token is expiry.mac", "no dot", "a dot") }
                some(at) => {
                    r.yes("3.2 the token's MAC is a SHA-256 digest",
                          is_hex(token.slice(at + 1, token.len()), 64))
                }
            }
            r.yes("3.3 the route parameter reached the page",
                  document.contains("Order for table 4"))
            io.println("")
            io.println("--- /order/4, with the token masked ---")
            io.println(mask_token(document))
            io.println("--- end ---")
        }
    }

    // ACCEPTED. Everything below refuses; this is the control that proves the
    // refusals are refusing for their own reason and not for a coarser one.
    match host.send_with_headers("POST", "/order/4", form_headers(session),
                                 "__latte_token={token}&name=Ada&cups=2&decaf=on") {
        err(problem) => { r.eq("3.4 a good POST", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("3.4 a good POST is accepted", reply.status, 200)
            r.yes("3.5 and the order is placed",
                  reply.text().contains("2 decaf for Ada at table 4"))
        }
    }

    // A body that binds and fails a rule is NOT a refusal: it is a 200 with the
    // page re-rendered, the message beside the field, and the text still in the
    // box. A form that answered 400 here would lose what the user typed.
    match host.send_with_headers("POST", "/order/4", form_headers(session),
                                 "__latte_token={token}&name=A&cups=9") {
        err(problem) => { r.eq("3.6 a bad POST", "err {problem.msg}", "200") }
        ok(reply) => {
            let document: string = reply.text()
            r.eqi("3.6 a bad POST is still a page", reply.status, 200)
            r.yes("3.7 the length rule is reported by name",
                  document.contains("<li>name:"))
            r.yes("3.8 the range rule is reported by name",
                  document.contains("<li>cups:"))
            r.yes("3.9 and the boxes give back what was typed",
                  document.contains("id=\"cups\" value=\"9\""))
            r.no("3.10 nothing was placed", document.contains("for A at table"))
        }
    }

    match host.send_with_headers("POST", "/order/4", form_headers(session),
                                 "name=Ada&cups=2") {
        err(problem) => { r.eq("3.11 no token", "err {problem.msg}", "400") }
        ok(reply) => { r.eqi("3.11 a POST with no token is refused", reply.status, 400) }
    }
    match host.send_with_headers("POST", "/order/4", form_headers(session),
                                 "__latte_token=1899.deadbeef&name=Ada&cups=2") {
        err(problem) => { r.eq("3.12 a forged token", "err {problem.msg}", "400") }
        ok(reply) => { r.eqi("3.12 a forged token is refused", reply.status, 400) }
    }
    // The same token, a different session. This is the binding that makes the
    // token worth minting: a token lifted off someone else's page is useless.
    var other: string = ""
    match host.get("/order/4") {
        err(_) => {}
        ok(reply) => { other = session_in(reply) }
    }
    r.no("3.13 the second visitor got a different session", other == session)
    match host.send_with_headers("POST", "/order/4", form_headers(other),
                                 "__latte_token={token}&name=Ada&cups=2") {
        err(problem) => { r.eq("3.14 another session's token", "err {problem.msg}", "400") }
        ok(reply) => {
            r.eqi("3.14 another session's token is refused", reply.status, 400)
        }
    }

    // A route parameter that cannot bind. `/order/4` above is the control.
    match host.get("/order/twelve") {
        err(problem) => { r.eq("3.15 an unbindable parameter", "err {problem.msg}", "400") }
        ok(reply) => {
            r.eqi("3.15 a table that is not a number is refused", reply.status, 400)
        }
    }
    match host.get("/nowhere") {
        err(problem) => { r.eq("3.16 an unrouted path", "err {problem.msg}", "404") }
        ok(reply) => {
            r.eqi("3.16 a path no @page claims falls through to espresso",
                  reply.status, 404)
        }
    }
}

// -------------------------------------------------------------- § 4 circuit

/// A click, over the seam a socket drives.
///
/// These are the SAME nine closures `latte.web` hands `CircuitEndpoint` — the
/// set's own `open`, `accept` and `outbox`. What is missing here and nowhere
/// else is the socket, and that is what `w8b_cafe.sh` adds with a real Chrome.
fn section_circuit(r: Report, cafe: Cafe) {
    io.println("")
    io.println("-- 4. a click, over a circuit")
    match cafe.set {
        none => { r.eq("4.0 the circuit set exists", "none", "some") }
        some(set) => {
            var facts: Map<string, string> = {}
            var id: string = ""
            match fresh_id() { ok(value) => { id = value } err(_) => {} }
            facts["id"] = id
            facts["session"] = "0123456789abcdef0123456789abcdef"
            facts["origin"] = "http://127.0.0.1:8080"
            facts["path"] = SOCKET_PATH

            let handle: int = set.open(facts, 0)
            r.yes("4.1 the circuit opened", handle >= 0)

            let greeting: List<string> = set.outbox(handle)
            r.eqi("4.2 one frame is queued before any message", greeting.len(), 1)
            r.eq("4.3 and it is the hello, naming the id the SERVER minted",
                 greeting[0],
                 "\{\"t\":\"hello\",\"v\":1,\"c\":\"{id}\",\"mx\":65536\}")

            let first: List<string> = set.accept(handle,
                "\{\"t\":\"attach\",\"c\":\"{id}\",\"u\":\"/\"\}", 1)
            r.eqi("4.4 attach answers exactly one batch", first.len(), 1)
            let batch1: string = first[0]
            r.yes("4.5 it is batch 1",
                  batch1.starts_with("\{\"t\":\"batch\",\"b\":1,"))
            r.yes("4.6 the whole menu is in it", batch1.contains("cortado"))
            r.yes("4.7 including the page's own text",
                  batch1.contains("nothing picked yet"))

            let clicks: List<int> = handlers_for(batch1, "click")
            r.eqi("4.8 three drinks bound three click handlers", clicks.len(), 3)
            io.println("   the handler ids the batch carried: {clicks.join(", ")}")

            let second: List<string> = set.accept(handle,
                "\{\"t\":\"ev\",\"h\":{clicks[0]},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":1,\"y\":2\}\}", 2)
            r.eqi("4.9 a click answers one batch", second.len(), 1)
            let batch2: string = second[0]
            r.yes("4.10 it is batch 2",
                  batch2.starts_with("\{\"t\":\"batch\",\"b\":2,"))
            r.yes("4.11 the page says what was picked",
                  batch2.contains("picked espresso (1)"))
            // The claim that makes a circuit worth having: a drink whose
            // parameters did not move sends NOTHING. `cortado` is neither the
            // one clicked nor the one whose `chosen` changed, so its name must
            // not be on the wire at all.
            r.no("4.12 and an untouched row is not on the wire",
                 batch2.contains("cortado"))

            // The second click is on a handler from batch 1, deliberately: the
            // row it belongs to did not re-render, so its slot is still the one
            // the client holds. A framework that re-numbered every slot on
            // every render would fail here.
            let third: List<string> = set.accept(handle,
                "\{\"t\":\"ev\",\"h\":{clicks[1]},\"k\":\"click\",\"p\":\{\"b\":0,\"x\":1,\"y\":2\}\}", 3)
            r.eqi("4.13 a click on a stale-looking slot still lands", third.len(), 1)
            r.yes("4.14 on the row it belongs to",
                  third[0].contains("picked flat white (2)"))

            r.eqi("4.15 one circuit is held", set.count(), 1)
            r.eqi("4.16 and the set recorded no faults", set.faults.len(), 0)
        }
    }
}
