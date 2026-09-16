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
// ## What this file is, and what it is not
//
// It is the seam nothing else in this repo has: a served **document** — with a
// doctype, a head, and a `<script src>` that boots a circuit — over a real
// espresso pipeline with latte's own CSP on it.
//
// `check` drives it through espresso's `TestHost`, so every request runs the
// real middleware, the real cookie code and the real HMAC — and then drives a
// circuit through the same seam closures `latte.web` hands to a socket. What
// it CANNOT do is open a WebSocket; that needs a real browser.
//
// ## The application is nine lines
//
// Everything below `check` is this example's own self-test, and everything
// above it is the application. It used to be 248 lines: a hand-rolled service
// class with `Option` holes in it, a `start` that scanned and signed and built
// two shells and a circuit set, a `mount` that got five espresso calls into the
// right order and assembled a nine-closure seam, and a `listen` that could only
// fill in the WebSocket origin list after the kernel had chosen a port.
//
// None of that was about a cafe. It is `latte_app` now, and what is left here
// is a title, a stylesheet, and a clock the test can predict.
package main

import github.com/beans-lang/espresso
import std.fs
import std.http
import std.io
import std.os
import {Antiforgery, CircuitSet, Component, PageHost, Principal, TOKEN_FIELD,
        CLIENT_PATH as SHELL_CLIENT_PATH, SOCKET_PATH as SHELL_SOCKET_PATH,
        ROOT_ID} from latte
import {LatteApp, LatteOptions, build} from latte_app
import {EndpointOptions, SESSION_COOKIE, CLIENT_PATH, SOCKET_PATH,
        fresh_id} from latte.web
// Nothing calls these five. The import is what puts them in the executable, so
// `scan_pages` can find their `@page` annotations — latte has no registry and
// `reflect.types()` is the registry.
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

// ============================================================== the app

/// The whole application. Nine lines, and every one of them is about a cafe.
///
/// `now` is the only unusual one. `LatteApp` reads the wall clock for the
/// antiforgery expiry unless it is given a number; `check` gives it one, so
/// the token is a pure function of inputs this file picked and no test here
/// reads a clock.
fn options() -> LatteOptions {
    var options: LatteOptions = new LatteOptions()
    options.title = "The Cafe"
    options.stylesheet("/app.css", stylesheet())
    options.now = 1000
    return move options
}

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

/// The server a person runs. Port 0 lets the kernel choose.
///
/// Two routes that are not pages are added on the way past: they reach the
/// router because `map_pages` hands a path no `@page` claims back to `next`.
fn serve(port: int) {
    match build(options()) {
        err(problem) => { io.eprintln("CAFE-REFUSED {problem}") }
        ok(app) => {
            match app.serve_with(port, fn(web: espresso.WebApplication) -> Result<bool> {
                web.get("/_stop", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
                    app.stop()
                    return espresso.text("stopping\n")
                })?
                // Chrome asks for this on every navigation with no prompting,
                // and a 404 would land in a console assertion as noise that
                // has nothing to do with latte.
                web.get("/favicon.ico", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
                    return espresso.no_content()
                })?
                return ok(true)
            }) {
                ok(_) => {}
                err(problem) => { io.eprintln("CAFE-REFUSED {problem.msg}") }
            }
        }
    }
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
    match build(options()) {
        err(problem) => {
            io.println("FAIL the application did not start: {problem}")
            io.println("")
            io.println("1 checks, 1 bad")
            return
        }
        ok(app) => { drive(r, app) }
    }
    io.println("")
    io.println("{r.checks} checks, {r.failures} bad")
}

fn drive(r: Report, app: LatteApp) {
    r.eq("0.1 the page scan refused nothing", app.pages.report(), "")
    r.eq("0.2 the form scan refused nothing", app.forms.report(), "")
    r.eq("0.3 the shell options have no faults",
         app.shell.faults().join(" | "), "")
    // The two spellings of one path. `latte.web` may not import its own module
    // root, so `CLIENT_PATH` and `SOCKET_PATH` exist twice; a drift is a page
    // whose script is a 404 and a socket that never connects, and this is what
    // makes it a failing check instead.
    r.eq("0.4 latte and latte.web agree where the client is served",
         SHELL_CLIENT_PATH, CLIENT_PATH)
    r.eq("0.5 latte and latte.web agree where the socket is",
         SHELL_SOCKET_PATH, SOCKET_PATH)

    var endpoint: EndpointOptions = new EndpointOptions()
    var web: espresso.WebApplication = new espresso.WebApplicationBuilder()
        .build().expect("the app builds")
    match app.mount(web, endpoint) {
        err(problem) => { io.println("FAIL mount: {problem.msg}"); return }
        ok(_) => {}
    }
    let host: espresso.TestHost = new espresso.TestHost(web)
    section_shell(r, app, host)
    section_client(r, app, host)
    section_form(r, app, host)
    section_circuit(r, app)
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
fn section_shell(r: Report, app: LatteApp, host: espresso.TestHost) {
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
fn section_client(r: Report, app: LatteApp, host: espresso.TestHost) {
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
fn section_form(r: Report, app: LatteApp, host: espresso.TestHost) {
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
fn section_circuit(r: Report, app: LatteApp) {
    io.println("")
    io.println("-- 4. a click, over a circuit")
    // `app.set` is a CircuitSet and not an `Option<CircuitSet>`: a LatteApp
    // that exists has one, because `build` either answers a whole application
    // or answers why it could not. The unwrap that used to be here printed a
    // check numbered 4.0 that no run has ever reached.
    let set: CircuitSet = app.set
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
