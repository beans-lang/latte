// A page whose `init` takes services, and what each lifetime means for it.
//
//     beansc run examples/injected/main.b -- check
//
// latte declared this seam — `pages.b:Activator` — from the beginning, and
// **nothing ever implemented it**: every `open_page` call site in latte, its
// tests and its examples passed `none`, so the only route that ever ran was the
// cached zero-argument initializer, and a page whose `init` took a repository
// could not be activated at all. `latte_app` supplies a barista-backed
// activator now, and this is what that buys.
//
// The counters are the point. `Menu` is a singleton, so it is built once for
// the process however many requests arrive. `Visit` is scoped, so it is built
// once per request — which is only true because `latte_app` opens a scope per
// request and releases it after the response, and this file is what proves it
// rather than asserting it.
package main

import barista
import espresso
import std.io
import {Builder, Component, page} from latte
import {LatteApp, LatteOptions, build_with} from latte_app

// ---------------------------------------------------------------- services

pub interface Menu {
    fn first() -> string
}

/// One per process.
@barista.service(lifetime: barista.ServiceLifetime.singleton)
pub class FixedMenu implements Menu {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        FixedMenu.made += 1
        self.tag = FixedMenu.made
    }
    pub fn first() -> string { return "espresso" }
}

/// One per request. Its constructor takes the singleton, so this also shows a
/// service resolving another service.
@barista.service
pub class Visit {
    static made: int = 0
    menu: Menu
    pub id: int = 0
    pub fn init(menu: Menu) {
        self.menu = menu
        Visit.made += 1
        self.id = Visit.made
    }
    pub fn greeting() -> string { return "{self.menu.first()} #{self.id}" }
}

// ---------------------------------------------------------------- the page

/// The page asks for both. Neither is a `@param` and neither is threaded down
/// from anywhere: they arrive because the container built the page.
@page(route: r"/")
pub class Home extends Component {
    menu: Menu
    visit: Visit

    pub fn init(menu: Menu, visit: Visit) {
        self.menu = menu
        self.visit = visit
    }

    pub override fn render(b: Builder) {
        b.open(0, "p")
        b.text(1, "{self.visit.greeting()}")
        b.close()
    }
}

// ---------------------------------------------------------------- the check

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("FAIL {what}: got [{got}], want [{want}]") }
}

fn body_of(reply: espresso.TestResponse) -> string {
    let text: string = reply.text()
    match text.find("<p>") {
        none => { return "no paragraph" }
        some(at) => {
            let rest: string = text.slice(at + 3, text.len())
            match rest.find("</p>") {
                none => { return "unterminated" }
                some(end) => { return rest.slice(0, end) }
            }
        }
    }
}

fn main() {
    var options: LatteOptions = new LatteOptions()
    options.title = "Injected"
    options.now = 1000

    var services: barista.ServiceCollection = new barista.ServiceCollection()
    let found: int = barista.add_services(services).expect("scan services")
    io.println("== a page built by the container ==")
    report("services discovered", "{found}", "2")

    match build_with(options, services) {
        err(problem) => { io.println("FAIL the application did not start: {problem}") }
        ok(app) => { drive(app) }
    }
}

fn drive(app: LatteApp) {
    report("the page scan accepted a page whose init takes services",
           app.pages.report(), "")

    var endpoint: espresso.WebApplication = new espresso.WebApplicationBuilder()
        .build().expect("the app builds")
    match app.web_on(endpoint) {
        err(problem) => { io.println("FAIL mount: {problem.msg}"); return }
        ok(_) => {}
    }
    let host: espresso.TestHost = new espresso.TestHost(endpoint)

    // Three requests. The singleton is built once across all of them; the
    // scoped service is built once per request, and its id counts up.
    match host.get("/") {
        ok(reply) => { report("request 1", body_of(reply), "espresso #1") }
        err(problem) => { io.println("FAIL request 1: {problem.msg}") }
    }
    match host.get("/") {
        ok(reply) => { report("request 2", body_of(reply), "espresso #2") }
        err(problem) => { io.println("FAIL request 2: {problem.msg}") }
    }
    match host.get("/") {
        ok(reply) => { report("request 3", body_of(reply), "espresso #3") }
        err(problem) => { io.println("FAIL request 3: {problem.msg}") }
    }

    report("the singleton was built once for three requests",
           "{FixedMenu.made}", "1")
    report("the scoped service was built once per request",
           "{Visit.made}", "3")

    match host.close() {
        ok(_) => {}
        err(problem) => { io.println("FAIL closing the host: {problem.msg}") }
    }
}
