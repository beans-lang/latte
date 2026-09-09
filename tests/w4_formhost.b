// tests/w4_formhost.b — routing, layouts, a form with validation, and the
// antiforgery refusal, on espresso's TestHost.
//
// This is a whole latte application — a `@page`, a `@layout`, a `@form` model,
// a `PageHost` and `latte.web.map_pages` — served through espresso's in-memory
// host, so every request here runs the real middleware pipeline, the real
// cookie code and the real HMAC.
//
// **Every refusal in § 3 has the accepted case beside it, in the same section,
// posting the same body.** That is not decoration: a token check that never ran
// would pass every "refused" case in this file by refusing for some other
// reason, and the only thing that can tell those two apart is a request that
// must be *accepted* going through the same code. RULES.md, "the refusal
// that never runs" — a live refusal can stand behind a coarser rule that
// swallows every input before it, so it looks correct and never actually
// runs.
//
// **What makes this byte-deterministic.** The session id is 256 random bits, so
// it is never printed: what is printed is its shape and the answers to
// questions about it. The clock is a variable this file advances, so the expiry
// case needs no sleep and the token is a pure function of inputs this file
// chose. Nothing here reads a wall clock.
package main

import espresso
import std.http
import std.io
import std.reflect
import {Builder, Component, Layout, PageMap, PageHost, PageRequest,
        PageResponse, Principal, Anonymous, scan_pages, scan_forms,
        FormComponent, FormMap, FormState, Signer, SeamSigner, Antiforgery,
        TOKEN_FIELD, page, layout, authorize, param,
        form, field, required, length, range} from latte
import {hmac_signer, same_bytes, map_pages, WebRequest, WebReply,
        SESSION_COOKIE} from latte.web

// ================================================================ the app

@form
pub class Note {
    @field @required @length(min: 2, max: 10) pub title: string = ""
    @field @range(min: 1, max: 5) pub stars: int = 0
    @field pub pinned: bool = false
    /// Public and not a `@field`: no body may reach it.
    pub owner: string = "nobody"
    pub fn init() {}
}

pub class Shell extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) {
        b.open(0, "html")
        b.open(1, "body")
        b.fragment(2, self.body)
        b.close()
        b.close()
    }
}

/// The form page. Its render is what a browser would post back: a hidden token
/// input, the fields, and whatever the last post complained about.
@page(route: r"/notes/{slug}", methods: ["GET", "POST"])
@layout(name: "Shell")
pub class NotePage extends FormComponent {
    @param pub slug: string = ""
    pub model: Note = new Note()
    pub saved: int = 0
    pub fn init() { super.init() }
    pub override fn form_id() -> string { return "note" }
    pub override fn form_model() -> reflect.Value { return reflect.value(self.model) }
    pub override fn on_submit() { self.saved += 1 }
    pub override fn render(b: Builder) {
        b.open(0, "form")
        b.attr(1, "method", "post")
        b.attr(2, "action", "/notes/{self.slug}")
        b.open(3, "input")
        b.attr(4, "type", "hidden")
        b.attr(5, "name", TOKEN_FIELD)
        b.attr(6, "value", self.state.token)
        b.close()
        b.open(7, "p")
        b.attr(8, "class", "title")
        // What a browser would put back in the box: the text this post carried
        // for `title`, and the model on a GET or a body that named no title.
        b.text(9, self.state.value_for("title", self.model.title))
        b.close()
        // `stars` is an int, so it is the field that CANNOT hold what a user
        // types when they type something that is not a number. It is rendered
        // here for exactly that reason — see § 7.
        b.open(19, "p")
        b.attr(20, "class", "stars")
        b.text(21, self.state.value_for("stars", "{self.model.stars}"))
        b.close()
        b.open(10, "p")
        b.attr(11, "class", "errors")
        b.text(12, self.state.summary())
        b.close()
        b.open(13, "p")
        b.attr(14, "class", "ignored")
        b.text(15, self.state.ignored())
        b.close()
        b.open(16, "p")
        b.attr(17, "class", "owner")
        b.text(18, self.model.owner)
        b.close()
        b.close()
    }
}

