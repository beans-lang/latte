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

import github.com/beans-lang/barista
import github.com/beans-lang/espresso
import std.io
import std.os
import std.time
import std.reflect
import {Activator, Anonymous, Antiforgery, CircuitOptions, CircuitSet,
        Component, FormComponent, FormMap, FormState, PageHost, PageInstance,
        PageMap, PageRequest, PageResponse, Principal, ServiceSource,
        ShellOptions, Signer, SeamSigner, NO_POLLER_MESSAGE, is_safe_method,
        Island, Islands, ModeScan, PersistOptions, PersistState, RenderMode,
        ViewModel, ActionMap, ActionRequest, ActionReply, TokenOutcome,
        ACTION_FORBIDDEN, ACTION_FORM_ID, ACTION_INVALID, ACTION_REFUSED,
        ACTION_STALE, ACTION_UNKNOWN,
        CLIENT_BUNDLE_PATH, CLIENT_MODULE_SCRIPT,
        describe_island, describe_token, open_page,
        pack_state, render_shell, restore_models, run_action, scan_actions,
        scan_forms, scan_injections,
        scan_memo, scan_pages_for, scan_persist, scan_render_modes} from latte
import {run} from latte.boundary
import {ActionAnswer, ActionOptions, CircuitSeam, ClientOptions,
        EndpointOptions, HeaderOptions, WebRequest,
        WebReply, SOCKET_PATH, fresh_id, has_fiber_poller, hmac_signer,
        map_actions, map_asset, map_circuit, map_client, map_pages, same_bytes,
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
    /// wall clock; any other value is used as-is, which is what an expected output-file
    /// test wants so its token is a pure function of inputs it chose.
    pub now: int = 0

    /// What a page may carry across a prerender into the attach that follows.
    ///
    /// **Off by default.** An island is bytes in every document, and an
    /// application whose pages have no `@persist` field would carry the cost
    /// of a feature it does not use. Turn it on and the POST answer for a page
    /// whose view-model persists something arrives with its state sealed into
    /// the markup.
    pub persist: bool = false
    pub persist_options: PersistOptions = new PersistOptions()

    /// The WebAssembly bundle this application's `client` regions run in, as
    /// a path on disk. Empty means latte serves none.
    ///
    /// It is a path and not bytes because it is read once, at startup, the
    /// way `js/latte.js` is — and because a deployment started in the wrong
    /// directory should fail then, with the path in the message, rather than
    /// serve a 404 that looks like a browser problem.
    pub client_module: string = ""

    /// Where the page points at the bundle. Empty means latte's own path,
    /// which is where `client_module` is served.
    ///
    /// Set it WITHOUT `client_module` when something else serves the bundle
    /// — a CDN, a reverse proxy, a static directory — and latte should
    /// write the script tag and nothing more. Setting neither, in an
    /// application that has a `client` region, is refused at startup.
    pub client_url: string = ""

    /// The directory the region runtime's loader and its imports are read
    /// from. The default is `js/`, beside `js/latte.js`; a deployment that
    /// stages its assets elsewhere says so.
    pub client_loader: string = ""

    /// The application-wide default execution mode, inherited by every
    /// component that declares none.
    ///
    /// `server` is what latte did before modes existed, so an application
    /// that names nothing renders exactly the bytes it rendered before.
    pub render_mode: RenderMode = RenderMode.server

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
/// It answers both of latte's service questions, because they are two
/// questions about one provider.
///
/// `Activator.make` **constructs** a type the container does not have to know
/// about — a page — resolving only what its initializer asks for.
/// `ServiceSource.provide` **resolves** a type the container does know about —
/// an `@inject` field on a component. One class, two interfaces, so a host
/// hands the same object to both seams; a single interface would have had to
/// mean both things, and a downcast between them is refused natively
/// (beans-lang/beans#195).
pub class Container implements Activator, ServiceSource {
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

    pub fn provide(described: reflect.Type) -> Result<reflect.Value, string> {
        match self.provider.resolve_type(described) {
            ok(value) => { return ok(value) }
            err(problem) => { return err(problem.msg) }
        }
    }

    pub fn knows(described: reflect.Type) -> bool {
        return self.provider.provides(described)
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

/// Release a request scope, if one was opened. A free function because
/// `defer` takes a call and this one has to be safe with `none`.
fn close_scope(scope: Option<barista.ServiceProvider>) {
    match scope {
        some(held) => { let closed: Result<bool> = held.close() }
        none => {}
    }
}

/// A copy of a shell's options.
///
/// Two requests are served by two fibers on one worker; writing a per-request
/// field into the shared `ShellOptions` would put one request's island in
/// another's document. There is no derived `clone` here because `ShellOptions`
/// is a class an application also configures by hand, and a `Clone` on it would
/// be a promise about every field it ever grows.
fn copy_shell(from: ShellOptions) -> ShellOptions {
    var out: ShellOptions = new ShellOptions()
    out.lang = from.lang
    out.title = from.title
    out.root_id = from.root_id
    out.script = from.script
    out.socket = from.socket
    out.circuit = from.circuit
    out.circuit_id = from.circuit_id
    out.stylesheets = from.stylesheets.clone()
    out.state = from.state
    out.client_script = from.client_script
    out.client_module = from.client_module
    out.action_token = from.action_token
    return move out
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
    /// Every `@action` in the executable. Empty for an application that
    /// declares none, and then no route is registered and no page carries a
    /// token.
    pub actions: ActionMap = new ActionMap()
    pub anti: Antiforgery
    pub set: CircuitSet
    pub factory: PageFactory
    pub islands: Islands
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
    /// Islands that could not be sealed, in the words a log wants. A page whose
    /// state grew past `max_bytes` is here and nowhere else.
    pub persist_faults: List<string> = []
    pub stopper: Option<espresso.ServerControl> = none

    fn init(pages: PageMap, forms: FormMap, host: PageHost, anti: Antiforgery,
            set: CircuitSet, factory: PageFactory, islands: Islands,
            shell: ShellOptions, static_shell: ShellOptions,
            options: LatteOptions, services: barista.ServiceCollection,
            provider: barista.ServiceProvider) {
        self.pages = pages
        self.forms = forms
        self.host = host
        self.anti = anti
        self.set = set
        self.factory = factory
        self.islands = islands
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
        var headers: HeaderOptions = new HeaderOptions()
        // Compiling WebAssembly is script execution as far as CSP is
        // concerned, and `script-src 'self'` alone does not allow it — Chrome
        // refuses `WebAssembly.instantiate` outright without this word, and
        // the failure is a region that never mounts with one line in the
        // console. It is added only for an application that ships a bundle,
        // so a page with no client region keeps exactly the policy it had.
        if self.shell.client_module != "" {
            headers.script.push("'wasm-unsafe-eval'")
        }
        web.use(security_headers(headers))?

        var client: ClientOptions = new ClientOptions()
        client.bundle_file = self.options.client_module
        // The loader is served whenever a page points at a bundle, even when
        // something else serves the bundle itself.
        client.serve_loader = self.shell.client_module != ""
        if self.options.client_loader != "" {
            client.module_dir = self.options.client_loader
        }
        map_client(web, client)?
        for asset: Asset in self.options.assets {
            map_asset(web, asset.path, asset.body, asset.content_type,
                      asset.cache)?
        }

        let holder: LatteApp = self
        // The action route BEFORE the pages, because `/_latte/action/...` is
        // latte's path and the page table must never be asked about it. It
        // used to sit after, and `map_pages` answered every action with 415:
        // it reads a urlencoded body and an action's is JSON.
        if self.actions.plans.len() > 0 {
            var action_options: ActionOptions = new ActionOptions()
            map_actions(web, action_options,
                fn(name: string, body: string, token: string,
                   session: string) -> ActionAnswer {
                    return holder.act(name, body, token, session)
                })?
        }

        map_pages(web, fn(request: WebRequest) -> Option<WebReply> {
            return holder.answer(request)
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

    /// Answer one action call.
    ///
    /// The three checks the browser cannot be trusted with happen here, in
    /// this order and before the action is looked up:
    ///
    ///  1. **The antiforgery token.** Bound to the session cookie, so a token
    ///     lifted off another user's page verifies against the wrong session
    ///     and is refused.
    ///  2. **The authorization**, from the `@action`'s own requirements, by
    ///     `run_action`.
    ///  3. **Every argument's type**, also by `run_action`, against the
    ///     method's declared parameters.
    ///
    /// A scope per call, released on every exit, exactly as a page gets: an
    /// action group is built by the container and a `scoped` service inside
    /// it must not outlive the call that asked for it.
    fn act(name: string, body: string, token: string,
           session: string) -> ActionAnswer {
        let outcome: TokenOutcome = self.anti.check(token, session,
                                                    ACTION_FORM_ID, self.now())
        match outcome {
            valid => {}
            _ => {
                var refusal: ActionReply = new ActionReply()
                refusal.kind = ACTION_STALE
                refusal.message = "this call's antiforgery token {describe_token(outcome)}; reload the page"
                return new ActionAnswer(403, refusal.encode())
            }
        }

        var scope: Option<barista.ServiceProvider> = none
        var activator: Option<Activator> = none
        if self.provider.has_registrations() {
            match self.provider.create_scope() {
                ok(made) => {
                    scope = some(made)
                    activator = some(new Container(made))
                }
                err(problem) => {}
            }
        }
        defer close_scope(scope)

        var asked: ActionRequest = new ActionRequest()
        asked.name = name
        asked.arguments = body
        asked.who = self.factory.who
        asked.token = token
        asked.session = session
        let reply: ActionReply = run_action(self.actions, asked, activator)
        return new ActionAnswer(status_for_action(reply.kind), reply.encode())
    }

    /// Answer one HTTP request, in its own service scope.
    ///
    /// **The scope is why this is a method and not the closure it used to be.**
    /// A `scoped` service must be built once per request and released after it,
    /// and the release has to happen on every exit — the 404 fall-through, the
    /// non-200 reply, the shell that failed to render. `defer` does that, and
    /// `defer` must sit at the top level of a function body, which a closure
    /// with four returns in it could not offer.
    ///
    /// The scope is opened only when something is registered. An application
    /// with no services allocates nothing per request, which is the difference
    /// between DI costing what it costs and DI costing something for people who
    /// do not use it.
    fn answer(request: WebRequest) -> Option<WebReply> {
        var scope: Option<barista.ServiceProvider> = none
        var activator: Option<Activator> = none
        var source: Option<ServiceSource> = none
        if self.provider.has_registrations() {
            match self.provider.create_scope() {
                ok(made) => {
                    scope = some(made)
                    let container: Container = new Container(made)
                    activator = some(container)
                    source = some(container)
                }
                // A provider that cannot open a scope is one that is closed,
                // which means the application is shutting down. Serve the
                // request with no container rather than failing it: a page
                // that needs a service will say so itself, by name.
                err(problem) => {}
            }
        }
        defer close_scope(scope)

        var asked: PageRequest = new PageRequest()
        asked.method = request.method
        asked.path = request.path
        asked.body = request.body
        asked.session = request.session
        asked.bundle_ready = request.bundle_ready
        asked.who = self.factory.who
        let answer: PageResponse =
            self.host.handle_with(asked, self.now(), activator, source)
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
        self.pages_served += 1
        // A page a circuit could not produce is served WITHOUT one: this body
        // is the answer to a POST and holds what the post produced — the field
        // errors, or the receipt — and a circuit attaching to it would replace
        // all of that with the pristine form.
        var used: ShellOptions = self.shell
        if !is_safe_method(asked.method) { used = self.static_shell }
        // The token every server action on this page must present. It is per
        // SESSION, so the shell has to be copied: two requests are served by
        // two fibers on one worker and a field written into the shared
        // options by one would reach the other's document.
        if self.actions.plans.len() > 0 {
            var signed: ShellOptions = copy_shell(used)
            signed.action_token = self.anti.issue(asked.session, ACTION_FORM_ID,
                                                  self.now())
            used = signed
        }
        // The island rides on the answer to an UNSAFE method, and only there.
        // That is the whole hole this closes: a GET's circuit renders the same
        // page the GET did, so it needs nothing carried; a POST's answer holds
        // what the post produced, and a circuit attaching to it would replace
        // that with the pristine form.
        //
        // A copy of the shell, not the shared one: two requests are served by
        // two fibers on one worker and a field written into the shared options
        // by one would reach the other's document.
        if self.options.persist && !is_safe_method(asked.method) &&
           answer.state.len() > 0 {
            match self.islands.seal(answer.state, asked.session, asked.path,
                                    self.now()) {
                ok(sealed) => {
                    if sealed != "" {
                        var carried: ShellOptions = copy_shell(used)
                        carried.state = sealed
                        used = carried
                    }
                }
                // A state too large to carry is the application's mistake and
                // not this request's: the page is served without an island,
                // which is exactly how it behaved before the feature existed.
                // `scan_persist` cannot catch it — the size depends on what a
                // user typed — so it is reported where a host can see it.
                err(problem) => { self.persist_faults.push(problem) }
            }
        }
        match render_shell(used, answer.body) {
            ok(document) => { reply.body = document }
            err(problem) => {
                reply.status = 500
                reply.body = problem
                reply.content_type = "text/plain; charset=utf-8"
            }
        }
        return some(reply)
    }

    /// Mount onto a `WebApplication` the caller already built, with default
    /// endpoint options. The common shape for a test host.
    pub fn web_on(web: espresso.WebApplication) -> Result<bool> {
        var endpoint: EndpointOptions = new EndpointOptions()
        return self.mount(web, endpoint)
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
    // The provider first, because the page scan needs to know whether a
    // container exists: a page whose `init` takes services is servable with one
    // and a guaranteed 500 without one, and that is a startup refusal either
    // way rather than a surprise on the first request.
    let provider: barista.ServiceProvider = services.build_provider()

    let pages: PageMap = scan_pages_for(provider.has_registrations())
    if pages.report() != "" { return err(pages.report()) }
    let forms: FormMap = scan_forms(pages)
    if forms.report() != "" { return err(forms.report()) }

    // Every `@inject` field in the executable, checked before a socket exists.
    // Left to render time an unfillable field is a component that mounts with
    // its default, buries a fault in a buffer's list, and answers 200 — a page
    // that renders and is wrong. It is a configuration fault, not a rendering
    // one, so it is refused where the rest of them are.
    var container_source: Option<ServiceSource> = none
    if provider.has_registrations() {
        container_source = some(new Container(provider))
    }
    let injections: List<string> = scan_injections(container_source)
    if injections.len() > 0 { return err(injections.join(" | ")) }

    // Every `@memo` that cannot work. A memo that cannot compare a parameter is
    // a component that stops updating, which is the silence the hand-written
    // `ParamWatch` list used to produce and the whole reason `@memo` exists.
    let memos: List<string> = scan_memo()
    if memos.len() > 0 { return err(memos.join(" | ")) }

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

    // Every `@render_mode` in the executable, by name, before a socket
    // exists — the same contract as the four scans above. A mode that only
    // failed when somebody reached the page is a mode nobody would find.
    let modes: ModeScan = scan_render_modes(options.render_mode)
    if modes.faults.len() > 0 { return err(modes.faults.join(" | ")) }

    // Every `@action` in the executable, by name, before a socket exists. An
    // action whose parameter cannot cross is a 400 on every call, and that
    // is a configuration fault rather than a request's.
    let actions: ActionMap = scan_actions()
    if actions.report() != "" { return err(actions.report()) }
    // A `client` region with no bundle to run in is an element that stays
    // blank for ever, so the two are refused as a pair. The browser_types
    // list is what a build has to be able to construct.
    let browser_types: List<string> = modes.browser_types()
    if browser_types.len() > 0 && options.client_module == "" &&
       options.client_url == "" {
        return err("{browser_types.join(", ")} declare @render_mode(value: \"client\") or \"auto\" and this application points at no browser bundle; build one with `latte build --client` and set LatteOptions.client_module, set LatteOptions.client_url if something else serves it, or change the mode")
    }
    host.modes = modes

    var shell: ShellOptions = new ShellOptions()
    shell.title = options.title
    shell.lang = options.lang
    shell.stylesheets = options.stylesheets.clone()
    var static_shell: ShellOptions = new ShellOptions()
    static_shell.title = options.title
    static_shell.lang = options.lang
    static_shell.stylesheets = options.stylesheets.clone()
    static_shell.circuit = false
    // BOTH shells carry the loader. A client region does not need a circuit
    // and the answer to a POST is served without one, so a page that dropped
    // the loader there would come back inert for exactly the requests where
    // a form had just been submitted.
    var bundle_url: string = options.client_url
    if bundle_url == "" && options.client_module != "" {
        bundle_url = CLIENT_BUNDLE_PATH
    }
    if bundle_url != "" {
        shell.client_script = CLIENT_MODULE_SCRIPT
        shell.client_module = bundle_url
        static_shell.client_script = CLIENT_MODULE_SCRIPT
        static_shell.client_module = bundle_url
    }

    var faults: List<string> = shell.faults()
    for problem: string in static_shell.faults() { faults.push(problem) }
    if faults.len() > 0 { return err(faults.join(" | ")) }

    let islands: Islands = new Islands(signer, options.persist_options)

    // Every `@persist` field in the executable, checked before a socket exists,
    // for the reason `scan_injections` is: a field that cannot cross the seam
    // is a page that silently loses state on one navigation.
    let persist_problems: List<string> = scan_persist()
    if persist_problems.len() > 0 { return err(persist_problems.join(" | ")) }

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
    let root_container: Container = new Container(provider)
    factory.activator = some(root_container)

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
    // How a circuit restores a page from the island the client read out of the
    // document. It runs BEFORE the mount, so the first render is the restored
    // page rather than the pristine one corrected a frame later.
    //
    // Every check that matters is here and not in the core: the core has no
    // crypto and no clock, and the island's MAC binds the session and the url
    // this closure is handed. A refused island restores nothing and the page
    // renders pristine — the failure mode of this feature is the absence of
    // this feature.
    if options.persist {
        set.restore = fn(page: Component, session: string, url: string,
                         island: string) -> string {
            if island == "" { return "" }
            var when: int = options.now
            if when == 0 { when = time.wall_nanos() / 1000000000 }
            let opened: Island = islands.open(island, session, url, when)
            if !opened.ok() {
                return "a state island was refused: {describe_island(opened.outcome)}"
            }
            return restore_models(page, opened.state).join(" | ")
        }
    }

    // A circuit's components resolve their `@inject` fields from the ROOT
    // provider — see the note beside `factory.activator` for why it is not a
    // scope, and what would change that.
    set.services = some(root_container)
    set.modes = modes

    var built: LatteApp = new LatteApp(pages, forms, host, anti, set, factory,
                                       islands, shell, static_shell, options,
                                       services, provider)
    built.actions = actions
    return ok(built)
}

// ============================================================== main

/// The whole of an application's `main`, for an application that wants no more
/// than the defaults.
///
/// **The default is `check`, not `serve`.** An entry whose default was a
/// listening socket would hang an expected output-file check for ever the day its
/// arguments went missing — green, because nothing would ever come back to be
/// red. Failing towards the deterministic mode costs a person eight characters
/// and cannot silence a check.
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

/// The HTTP status one action answer gets.
///
/// A `failed` action answers 200: it RAN, and it said no. That is a business
/// answer and not a transport one, and a client that treated it as a server
/// error would retry it — which is the one thing an action must never do by
/// itself.
fn status_for_action(kind: string) -> int {
    if kind == ACTION_UNKNOWN { return 404 }
    if kind == ACTION_FORBIDDEN { return 403 }
    if kind == ACTION_STALE { return 403 }
    if kind == ACTION_INVALID { return 400 }
    if kind == ACTION_REFUSED { return 500 }
    return 200
}
