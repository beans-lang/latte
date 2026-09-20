// `examples/board/main.b` — the Brew Board, a whole latte application.
//
//     beansc run examples/board/main.b -- serve 8080   # open http://127.0.0.1:8080/
//     beansc run examples/board/main.b -- check        # what the check runs
//
// Run it from the latte module root: the client script and the stylesheet are
// read relative to the working directory.
//
// ## What it is for
//
// `examples/cafe` is the reference for the seam — a served document, a content
// security policy, a form that works with JavaScript switched off. This one is
// the reference for everything above that seam:
//
//   * **a service container.** `Orders` and `Prices` are registered once; the
//     page's `init` takes an `Orders` and the container resolves it.
//   * **`@inject`.** `Ticket.prices` is filled at mount. No ancestor passes it.
//   * **`@memo`.** A row re-renders only when one of its parameters changed —
//     replacing a hand-written `ParamWatch` whose stringly-typed list was the
//     thing that went wrong.
//   * **a view-model.** `BoardModel` holds the state and the behaviour and has
//     no render tree in it, so it can be exercised without mounting anything.
//   * **a `Signal` and `live`.** `placed` patches one text node with no render
//     and no diff, and nothing calls `own(self)` — the framework does.
//   * **a `Command` with a guard**, asked to disable the button and asked again
//     when it runs.
//
// ## The stylesheet is real Tailwind
//
// `css/app.build.css` is built by `build-css.sh` from `css/app.css`, which
// scans the `.bx` files for the classes they use. It is committed, and it is
// served from memory — **not** from a CDN, because latte ships
// `style-src 'self'` with no `'unsafe-inline'` and a CDN stylesheet would be
// dropped by the policy latte itself sends. A demo that told you to disable the
// CSP to see it styled would be teaching the wrong thing.
package main

import github.com/beans-lang/barista
import github.com/beans-lang/espresso
import std.fs
import std.io
import std.os
import {LatteApp, LatteOptions, build_with} from latte_app
import {Board, BoardModel, Orders, Prices, Shell, Ticket} from board.site

const STYLESHEET: string = "examples/board/css/app.build.css"

/// The application, and every line of it is about a coffee shop.
fn options() -> Result<LatteOptions, string> {
    var options: LatteOptions = new LatteOptions()
    options.title = "Brew Board"
    // A fixed clock, so `check`'s antiforgery expiry is a pure function of
    // inputs this file picked and no test here reads a wall clock.
    options.now = 1000
    match fs.read(STYLESHEET) {
        ok(css) => { options.stylesheet("/app.css", css) }
        err(problem) => {
            return err("cannot read {STYLESHEET} ({problem.kind}) — run examples/board/build-css.sh")
        }
    }
    return ok(move options)
}

fn services() -> barista.ServiceCollection {
    var services: barista.ServiceCollection = new barista.ServiceCollection()
    // One book for the shop, one price list. Both singletons: they are the
    // application's own state, not a request's.
    services.singleton<Orders>().expect("orders")
    services.singleton<Prices>().expect("prices")
    return move services
}

fn start() -> Result<LatteApp, string> {
    let ready: LatteOptions = options()?
    return build_with(ready, services())
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
        match start() {
            err(problem) => { io.eprintln("BOARD-REFUSED {problem}") }
            ok(app) => {
                match app.serve(port) {
                    ok(_) => {}
                    err(problem) => { io.eprintln("BOARD-REFUSED {problem.msg}") }
                }
            }
        }
        return
    }
    if command != "check" {
        io.println("usage: main [check | serve <port>]")
        return
    }
    check()
}

// ============================================================== check

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
    pub fn yes(what: string, got: bool) { self.eq(what, "{got}", "true") }
    pub fn no(what: string, got: bool) { self.eq(what, "{got}", "false") }
    pub fn eqi(what: string, got: int, want: int) { self.eq(what, "{got}", "{want}") }
}

fn check() {
    let r: Report = new Report()
    io.println("== the brew board ==")
    io.println("")
    io.println("-- 0. the application starts")
    match start() {
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

    var web: espresso.WebApplication = new espresso.WebApplicationBuilder()
        .build().expect("the app builds")
    match app.web_on(web) {
        err(problem) => { io.println("FAIL mount: {problem.msg}"); return }
        ok(_) => {}
    }
    let host: espresso.TestHost = new espresso.TestHost(web)

    io.println("")
    io.println("-- 1. the document")
    match host.get("/") {
        err(problem) => { r.eq("1.0 GET /", "err {problem.msg}", "200") }
        ok(reply) => {
            let document: string = reply.text()
            r.eqi("1.1 status", reply.status, 200)
            r.yes("1.2 it is a document", document.starts_with("<!doctype html>\n"))
            r.yes("1.3 the stylesheet is served from this origin, not a CDN",
                  document.contains("<link rel=\"stylesheet\" href=\"/app.css\">"))
            r.no("1.4 and nothing is loaded from anywhere else",
                 document.contains("//cdn.") || document.contains("https://"))
            r.no("1.5 no inline style, which the CSP would drop anyway",
                 document.contains("<style"))
        }
    }

    match host.get("/app.css") {
        err(problem) => { r.eq("1.6 GET /app.css", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("1.6 the stylesheet is served", reply.status, 200)
            r.yes("1.7 it is real Tailwind output, not a hand-written subset",
                  reply.text().contains("tailwindcss.com"))
            r.yes("1.8 and it carries the classes the markup uses",
                  reply.text().contains("bg-amber-700"))
        }
    }

    io.println("")
    io.println("-- 2. the container built the page")
    // The page's `init` takes an `Orders`. Nothing on the page constructs one
    // and nothing passes one in.
    match host.get("/") {
        err(problem) => { r.eq("2.0 GET /", "err {problem.msg}", "200") }
        ok(reply) => {
            let document: string = reply.text()
            r.yes("2.1 the two orders the service starts with are on the page",
                  document.contains("flat white") && document.contains("cortado"))
            // `Ticket.prices` is @inject: no ancestor passed it down.
            r.yes("2.2 and a child component priced them from an injected service",
                  document.contains("£3.20") && document.contains("£2.80"))
        }
    }

    io.println("")
    io.println("-- 3. the view-model, with no page mounted at all")
    // A view-model has no render tree, which is the whole reason to have one:
    // its behaviour is exercised here without a Renderer, a Builder or a
    // document anywhere in sight.
    let orders: Orders = new Orders()
    let model: BoardModel = new BoardModel(orders)
    r.no("3.1 an empty draft is not ready", model.ready())
    model.draft = "  "
    r.no("3.2 and neither is whitespace", model.ready())
    model.draft = " mocha "
    r.yes("3.3 a real one is", model.ready())
    r.eqi("3.4 the board starts with what the service had", model.total(), 2)

    io.println("")
    io.println("-- 4. a price nobody wrote down")
    let prices: Prices = new Prices()
    r.eqi("4.1 a known drink", prices.of("cortado"), 280)
    r.eqi("4.2 and one that is not on the list still has a price",
          prices.of("something else"), 250)

    match host.close() {
        ok(_) => {}
        err(problem) => { io.println("FAIL closing the host: {problem.msg}") }
    }
}
