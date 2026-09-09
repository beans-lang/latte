// `latte_app` — the composition root every latte application used to write by
// hand.
//
// Before this, `examples/cafe/main.b` was 248 lines of application, of which
// about 25 were about a cafe. The other ~210 would have been byte-identical in
// every latte application ever written: the scan-and-refuse pass, the signing
// key, the one `Antiforgery` shared between two halves that must agree, two
// `ShellOptions`, the circuit's page factory, five espresso mount calls in an
// order nothing enforced, a nine-closure seam, and an origin list that can only
// be built after the kernel has chosen a port.
//
// ## Why this is a module and not a package under `latte/`
//
// A package under a module may not import its own module root. That is why
// `latte.web` cannot name `CircuitSet` or `ShellOptions`, and why a
// `CircuitSeam` arrives as nine closures over `int` and `string`: the two
// halves of latte can only meet somewhere that may import both, and until now
// the only such place was the application's own root file. A separate module
// may import both. So the meeting moved here.
//
// ## What it will not do
//
// It does not hide latte. `LatteApp` hands back its `PageMap`, its `PageHost`,
// its `CircuitSet` and both `ShellOptions`; a host that wants to mount latte
// beside its own routes calls `mount` and keeps its own `WebApplication`. The
// point is that nobody has to *assemble* those correctly, not that nobody may
// see them.
package latte_app

import barista
import espresso
import std.io
import std.os
import std.time
import std.reflect
import {Activator, Anonymous, Antiforgery, CircuitOptions, CircuitSet,
        Component, FormComponent, FormMap, FormState, PageHost, PageInstance,
        PageMap, PageRequest, PageResponse, Principal, ShellOptions, Signer,
        SeamSigner, NO_POLLER_MESSAGE, is_safe_method, open_page, render_shell,
        scan_forms, scan_pages} from latte
import {run} from latte.boundary
import {CircuitSeam, ClientOptions, EndpointOptions, HeaderOptions, WebRequest,
        WebReply, SOCKET_PATH, fresh_id, has_fiber_poller, hmac_signer,
        map_asset, map_circuit, map_client, map_pages, same_bytes,
        security_headers} from latte.web

// ============================================================== assets

/// One file served from memory.
///
/// A latte application's assets are small and known at startup — a stylesheet,
/// a favicon, a sprite. There is no directory serving here on purpose: a route
/// that reads from disk per request is a different feature with a different
/// set of mistakes in it, and `map_asset` already answers a fixed body with an
/// entity tag and a conditional request.
pub class Asset {
    pub path: string = ""
    pub body: string = ""
    pub content_type: string = ""
    pub cache: string = "no-cache"
    pub fn init(path: string, body: string, content_type: string) {
        self.path = path
        self.body = body
        self.content_type = content_type
    }
}

// ============================================================== options

/// Everything an application chooses. Every field has a default that is safe
/// rather than convenient — see `contain_panics` and `origins`.
pub class LatteOptions {
    pub title: string = "latte"
    pub lang: string = "en"
    /// Stylesheet URLs for the document head. `stylesheet()` adds one of these
    /// and the asset that serves it in one call.
    pub stylesheets: List<string> = []
    pub assets: List<Asset> = []

    pub idle_ms: int = 600000
    pub retention_ms: int = 600000
    pub poll_ms: int = 100
    pub socket_ms: int = 60000
    /// How long an antiforgery token stays valid.
    pub token_seconds: int = 900

    /// `Secure` on the session cookie. Off by default because the default
    /// deployment a person tries first is plain http on localhost, and a
    /// browser silently DROPS a `Secure` cookie there — which presents as
    /// "latte does not keep a session" rather than as a configuration
    /// mistake. Turn it on with TLS in front.
    pub secure_cookies: bool = false

    /// Run every event handler inside latte's error boundary.
    ///
    /// **On by default, and that is the whole reason this option exists.**
    /// `CircuitSet.guard` defaults to running a handler with no containment at
    /// all, so an application that forgot one line turned a panic in a click
    /// into a dead worker. A default that unsafe belongs to the framework.
    pub contain_panics: bool = true

    /// The clock the antiforgery expiry is measured against. `0` reads the
    /// wall clock; any other value is used as-is, which is what a golden-file
    /// test wants so its token is a pure function of inputs it chose.
    pub now: int = 0