/// A read-only page, so the 405 case has a path that answers something else and
/// the layout chain is exercised by more than one page.
@page(route: r"/about")
@layout(name: "Shell")
pub class AboutPage extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "about")
        b.close()
    }
}

/// An authorized page, so the 401 and 403 answers are real rather than
/// asserted. Nothing here is a form: `@authorize` is checked before anything is
/// activated.
@page(route: r"/admin")
@authorize(roles: ["admin"])
@layout(name: "Shell")
pub class AdminPage extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "admin")
        b.close()
    }
}

/// Somebody who is signed in and is not an admin.
pub class Member implements Principal {
    pub fn init() {}
    pub fn authenticated() -> bool { return true }
    pub fn has_role(role: string) -> bool { return role == "member" }
    pub fn satisfies(policy: string) -> bool { return false }
}

// ================================================================ the harness

class Report {
    pub failures: int = 0
    pub checks: int = 0
    pub fn init() {}

    pub fn eq(label: string, got: string, want: string) {
        self.checks += 1
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got \"{got}\", want \"{want}\"") ; self.failures += 1 }
    }

    pub fn eqi(label: string, got: int, want: int) {
        self.checks += 1
        if got == want { io.println("ok   {label}: {got}") }
        else { io.println("FAIL {label}: got {got}, want {want}") ; self.failures += 1 }
    }

    pub fn yes(label: string, got: bool) {
        self.checks += 1
        if got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got false, want true") ; self.failures += 1 }
    }

    pub fn no(label: string, got: bool) {
        self.checks += 1
        if !got { io.println("ok   {label}") }
        else { io.println("FAIL {label}: got true, want false") ; self.failures += 1 }
    }
}

/// The clock and the identity this run's requests are served under.
///
/// A class and not two locals, because the seam closure `map_pages` takes
/// captures it and a closure cannot capture a `var` it must also see change.
class Dial {
    pub now: int = 1000
    pub who: Principal = new Anonymous()
    pub fn init() {}
}

/// The value of the one attribute in `html` named `name`, or `""`.
///
/// Deliberately crude: it reads the rendered page the way the browser's next
/// request would, so the token this file posts back is the token the page
/// actually carried, not one the test minted for itself. A test that issued its
/// own token would never notice a page that rendered somebody else's.
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

// ================================================================ the gate

fn main() {
    let r: Report = new Report()
    var pages: PageMap = scan_pages()
    let forms: FormMap = scan_forms(pages)

    io.println("== 0. the application starts ==")
    r.eq("the page scan refused nothing", pages.report(), "")
    r.eq("the form scan refused nothing", forms.report(), "")

    let dial: Dial = new Dial()
    let signer: Signer = new SeamSigner(hmac_signer("the host's key"), same_bytes())
    let host: PageHost = new PageHost(pages, forms, new Antiforgery(signer, 900))

    var builder: espresso.WebApplicationBuilder = new espresso.WebApplicationBuilder()
    match builder.build() {
        err(problem) => {
            io.println("FAIL the application did not build: {problem.msg}")
            return
        }
        ok(app) => {
            // `secure = false`: a TestHost is not a TLS connection, and the
            // point of the parameter is that this choice is visible in the code
            // that made it.
            match map_pages(app, fn(request: WebRequest) -> Option<WebReply> {
                var latte_request: PageRequest = new PageRequest()
                latte_request.method = request.method
                latte_request.path = request.path
                latte_request.body = request.body
                latte_request.session = request.session
                latte_request.who = dial.who
                let answer: PageResponse = host.handle(latte_request, dial.now)
                if answer.status == 404 && answer.allowed.len() == 0 { return none }
                var reply: WebReply = new WebReply()
                reply.status = answer.status
                reply.body = if answer.status == 200 { answer.body } else { answer.detail() }
                reply.allow = answer.allowed.join(", ")
                if answer.status != 200 { reply.content_type = "text/plain; charset=utf-8" }
                return some(reply)
            }, false) {
                err(problem) => {
                    io.println("FAIL map_pages: {problem.msg}")
                    return
                }
                ok(_) => {}
            }
            let test_host: espresso.TestHost = new espresso.TestHost(app)
            run(r, test_host, dial, host)
            match test_host.close() {
                ok(_) => {}
                err(problem) => { io.println("FAIL closing the host: {problem.msg}") }
            }
        }
    }

    io.println("")
    io.println("{r.checks} checks, {r.failures} bad")
}