    pub fn init() {}

    /// Serve `css` at `path` and reference it from the document head.
    ///
    /// Both halves in one call because they are one decision, and because a
    /// stylesheet referenced but not served is a page that renders unstyled
    /// with nothing in the log.
    pub fn stylesheet(path: string, css: string) {
        self.assets.push(new Asset(path, css, "text/css; charset=utf-8"))
        self.stylesheets.push(path)
    }

    /// Serve a fixed body at a fixed path.
    pub fn asset(path: string, body: string, content_type: string) {
        self.assets.push(new Asset(path, body, content_type))
    }
}

// ============================================================== the activator

/// latte's `Activator`, backed by a barista provider.
///
/// `latte.pages` has declared this seam since the beginning and **nothing has
/// ever implemented it**: every one of the ~20 `open_page` call sites in latte,
/// its tests and its examples passed `none`, so the only route that ever ran
/// was the cached zero-argument initializer. Which meant a page whose `init`
/// takes a repository could not be activated at all.
///
/// `provider.activate` resolves each of the initializer's parameters from the
/// provider and calls it. The page type itself needs **no registration** —
/// only its constructor's parameters do — so mounting caller-written page
/// types does not turn every one of them into a service.
pub class ContainerActivator implements Activator {
    provider: barista.ServiceProvider

    pub fn init(provider: barista.ServiceProvider) {
        self.provider = provider
    }

    pub fn make(described: reflect.Type) -> Result<reflect.Value, string> {
        match self.provider.activate(described) {
            ok(value) => { return ok(value) }
            err(problem) => { return err(problem.msg) }
        }
    }
}

// ============================================================== the factory

/// The page a circuit renders for a URL.
///
/// This is the thing every application used to write, and it is worth saying
/// why it is not obvious. A circuit's `attach` carries a url and nothing else,
/// so the page has to be looked up and rendered again — through the SAME
/// `PageMap` and `open_page` the HTTP half uses, or a circuit could answer a
/// route the server does not have and skip the authorization `open_page`
/// re-checks.
///
/// **And the token has to be minted here or the form is dead.** `PageHost`
/// gives every safe request's form page a fresh `FormState` with a token bound
/// to that request's session. A circuit renders the same page through
/// `open_page` and never touches `PageHost`, so without this the form the
/// browser ends up holding carries `value=""` and the post it makes is
/// answered `400 the form carried no antiforgery token`.
///
/// It holds the pieces it needs rather than the application, so the closure
/// `CircuitSet` keeps does not point back at the object that owns the set.
pub class PageFactory {
    pages: PageMap
    anti: Antiforgery
    /// How a page is constructed. `none` is the cached zero-argument
    /// initializer; a container-backed one lets a page's `init` take services.
    pub activator: Option<Activator> = none
    pub who: Principal = new Anonymous()
    pub now: int = 0

    fn init(pages: PageMap, anti: Antiforgery) {
        self.pages = pages
        self.anti = anti
    }

    fn clock() -> int {
        if self.now != 0 { return self.now }
        // std.time has no unix_seconds; the wall clock is in nanoseconds.
        return time.wall_nanos() / 1000000000
    }

    pub fn page_for(session: string, url: string) -> Option<Component> {
        match self.pages.find("GET", path_only(url)) {
            none => { return none }
            some(found) => {
                let instance: PageInstance =
                    open_page(found, self.who, self.activator)
                if !instance.ok() { return none }
                // `instance.component` and not `instance.root()`: the root is
                // the outermost LAYOUT when the page has one, and the form is
                // the page.
                match instance.component {
                    some(page) => {
                        match page as? FormComponent {
                            some(form_page) => {
                                form_page.state = new FormState()
                                form_page.state.token = self.anti.issue(
                                    session, form_page.form_id(), self.clock())
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

// ============================================================== the app

/// A whole latte application, assembled.
///
/// Every field is built. There is no `Option` here and no half-state: `build`
/// either answers an application whose page table, form table, shell and
/// circuit are all decided, or it answers the reason it could not — once,
/// before a socket exists.
pub class LatteApp {
    pub pages: PageMap
    pub forms: FormMap
    pub host: PageHost
    pub anti: Antiforgery
    pub set: CircuitSet
    pub factory: PageFactory
    pub shell: ShellOptions
    /// The shell for a response a circuit could not produce — a POST answer.
    /// Same document, `circuit = false`, so the client script is still served
    /// and no socket is opened over an answer the user is reading.
    pub static_shell: ShellOptions
    pub options: LatteOptions
    /// Frozen: `build` calls `build_provider()`, so registering after an
    /// application exists is an error rather than a silent no-op. Fill it in
    /// with `build_with`.
    pub services: barista.ServiceCollection
    /// The root provider. Singletons live here for the life of the process;
    /// `create_scope()` gives a request or a circuit its own.
    pub provider: barista.ServiceProvider

    pub pages_served: int = 0
    pub stops: int = 0
    pub stopper: Option<espresso.ServerControl> = none

    fn init(pages: PageMap, forms: FormMap, host: PageHost, anti: Antiforgery,
            set: CircuitSet, factory: PageFactory, shell: ShellOptions,
            static_shell: ShellOptions, options: LatteOptions,
            services: barista.ServiceCollection,
            provider: barista.ServiceProvider) {
        self.pages = pages
        self.forms = forms
        self.host = host
        self.anti = anti
        self.set = set
        self.factory = factory
        self.shell = shell
        self.static_shell = static_shell
        self.options = options
        self.services = services
        self.provider = provider
    }

    /// Who the next request is from. A real deployment sets this per request
    /// through its own middleware; the default is `Anonymous`.
    pub fn identify(who: Principal) {
        self.factory.who = who
    }

    fn now() -> int {
        if self.options.now != 0 { return self.options.now }
        // std.time has no unix_seconds; the wall clock is in nanoseconds.
        return time.wall_nanos() / 1000000000
    }

    /// Mount this application on an espresso app.
    ///
    /// The order is the whole design of the pipeline, and it is here so that
    /// nobody has to get it right twice:
    ///
    ///  1. `security_headers` FIRST, so it is outermost and sets its headers
    ///     after everything else has answered — a page, a 404, a 500, an asset.
    ///  2. the assets, which are exact paths and answer before anything looks
    ///     at a route table.
    ///  3. `map_pages`, which owns latte's route table and falls through to
    ///     `next` for a path no `@page` claims — so the host's own routes still
    ///     work.
    ///  4. `map_circuit`, on espresso's upgrade table, which the whole pipeline
    ///     above runs before.
    pub fn mount(web: espresso.WebApplication,
                 endpoint: EndpointOptions) -> Result<bool> {
        web.use(security_headers(new HeaderOptions()))?

        var client: ClientOptions = new ClientOptions()
        map_client(web, client)?
        for asset: Asset in self.options.assets {
            map_asset(web, asset.path, asset.body, asset.content_type,
                      asset.cache)?
        }

        let host: PageHost = self.host
        let shell: ShellOptions = self.shell
        let static_shell: ShellOptions = self.static_shell
        let who: Principal = self.factory.who
        let when: int = self.now()
        let counter: LatteApp = self
        map_pages(web, fn(request: WebRequest) -> Option<WebReply> {
            var asked: PageRequest = new PageRequest()
            asked.method = request.method
            asked.path = request.path
            asked.body = request.body
            asked.session = request.session
            asked.who = who
            let answer: PageResponse = host.handle(asked, when)
            // A 404 with no allowed methods is "latte has no page here" — hand
            // it back to espresso so the application's own routes still work.
            if answer.status == 404 && answer.allowed.len() == 0 { return none }

            var reply: WebReply = new WebReply()
            reply.status = answer.status
            reply.allow = answer.allowed.join(", ")
            if answer.status != 200 {
                reply.body = answer.detail()
                reply.content_type = "text/plain; charset=utf-8"
                return some(reply)
            }
            counter.pages_served += 1
            var used: ShellOptions = shell
            if !is_safe_method(asked.method) { used = static_shell }
            match render_shell(used, answer.body) {
                ok(document) => { reply.body = document }
                err(problem) => {
                    reply.status = 500
                    reply.body = problem
                    reply.content_type = "text/plain; charset=utf-8"
                }
            }
            return some(reply)
        }, self.options.secure_cookies)?

        endpoint.poll_ms = self.options.poll_ms
        endpoint.socket_ms = self.options.socket_ms
        endpoint.no_poller_message = NO_POLLER_MESSAGE

        let set: CircuitSet = self.set
        let seam: CircuitSeam = new CircuitSeam(
            set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
            set.tick_fn(), set.ending_fn(), set.disconnect_fn(),
            set.resume_fn(), set.wake_fn())
        map_circuit(web, SOCKET_PATH, seam, endpoint)?
        return ok(true)
    }

    /// Build an espresso application with this latte application on it.
    pub fn web(endpoint: EndpointOptions) -> Result<espresso.WebApplication> {
        let builder: espresso.WebApplicationBuilder =
            new espresso.WebApplicationBuilder()
        let web: espresso.WebApplication = builder.build()?
        self.mount(web, endpoint)?
        return ok(web)
    }

    /// Bind, announce the port, and serve until stopped.
    ///
    /// The origin allowlist is filled in from the port the kernel chose, which
    /// is the one part of this that cannot be decided earlier and the one an
    /// application most often got wrong: an EMPTY list refuses every handshake
    /// carrying an `Origin`, so a circuit never connects and nothing says why.
    pub fn serve(port: int) -> Result<bool> {
        return self.serve_with(
            port, fn(web: espresso.WebApplication) -> Result<bool> { return ok(true) })
    }

    /// `serve`, with a chance to add routes of your own to the application
    /// latte mounted itself on.
    ///
    /// The closure runs after latte is mounted and before the socket is bound,
    /// which is the only window where both are true. A path no `@page` claims
    /// falls through `map_pages` to the router, so a route added here is
    /// reachable.
    pub fn serve_with(port: int,
                      extra: fn(espresso.WebApplication) -> Result<bool>) -> Result<bool> {
        if !has_fiber_poller() {
            io.eprintln("LATTE-UNAVAILABLE {NO_POLLER_MESSAGE}")
            return ok(false)
        }
        var endpoint: EndpointOptions = new EndpointOptions()
        let web: espresso.WebApplication = self.web(endpoint)?
        extra(web)?

        var server_options: espresso.ServerOptions = new espresso.ServerOptions()
        server_options.port = port
        server_options.poll_timeout_ms = 25
        let server: espresso.WebServer =
            espresso.WebServer.bind(web, server_options)?
        let chosen: int = server.port()?

        // Both spellings, because a browser sends the host exactly as it was
        // typed and `localhost` and `127.0.0.1` are different origins.
        endpoint.origins = ["http://127.0.0.1:{chosen}",
                            "http://localhost:{chosen}"]
        self.stopper = some(server.control())

        // stderr, and not stdout: `std.io` has no flush, stdout to a pipe is
        // fully buffered, and the port line would sit in a 64 KiB buffer until
        // the process exits — that is, until after the harness gave up waiting
        // for it.
        io.eprintln("LATTE-PORT {chosen}")
        let stats: espresso.ServerStats = server.run()?
        io.eprintln("LATTE-PAGES {self.pages_served}")
        io.eprintln("LATTE-UPGRADES {stats.upgrades}")
        io.eprintln("LATTE-HELD {self.set.count()}")
        io.eprintln("LATTE-FAULTS {self.set.faults.len()}")
        for fault: string in self.set.faults { io.eprintln("LATTE-FAULT {fault}") }
        io.eprintln("LATTE-DONE")
        return ok(true)
    }

    /// Ask a running server to stop.
    pub fn stop() {
        self.stops += 1
        match self.stopper {
            some(control) => { let asked: bool = control.stop().or(false) }
            none => {}
        }
    }
}

// ============================================================== build

/// Scan, check, and refuse to go any further if anything is wrong.
///
/// A latte application that starts with a bad page table serves the pages that
/// happened to survive, and the refusal that matters is the one it skipped.
/// Everything is decided here, once, before a socket exists.
pub fn build(options: LatteOptions) -> Result<LatteApp, string> {
    var services: barista.ServiceCollection = new barista.ServiceCollection()
    return build_with(options, services)
}

/// `build`, with a service collection the caller has already filled in.
pub fn build_with(options: LatteOptions,
                  services: barista.ServiceCollection) -> Result<LatteApp, string> {
    let pages: PageMap = scan_pages()
    if pages.report() != "" { return err(pages.report()) }
    let forms: FormMap = scan_forms(pages)
    if forms.report() != "" { return err(forms.report()) }

    // The signing key. A real deployment reads it from its configuration; a
    // constant here would be a key in a public repository, so this one is
    // fresh per process.
    var key: string = ""
    match fresh_id() {
        ok(value) => { key = value }
        err(problem) => { return err("no CSPRNG: {problem.kind}") }
    }
    let signer: Signer = new SeamSigner(hmac_signer(key), same_bytes())
    // ONE `Antiforgery`, shared. The circuit's page factory mints tokens the
    // HTTP half will check, so a second instance would only be right for as
    // long as nobody changed a lifetime in one of the two places.
    let anti: Antiforgery = new Antiforgery(signer, options.token_seconds)
    let host: PageHost = new PageHost(pages, forms, anti)

    var shell: ShellOptions = new ShellOptions()
    shell.title = options.title
    shell.lang = options.lang
    shell.stylesheets = options.stylesheets.clone()
    var static_shell: ShellOptions = new ShellOptions()
    static_shell.title = options.title
    static_shell.lang = options.lang
    static_shell.stylesheets = options.stylesheets.clone()
    static_shell.circuit = false

    var faults: List<string> = shell.faults()
    for problem: string in static_shell.faults() { faults.push(problem) }
    if faults.len() > 0 { return err(faults.join(" | ")) }

    let provider: barista.ServiceProvider = services.build_provider()

    let factory: PageFactory = new PageFactory(pages, anti)
    factory.now = options.now
    // A circuit resolves from the ROOT provider, not from a scope, and that is
    // a boundary rather than an oversight. A circuit's components live as long
    // as the socket, so a scope opened for one would have to be closed when the
    // circuit ends — and latte has no hook for that yet (`CircuitSet` publishes
    // `ending_fn` and `disconnect_fn`, so it is buildable, and it is not built).
    // Rather than leak a scope per circuit, a circuit gets singletons; asking
    // it for a `scoped` service is refused by barista's own rule, by name:
    // "scoped service X cannot be resolved from the root provider".
    //
    // **What would remove this:** a per-circuit scope created on open and
    // closed on ending, which is the same shape espresso already uses per
    // request. It belongs with the view-model work, where a circuit-lifetime
    // object is the point rather than an accident.
    factory.activator = some(new ContainerActivator(provider))

    var circuit_options: CircuitOptions = new CircuitOptions()
    circuit_options.idle_ms = options.idle_ms
    circuit_options.retention_ms = options.retention_ms
    let set: CircuitSet = new CircuitSet(circuit_options,
        fn(facts: Map<string, string>, url: string) -> Option<Component> {
            var session: string = ""
            match facts.get("session") { some(value) => { session = value } none => {} }
            return factory.page_for(session, url)
        })
    if options.contain_panics { set.guard = run }

    return ok(new LatteApp(pages, forms, host, anti, set, factory, shell,
                           static_shell, options, services, provider))
}

// ============================================================== main

/// The whole of an application's `main`, for an application that wants no more
/// than the defaults.
///
/// **The default is `check`, not `serve`.** An entry whose default was a
/// listening socket would hang a golden-file gate for ever the day its
/// arguments went missing — green, because nothing would ever come back to be
/// red. Failing towards the deterministic mode costs a person eight characters
/// and cannot silence a gate.
pub fn run_main(options: LatteOptions) {
    let args: List<string> = os.args()
    var command: string = "check"
    if args.len() > 0 { command = args[0] }
    if command == "serve" {
        var port: int = 8080
        if args.len() > 1 {
            match args[1].to_int() { ok(value) => { port = value } err(_) => {} }
        }
        match build(options) {
            err(problem) => { io.eprintln("LATTE-REFUSED {problem}") }
            ok(app) => {
                match app.serve(port) {
                    ok(_) => {}
                    err(problem) => { io.eprintln("LATTE-REFUSED {problem.msg}") }
                }
            }
        }
        return
    }
    if command != "check" {
        io.println("usage: main [check | serve <port>]")
        return
    }
    match build(options) {
        err(problem) => { io.println("latte refused to start: {problem}") }
        ok(app) => {
            io.println("latte ok: {app.pages.pages.len()} page(s), {app.forms.forms.len()} form(s)")
        }
    }
}