fn run(r: Report, host: espresso.TestHost, dial: Dial, pages: PageHost) {
    let ticket: Ticket = new Ticket()
    section_one(r, host, dial, ticket)
    section_two(r, host, dial, ticket)
    section_three(r, host, dial, ticket)
    section_four(r, host, dial, pages)
}

// ---------------------------------------------------------------- § 1 GET

/// The session and the token this run posts with. Filled by § 1 and read by
/// § 2 and § 3, because a token minted anywhere but by a rendered page is a
/// token this suite invented.
class Ticket {
    pub session: string = ""
    pub token: string = ""
    pub fn init() {}
}

fn section_one(r: Report, host: espresso.TestHost, dial: Dial, ticket: Ticket) {
    io.println("")
    io.println("== 1. a GET renders the page, in its layout, with a token ==")
    match host.get("/notes/hello") {
        err(problem) => { r.eq("GET /notes/hello", "error {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("GET /notes/hello", reply.status, 200)
            r.eq("its content type", header_of(reply, "Content-Type"),
                 "text/html; charset=utf-8")

            ticket.session = session_in(reply)
            r.yes("it minted a session of 256 bits in hex", is_hex(ticket.session, 64))
            let cookie: string = header_of(reply, "Set-Cookie")
            r.yes("the cookie is HttpOnly", cookie.contains("HttpOnly"))
            r.yes("and SameSite=Lax", cookie.contains("SameSite=Lax"))
            r.yes("and path-wide", cookie.contains("Path=/"))
            r.no("and not Secure over this plain-HTTP host",
                 cookie.contains("Secure"))

            ticket.token = token_in(reply.text())
            r.yes("the page carries a token", ticket.token.len() > 5)
            r.eq("issued against this clock", ticket.token.slice(0, 5), "1900.")

            // The whole page, so the layout chain, the route parameter and the
            // empty error line are all pinned at once. The token is the only
            // part that varies, and it is replaced by its own name.
            r.eq("the page", reply.text().replace(ticket.token, "<token>"),
                 "<html><body><form method=\"post\" action=\"/notes/hello\"><input type=\"hidden\" name=\"__latte_token\" value=\"<token>\"><p class=\"title\"></p><p class=\"stars\">0</p><p class=\"errors\"></p><p class=\"ignored\"></p><p class=\"owner\">nobody</p></form></body></html>")
        }
    }

    // A second GET in the same session must not mint a second session.
    match host.send_with_headers("GET", "/notes/hello", cookie_headers(ticket.session)) {
        err(problem) => { r.eq("a second GET", "error {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("a second GET in the same session", reply.status, 200)
            r.eq("sets no new cookie", header_of(reply, "Set-Cookie"), "")
            // Compared, never printed: the token is an HMAC over a random
            // session id, so putting it in the golden would make this suite
            // fail on its second run for a reason that has nothing to do with
            // latte.
            r.yes("and issues the same token for the same clock",
                  token_in(reply.text()) == ticket.token)
        }
    }

    io.println("-- routing, and the answers that are not this page")
    match host.get("/about") {
        err(problem) => { r.eq("GET /about", "error {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("another page on the same layout", reply.status, 200)
            r.eq("its body", reply.text(), "<html><body><p>about</p></body></html>")
        }
    }
    match host.get("/nowhere") {
        err(problem) => { r.eq("GET /nowhere", "error {problem.msg}", "404") }
        ok(reply) => { r.eqi("a path no page answers", reply.status, 404) }
    }
    match host.send_with_headers("POST", "/about", form_headers(ticket.session), "x=1") {
        err(problem) => { r.eq("POST /about", "error {problem.msg}", "405") }
        ok(reply) => {
            r.eqi("a POST to a page that only serves GET", reply.status, 405)
            r.eq("and it says which method would work", header_of(reply, "Allow"), "GET")
        }
    }
    var json_headers: http.Headers = cookie_headers(ticket.session)
    json_headers.add("Content-Type", "application/json")
    match host.send_with_headers("POST", "/notes/hello", json_headers, "title=x") {
        err(problem) => { r.eq("a JSON body", "error {problem.msg}", "415") }
        ok(reply) => {
            r.eqi("a body latte cannot read", reply.status, 415)
        }
    }

    io.println("-- authorization, before anything is activated")
    match host.send_with_headers("GET", "/admin", cookie_headers(ticket.session)) {
        err(problem) => { r.eq("GET /admin", "error {problem.msg}", "401") }
        ok(reply) => { r.eqi("nobody is signed in", reply.status, 401) }
    }
    dial.who = new Member()
    match host.send_with_headers("GET", "/admin", cookie_headers(ticket.session)) {
        err(problem) => { r.eq("GET /admin as a member", "error {problem.msg}", "403") }
        ok(reply) => { r.eqi("signed in, wrong role", reply.status, 403) }
    }
    dial.who = new Anonymous()
}

// ---------------------------------------------------------------- § 2 the post

fn post(host: espresso.TestHost, session: string, body: string) -> string {
    match host.send_with_headers("POST", "/notes/hello", form_headers(session), body) {
        err(problem) => { return "error {problem.msg}" }
        ok(reply) => {
            let text: string = reply.text().replace(session, "<session>")
            return "{reply.status} {text}"
        }
    }
}

fn body_with(token: string, rest: string) -> string {
    return "{TOKEN_FIELD}={token}&{rest}"
}

fn section_two(r: Report, host: espresso.TestHost, dial: Dial, ticket: Ticket) {
    io.println("")
    io.println("== 2. a post binds, validates and renders its errors ==")

    // The accepted case, first, so everything below it is measured against a
    // path that is known to work.
    let good: string = post(host, ticket.session,
                            body_with(ticket.token, "title=Hello&stars=4&pinned=on"))
    r.eq("a clean post", good.replace(ticket.token, "<token>"),
         "200 <html><body><form method=\"post\" action=\"/notes/hello\"><input type=\"hidden\" name=\"__latte_token\" value=\"<token>\"><p class=\"title\">Hello</p><p class=\"stars\">4</p><p class=\"errors\"></p><p class=\"ignored\"></p><p class=\"owner\">nobody</p></form></body></html>")

    let bad: string = post(host, ticket.session,
                           body_with(ticket.token, "title=H&stars=9"))
    r.eq("a post that fails both rules", bad.replace(ticket.token, "<token>"),
         "200 <html><body><form method=\"post\" action=\"/notes/hello\"><input type=\"hidden\" name=\"__latte_token\" value=\"<token>\"><p class=\"title\">H</p><p class=\"stars\">9</p><p class=\"errors\">title: title must be 2 to 10 characters | stars: stars must be between 1 and 5</p><p class=\"ignored\"></p><p class=\"owner\">nobody</p></form></body></html>")

    let missing: string = post(host, ticket.session, body_with(ticket.token, "stars=3"))
    r.eq("a post missing a required field", missing.replace(ticket.token, "<token>"),
         "200 <html><body><form method=\"post\" action=\"/notes/hello\"><input type=\"hidden\" name=\"__latte_token\" value=\"<token>\"><p class=\"title\"></p><p class=\"stars\">3</p><p class=\"errors\">title: title is required</p><p class=\"ignored\"></p><p class=\"owner\">nobody</p></form></body></html>")

    // Mass assignment, end to end. `owner` is public and is not a `@field`, and
    // a body that names it must leave it at its default AND say it was ignored.
    let sneaky: string = post(host, ticket.session,
                              body_with(ticket.token, "title=Hello&stars=4&owner=root"))
    r.eq("a post naming a field the author did not annotate",
         sneaky.replace(ticket.token, "<token>"),
         "200 <html><body><form method=\"post\" action=\"/notes/hello\"><input type=\"hidden\" name=\"__latte_token\" value=\"<token>\"><p class=\"title\">Hello</p><p class=\"stars\">4</p><p class=\"errors\"></p><p class=\"ignored\">owner</p><p class=\"owner\">nobody</p></form></body></html>")

    // A markup-shaped value goes through the serializer's escaping, not around
    // it: the model holds the bytes the user typed and the page renders them
    // escaped.
    let hostile: string = post(host, ticket.session,
                    body_with(ticket.token, "title=%3Cb%3Ehi&stars=2"))
    r.yes("a posted value is escaped where it renders",
          hostile.contains("<p class=\"title\">&lt;b&gt;hi</p>"))
    r.no("and no tag reaches the document", hostile.contains("<b>hi"))

    // ---- the field an int cannot hold -----------------------------------
    //
    // `stars=twelve` does not parse, so nothing is written to the model and
    // the model still says 0. Before `FormResult` kept the post, the page
    // re-rendered that 0 with "stars must be a whole number" printed beside
    // it: a message about text the user could no longer see, and their input
    // gone. The box must say `twelve`.
    let unparsed: string = post(host, ticket.session,
                                body_with(ticket.token, "title=Hi&stars=twelve"))
    r.eq("a value an int cannot hold comes back as it was typed",
         unparsed.replace(ticket.token, "<token>"),
         "200 <html><body><form method=\"post\" action=\"/notes/hello\"><input type=\"hidden\" name=\"__latte_token\" value=\"<token>\"><p class=\"title\">Hi</p><p class=\"stars\">twelve</p><p class=\"errors\">stars: stars must be a whole number</p><p class=\"ignored\"></p><p class=\"owner\">nobody</p></form></body></html>")

    // And the same value is escaped on the way back, because it takes the
    // serializer's text path like anything else. A framework that echoed the
    // post through a second route would have a second escaping question.
    let hostile_number: string = post(host, ticket.session,
                    body_with(ticket.token, "title=Hi&stars=%3Cimg+src%3Dx%3E"))
    r.yes("and an unparseable value is escaped where it comes back",
          hostile_number.contains("<p class=\"stars\">&lt;img src=x&gt;</p>"))
    r.no("no tag reaches the document from the echo either",
         hostile_number.contains("<img src=x>"))
}

// ---------------------------------------------------------------- § 3 the token

fn section_three(r: Report, host: espresso.TestHost, dial: Dial, ticket: Ticket) {
    io.println("")
    io.println("== 3. the antiforgery refusal, with the accepted case beside it ==")
    let body: string = "title=Hello&stars=4"

    // THE POSITIVE CONTROL. Every refusal below posts this same body to this
    // same page in this same session; the only thing that changes is the token.
    // Without this line, "refused" would be indistinguishable from "this page
    // refuses everything".
    let accepted: string = post(host, ticket.session, body_with(ticket.token, body))
    r.eq("the control: the page's own token is accepted",
         accepted.slice(0, 3), "200")
    r.yes("and the post reached the model",
          accepted.contains("<p class=\"title\">Hello</p>"))

    r.eq("no token at all", post(host, ticket.session, body),
         "400 {here()}.NotePage: the form carried no antiforgery token")
    r.eq("an empty token", post(host, ticket.session, body_with("", body)),
         "400 {here()}.NotePage: the form carried no antiforgery token")
    r.eq("a token that is not one", post(host, ticket.session, body_with("nonsense", body)),
         "400 {here()}.NotePage: the antiforgery token is malformed")
    r.eq("a token with one hex digit changed",
         post(host, ticket.session, body_with(flip_last(ticket.token), body)),
         "400 {here()}.NotePage: the antiforgery token does not match this session and form")

    // A token minted for the same form in a DIFFERENT session. This is the case
    // a check that never fed the session into the MAC would pass.
    match host.get("/notes/hello") {
        err(problem) => { r.eq("a second session", "error {problem.msg}", "200") }
        ok(reply) => {
            let other_session: string = session_in(reply)
            let other_token: string = token_in(reply.text())
            r.no("the second session is a different one", other_session == ticket.session)
            r.no("and so is its token", other_token == ticket.token)
            r.eq("the control: the second session's own token works there",
                 post(host, other_session, body_with(other_token, body)).slice(0, 3),
                 "200")
            r.eq("another session's token, in this one",
                 post(host, ticket.session, body_with(other_token, body)),
                 "400 {here()}.NotePage: the antiforgery token does not match this session and form")
        }
    }

    // The clock moves past the token's expiry. Nothing sleeps: the host reads
    // the clock this file holds.
    dial.now = 1900
    r.eq("the token at the moment it expires",
         post(host, ticket.session, body_with(ticket.token, body)),
         "400 {here()}.NotePage: the antiforgery token has expired")
    dial.now = 4000
    r.eq("long past its expiry",
         post(host, ticket.session, body_with(ticket.token, body)),
         "400 {here()}.NotePage: the antiforgery token has expired")

    // ...and the control for THAT: a token issued at the new time is accepted,
    // so "expired" is about the token and not about the clock having moved.
    match host.send_with_headers("GET", "/notes/hello", cookie_headers(ticket.session)) {
        err(problem) => { r.eq("a fresh GET", "error {problem.msg}", "200") }
        ok(reply) => {
            let fresh: string = token_in(reply.text())
            r.eq("a token issued at the new time", fresh.slice(0, 5), "4900.")
            r.eq("the control: it is accepted",
                 post(host, ticket.session, body_with(fresh, body)).slice(0, 3), "200")
        }
    }
    dial.now = 1000

    // A safe method carries no token and must not be asked for one.
    match host.send_with_headers("GET", "/notes/hello", cookie_headers(ticket.session)) {
        err(problem) => { r.eq("a GET with no token", "error {problem.msg}", "200") }
        ok(reply) => { r.eqi("a GET needs no token at all", reply.status, 200) }
    }

    // A post with no session cookie. The seam mints one, so the token the
    // client holds belongs to a session the server no longer sees.
    var headers: http.Headers = new http.Headers()
    headers.add("Content-Type", "application/x-www-form-urlencoded")
    match host.send_with_headers("POST", "/notes/hello", headers,
                                 body_with(ticket.token, body)) {
        err(problem) => { r.eq("a post with no cookie", "error {problem.msg}", "400") }
        ok(reply) => {
            r.eqi("a post carrying no session cookie", reply.status, 400)
            r.eq("and it is refused as a forgery, not as a missing session",
                 reply.text(),
                 "{here()}.NotePage: the antiforgery token does not match this session and form")
        }
    }
}

/// This file's own package name, as reflection reports it: an entry file
/// compiled inside a module is `<module>$entry`, not `main`.
fn here() -> string {
    let named: string = type_of(Note).qualified_name()
    match named.rfind(".") {
        some(at) => { return named.slice(0, at) }
        none => { return named }
    }
}

fn flip_last(token: string) -> string {
    let head: string = token.slice(0, token.len() - 1)
    let last: string = token.slice(token.len() - 1, token.len())
    if last == "0" { return "{head}1" }
    return "{head}0"
}

// ---------------------------------------------------------------- § 4 refusals

fn section_four(r: Report, host: espresso.TestHost, dial: Dial, pages: PageHost) {
    io.println("")
    io.println("== 4. a host whose scan refused something serves nothing ==")

    // The host answers from the maps it was given, and a host built over a map
    // carrying a fault must not serve the pages that happened to survive — the
    // one refusal that matters would be the one it served.
    var broken_forms: FormMap = new FormMap()
    broken_forms.faults.push("a form nobody fixed")
    let signer: Signer = new SeamSigner(hmac_signer("k"), same_bytes())
    let refused: PageHost = new PageHost(scan_pages(), broken_forms,
                                         new Antiforgery(signer, 900))
    var request: PageRequest = new PageRequest()
    request.method = "GET"
    request.path = "/about"
    let answer: PageResponse = refused.handle(request, 1000)
    r.eqi("a page a working host serves", pages.handle(request, 1000).status, 200)
    r.eqi("the same page, from a host whose scan refused something",
          answer.status, 500)
    r.eq("and it says what refused it", answer.detail(),
         "latte did not start: the scan refused this application | a form nobody fixed")

    io.println("-- the token's lifetime is the host's, not a constant")
    let brief: PageHost = new PageHost(scan_pages(), scan_forms(scan_pages()),
                                       new Antiforgery(signer, 30))
    var get: PageRequest = new PageRequest()
    get.method = "GET"
    get.path = "/notes/hello"
    get.session = "abc"
    let short_reply: PageResponse = brief.handle(get, 1000)
    r.eqi("a host with a thirty-second lifetime answers", short_reply.status, 200)
    r.eq("and its token expires in thirty seconds",
         token_in(short_reply.body).slice(0, 5), "1030.")
}
