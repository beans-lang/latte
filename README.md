# latte

A server-rendered component framework for Beans.

You write components as `.bx` files — HTML markup with Beans code in it. The
server renders them, keeps the component state in memory, and streams DOM edits
to the browser over a WebSocket. The browser runs a small script that applies
those edits and sends events back. There is no client-side framework and no
JSON API to write.

```html
<beans>
import {page, layout} from latte

@page(route: r"/counter")
@layout(name: "Shell")
pub partial class Counter extends Component {
    pub count: int = 0
    pub note: string = ""
}
</beans>

<section class="counter">
  <h2>Count: $self.count</h2>

  <button on:click={fn(e: MouseEvent) { self.count += 1 }}>Add one</button>

  <input bind:value={self.note} placeholder="A note" />

  $if self.count > 10 {
    <p class="warn">That is a lot, $self.note</p>
  }

  <ul>
    $for row: Row in self.rows {
      <li key={row.id}>$row.title</li>
    }
  </ul>
</section>
```

A click runs the handler on the server, the framework re-renders that one
component, diffs it against the previous frame, and sends only what changed.

## Contents

- [Requirements](#requirements) · [Try it](#try-it) · [Commands](#commands)
- [Markup](#markup) · [Annotations](#annotations)
- [Writing an application](#writing-an-application) — [the minimum](#the-minimum),
  [services](#services-barista), [view-models](#view-models-signals-and-commands),
  [state across the seam](#state-across-the-prerender-seam),
  [your own espresso app](#mounting-on-your-own-espresso-app)
- [The examples](#the-examples) · [How the pieces fit](#how-the-pieces-fit) ·
  [The gate](#the-gate) · [Status](#status)

## Requirements

- **Beans 0.1.41**, built from `beans/` on `main`. Not an installed release —
  see `RULES.md`. `beansc --version` must print
  `beansc 0.1.41 (language 1.0, runtime ABI 20)`.
- **espresso** (`../espresso`) hosts the HTTP server and the WebSocket upgrade.
- **barista** (`../barista`) is the service container. Only `latte_app` requires
  it; an application that never names a barista type needs no `require` row of
  its own.

Your application's `beans.pot` needs **two rows**. `latte_app` brings espresso
and barista with it, so you only name them when your own source does:

```
module myapp
kind application

# paths are relative to this manifest
require path "../latte"
require path "../latte/app"

# and only if this module's own source names their types:
# require path "../barista"     # e.g. ServiceCollection
# require path "../espresso"    # e.g. WebApplication, TestHost
```

An import resolves through the *importing* package's own `require` rows, so a
file inside latte finds barista through latte's row — an application that only
imports `latte` and `latte_app` needs no row for either.

## Try it

```bash
beansc run examples/board/main.b -- serve 8080   # the Brew Board, with Tailwind
beansc run examples/cafe/main.b  -- serve 8080   # the worked example
```

## Commands

Everything runs from the latte module root, because the client script and the
example stylesheets are read relative to the working directory.

### Run an example

```bash
beansc run examples/minimal/main.b -- serve 8080   # http://127.0.0.1:8080/
beansc run examples/minimal/main.b -- check        # what the gate runs, no socket
beansc run examples/counter.b                      # renders one page to stdout
```

`run_main` gives every application the same two words: `check` exits after the
scan, `serve <port>` binds a socket. An example whose default was a listening
socket would hang the gate, which is why there is no bare default.

### The markup compiler

`.bx` compiles to `.b`, and the generated `.b` is checked in beside its source.

```bash
beansc run examples/latte_bx.b -- build site/page.bx               # writes site/page_gen.b
beansc run examples/latte_bx.b -- build site/page.bx -o site/page.b  # the usual spelling
beansc run examples/latte_bx.b -- build site/page.bx --stdout
beansc run examples/latte_bx.b -- check site/*.bx                  # parse and emit, write nothing
beansc run examples/latte_bx.b -- vocabulary                       # the .bx surface as JSON
beansc run examples/latte_bx.b -- --help

beansc build examples/latte_bx.b -o build/latte-bx     # or build it once
build/latte-bx build site/page.bx -o site/page.b
```

Every `.bx` in this repository is compiled with `-o` to the plain `.b` name
beside it; `<stem>_gen.b` is only what you get when you pass no `-o`.

| option | what it does |
|---|---|
| `-o <path>` | write the generated Beans to `<path>`; one input only |
| `--stdout` | write the generated Beans to stdout |
| `--latte <module>` | the module `Builder` comes from (default: `latte`) |
| `--package <name>` | the package the generated file declares |

The compiler is build-time only. It imports `std.fs`; nothing under the module
root imports `latte.bx`, so a program that ships a latte page never links it.

### Running the gate

```bash
./test.sh              # every suite and example, both backends
./test.sh --interp     # the interpreter only — the edit loop
./test.sh --wasm       # proves the core still imports no I/O
./test.sh --examples   # builds and runs the examples only
./test.sh diff         # one suite by name, both backends
./test.sh cafe/main    # one example by name — the path under examples/, no .b
```

A name that matches neither a suite nor an example is an error, not a quiet
pass. So is a missing golden: a gate that skips on a missing input dies
silently the first time the layout moves.

### The probes

Not part of `test.sh`. They answer questions about the tests rather than about
the code, and one of them rewrites source files.

```bash
probes/check_refusals.sh              # every recorded refusal, re-checked
probes/delete_faults.sh               # delete each refusal, watch its case fail
probes/delete_faults.sh builder.b     # just one source file
```

`delete_faults.sh` deletes one `faults.push` at a time and requires a check that
*names that site* to turn red. It **rewrites the source files, so it must never
run beside a gate.** Run it after touching a refusal.

## Markup

A `.bx` file is a whole document, not Beans with tags in it: outside `<beans>`
every `<` opens a tag.

| syntax | what it does |
|---|---|
| `$self.field` | interpolates a value into text or an attribute |
| `$(a + b)` | a parenthesised expression; one line, a newline inside is refused |
| `${self.name}` | a braced expression, where the chain would otherwise run on |
| `$$` | a literal `$` |
| `$if c { } else if c { } else { }` | conditional subtree |
| `$for x: T in xs { }` | loop; give each row a `key={...}` so the differ can match it across frames |
| `$match e { p => { } }` | pattern match in markup |
| `$slot` | where a layout places the page it wraps; also `$slot:<name>` for named slots |
| `$html(expr)` | raw HTML, unescaped — you own what goes in |
| `<Child prop={...} />` | mounts another component |

### Attribute prefixes

| prefix | what it does |
|---|---|
| `on:click={fn(e: MouseEvent) { ... }}` | event handler, run on the server |
| `bind:value={self.field}` | two-way binding on `<input>` and `<textarea>` |
| `bind:checked={self.flag}` | two-way binding on a checkbox |
| `bind:value.int` / `.float` / `.bool` | converted on the way in; an unparseable value leaves the field alone rather than writing a zero |
| `xlink:href="..."` | an ordinary XML attribute; carries a URL, so it passes the scheme allowlist |

### latte's own attributes

None of these reaches the wire.

| attribute | what it does |
|---|---|
| `key={expr}` | the identity of one row; belongs on a tag directly inside a `$for` body |
| `ref={place}` | a `Reference` to the node — or, on a component tag, the child assigned into an `Option<T>` |
| `attrs={map}` | attributes splatted onto the element; each still passes the name and URL checks |
| `preserve` | the differ leaves this subtree alone |
| `live` | every interpolated text run in this subtree is signal-bound |

`live` is the fast path: it compiles to `live_text`, the signals it reads
subscribe to it, and a write patches that one text node with **no render and no
diff**. An expression under `live` that reads no signal raises a fault when the
component renders — rather than quietly becoming a value that renders once and
never moves again. `live` on a component tag is refused by the markup compiler:
it marks an element's subtree, not a child.

## Annotations

| annotation | on | what it does |
|---|---|---|
| `@page(route:, methods:)` | a type | a routed page; `methods` defaults to `["GET"]` |
| `@layout(name:)` | a type | the layout that wraps this page. `name` is a **type** — its qualified name, or its simple name when exactly one type in the executable carries it. Two matches is a startup refusal naming both |
| `@authorize(policy:, roles:)` | a type | repeatable. AND across requirements, OR across the roles inside one |
| `@param(name:, required:)` | a field | a value a parent or a route supplies. `required` is checked at **startup**: a required parameter with no matching `{name}` in the route is refused, not 404'd per request |
| `@inject` | a field | filled from the service container at mount |
| `@memo` | a type | re-render this component only when one of its parameters changed |
| `@persist` | a field of a `ViewModel` | carried across the prerender seam |
| `@form` | a type | a posted model |
| `@field(name:)` | a field | one posted value; `name` is the wire name |
| `@required(message:)` | a `@field` | must be present |
| `@length(min:, max:, message:)` | a string `@field` | length bounds |
| `@range(min:, max:, message:)` | an int or float `@field` | value bounds |
| `@stream` | a type | the page emits streamed regions |

**Every one of these is checked at startup, by name, before a socket exists.** A
`@length` on an int, a `@field` that is not public, an `@inject` nothing can
fill, a `@memo` on a component that takes child content — each is a refusal that
names the type and the field. The alternative is a page that answers 200 with
the field at its default and nothing in the log.

### `@memo` replaces four hand-written lines

```beans
// before
watch: ParamWatch = new ParamWatch()
pub override fn on_params_set() {
    self.watch.record([self.name, "{self.price}", "{self.chosen}"])
}
pub override fn should_render() -> bool { return self.watch.differs() }

// after
@memo
```

The list was the problem, not the length: it is stringly typed and written
beside the fields it mirrors, so a parameter left out of it is a parameter whose
changes silently stop reaching the screen. `@memo` reads the `@param` fields
themselves.

It compares `string`, `int`, `bool` and `float`. It skips `Callback<T>` on
purpose — a parent builds a fresh one every render, so comparing it would make
the memo never fire. Anything else is a **startup refusal** with the field
named, because silently not comparing a field is the trap the hand-written list
set. A component that takes child content is refused too: a `fn(Builder)` is
rebuilt every render and may hold completely different markup while every
parameter is equal.

`@memo` and a hand-written `should_render` are asked separately, and both must
agree before the component renders. Neither quietly overrides the other.

## Writing an application

### The minimum

```beans
package main

import {Builder, Component, page} from latte
import {LatteOptions, run_main} from latte_app

@page(route: r"/")
pub class Home extends Component {
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "h1")
        b.text(1, "hello from latte")
        b.close()
    }
}

fn main() {
    var options: LatteOptions = new LatteOptions()
    options.title = "Minimal"
    run_main(options)
}
```

That is `examples/minimal/`, whole.

`LatteApp` does what every `main.b` used to do by hand: the scan-and-refuse
pass, the signing key, the one `Antiforgery` both halves must share, the two
`ShellOptions`, the circuit's page factory, the five espresso mount calls in the
order they have to be in, the nine-closure seam, and the WebSocket origin list —
which can only be filled in after the kernel has chosen a port, and which
refuses every handshake when it is empty.

Three defaults are safer than the pieces they replace. Panic containment is
**on** (`CircuitSet.guard` defaults to none, so one forgotten line turned a
panic in a click into a dead worker); the origin list is filled in for you; and
one `Antiforgery` is shared by construction rather than by remembering to.

#### `LatteOptions`

| field | default | what it is |
|---|---|---|
| `title` | `"latte"` | the document title |
| `lang` | `"en"` | the document language |
| `stylesheet(path, css)` | — | serve `css` at `path` **and** reference it from the head, in one call |
| `asset(path, body, type)` | — | serve a fixed body at a fixed path |
| `contain_panics` | `true` | run every handler inside the error boundary |
| `secure_cookies` | `false` | `Secure` on the session cookie. Off because a browser silently drops one on plain http, which presents as "latte does not keep a session" |
| `token_seconds` | `900` | how long an antiforgery token stays valid |
| `persist` | `false` | carry `@persist` state across the prerender seam |
| `persist_options` | 4096 B / 300 s | the island's byte cap and expiry |
| `now` | `0` | `0` reads the wall clock; anything else is used as-is, which is what a golden-file test wants |
| `idle_ms`, `retention_ms`, `poll_ms`, `socket_ms` | | circuit timings |

#### Entry points

| call | when |
|---|---|
| `run_main(options)` | no services: reads `check` / `serve <port>` off the command line |
| `build(options)` | you want the `LatteApp` and will drive it |
| `build_with(options, services)` | you have a `barista.ServiceCollection` |
| `app.serve(port)` | bind and run |
| `app.serve_with(port, extra)` | bind and run, with `extra: fn(WebApplication) -> Result<bool>` adding routes of your own |
| `app.web(endpoint)` / `app.web_on(web)` | get or mount onto an `espresso.WebApplication` |
| `app.stop()` | stop serving |

`app.pages`, `app.forms`, `app.host`, `app.set`, `app.shell` and
`app.static_shell` are all reachable. The point is that nobody has to
*assemble* them correctly, not that nobody may see them.

### Services (barista)

`barista` is the container, a standalone package espresso and latte both use.

```beans
import barista
import {LatteApp, LatteOptions, build_with} from latte_app

fn services() -> barista.ServiceCollection {
    var services: barista.ServiceCollection = new barista.ServiceCollection()
    services.singleton<Orders>().expect("orders")
    services.scoped<Visit>().expect("visit")
    services.transient<Ticket>().expect("ticket")
    return move services
}

fn start() -> Result<LatteApp, string> {
    var options: LatteOptions = new LatteOptions()
    options.title = "Brew Board"
    return build_with(options, services())
}
```

| lifetime | built |
|---|---|
| `singleton<T>()` | once per **worker**, lazily at its first resolve |
| `scoped<T>()` | once per request, and once per circuit |
| `transient<T>()` | every time it is resolved |

Singletons stay lazy on purpose: building them at `build_provider()` would move
`singleton service cannot capture scoped service` from the resolve that asked
for it to the line that built the provider. The usual argument for eagerness is
a lock-free first use across threads, and ownership already answers that — each
worker owns its own graph, so two threads never race one store.

`add_singleton<S, I>()`, `add_scoped<S, I>()` and `add_transient<S, I>()`
register an implementation `I` under a service type `S`. `add_factory<T>` and
its per-lifetime variants take a closure instead of an initializer, which is the
only route for an abstract, `singleton` or closed-generic type — none of those
has a reflective initializer.

Two things a shared container has to say out loud:

- **A "singleton" is per worker, not per process.** Each espresso worker owns an
  independent service graph.
- **`is_assignable_from` does not walk interface-extends-interface.** A service
  registered as `C implements NamedShape`, where `interface NamedShape extends
  Shape`, will not resolve as `Shape`. Register each directly implemented
  interface as its own key.

#### Two ways a service reaches a component

**Constructor injection** reaches a `@page`, because the container builds one:

```beans
@page(route: r"/")
@layout(name: "Shell")
pub partial class Board extends Component {
    pub model: BoardModel
    pub fn init(orders: Orders) { self.model = new BoardModel(orders) }
}
```

**`@inject`** reaches a child, because the renderer builds those from a
zero-argument initializer and the renderer is not the container:

```beans
@memo
pub partial class Ticket extends Component {
    @param pub drink: string = ""
    @param pub position: int = 0
    @inject pub prices: Prices = new Prices()
    pub fn init() {}
}
```

An `@inject` field still needs a default — the renderer builds the component
before the container fills it in. It must be `pub`: reflection does not bypass
visibility, and latte says so at startup rather than reporting "field not
found".

Before `@inject`, a nested component could only see a shared object if every
ancestor between it and the page passed it down as a `@param`.

A page whose `init` takes arguments in an application with **no** container is a
startup refusal, not a 500 per request.

### View-models, signals and commands

A `ViewModel` is a plain class of `Signal` fields, `Command` fields and injected
services. It has no render tree in it, so it can be exercised without mounting
anything — and it is the object that can cross the prerender seam.

```beans
import {Command, Signal, ViewModel} from latte

pub class BoardModel extends ViewModel {
    orders: Orders
    pub draft: string = ""
    pub placed: Signal<int> = new Signal<int>(0)
    pub add: Command = new Command()

    pub fn init(orders: Orders) {
        self.orders = orders    // own fields first, then the base
        super.init()
    }

    /// Commands are built here and not in a field initializer: a field
    /// initializer cannot name `self`.
    pub override fn on_attach() {
        self.add = Command.guarded(self,
            fn(model: ViewModel) {
                match model as? BoardModel { some(b) => { b.place() } none => {} }
            },
            fn(model: ViewModel) -> bool {
                match model as? BoardModel { some(b) => { return b.ready() } none => { return false } }
            })
    }
}
```

- **`Signal<T>`** — `get()`, `peek()`, `set(v)`. A write patches every `live`
  text node that read it, with no render pass and no diff. Nothing calls
  `own(self)`: the framework adopts a component's signals at mount.
- **`Command.of(owner, body)`** and **`Command.guarded(owner, body, guard)`** —
  a view asks `can_run()` to decide whether to disable the control, and `run()`
  asks the guard **again**, so a stale render cannot fire a command the model
  has since disallowed. A command whose model is gone answers `false` and is
  silently not run: a disabled button that was clicked anyway is a race the
  model already decided, not an error.

**The body takes the model as a parameter instead of capturing it**, and the
owner is `weak`. A closure that captures `self` into a field the same object
owns is a cycle — model → command → closure → model — and `probes/p6_cycle`
measures which of six shapes release without a forced sweep. This is one of
them. The `as?` inside is the cost of not leaking a model per circuit.

`Signal<T>` cannot skip an equal write: `T` is unconstrained, so there is no
equality to call. latte compares the rendered text one level down instead.

### State across the prerender seam

A POST is answered by one worker and the socket that follows is accepted by
another, each with its own service graph — so a server-side handoff keyed by
session would miss. The state rides in the document instead, which makes it
attacker-controlled, which means it is **HMAC-signed**, bound to session and
url, with an expiry and a byte cap.

```beans
pub class OrderModel extends ViewModel {
    @persist pub name: string = ""
    @persist pub cups: int = 0
    pub note: string = "not carried"
    pub fn init() { super.init() }
}
```

```beans
options.persist = true
options.persist_options.max_bytes = 4096
options.persist_options.seconds = 300
```

`@persist` is scalar only — `string`, `int`, `bool`, `float` — and anything else
is a startup refusal naming the field. A non-public one is refused too:
reflection does not bypass visibility, so the pack would read nothing and the
field would come back at its default with no message.

It is delivered as an **HTML comment**, not a `<script>` block, because latte's
own CSP is `script-src 'self'` with no `'unsafe-inline'`.

Off by default: an island is bytes in every document, and an application whose
pages persist nothing should not pay for it.

### Mounting on your own espresso app

```beans
match build(options) {
    ok(app) => {
        var endpoint: EndpointOptions = new EndpointOptions()
        app.mount(my_web_application, endpoint)?
    }
    err(problem) => { /* the page table is bad; nothing has bound a socket */ }
}
```

Add routes of your own with `serve_with`.

### Why `latte_app` is a separate module

**A package under a module may not import its own module root.** That is why
`latte.web` cannot name `CircuitSet` and why a `CircuitSeam` is nine closures
over `int` and `string`. The two halves of latte can only meet somewhere that
may import both, and before this the only such place was your `main.b` — which
is why every latte `main.b` used to be 200 lines. A *sibling* module has no such
restriction.

## The examples

| example | what it is for |
|---|---|
| `examples/minimal/` | the smallest thing that runs — a `main` of three lines |
| `examples/board/` | **everything above the seam** — a container, `@inject`, `@memo`, a view-model with a `Signal` and a guarded `Command`, `live`, and real Tailwind |
| `examples/cafe/` | **the seam itself** — a served document, a CSP, static assets, a form that works with JavaScript switched off, and a circuit. 668 lines, most of them its own self-test |
| `examples/injected/` | what each service lifetime means for a page, with the counters to prove it |
| `examples/counter.bx` | one component, rendered to stdout — no socket |
| `examples/todo.b` | a hand-written component, no markup compiler |
| `examples/shop/` + `examples/shelf/` | a third-party component library used across a module boundary: four packages in three modules |
| `examples/latte_bx.b` | the markup compiler's command line |

### `examples/board`'s stylesheet

`css/app.build.css` is real Tailwind, built from `css/app.css`, which scans the
`.bx` files for the classes they use. It is **committed** and served from
memory — not from a CDN, because latte ships `style-src 'self'` with no
`'unsafe-inline'` and a CDN stylesheet would be dropped by the policy latte
itself sends. A demo that told you to switch off the CSP to see it styled would
be teaching the wrong thing.

```bash
examples/board/build-css.sh     # after changing a class name in the markup
```

Node is needed only to rebuild that CSS, which is why it is a script and not a
leg of the gate: a gate that needed npm would fail on a machine that has
`beansc` and nothing else.

## How the pieces fit

```
  your main.b            latte_app     scan, host, circuit, seam, shell, serve
       │                               (a sibling module — it may import both halves)
       ▼
  .bx source            bx/            markup compiler: lex, parse, emit .b
       │                               (build-time only; never linked into an app)
       ▼
  Component ──▶ Builder ──▶ Frame      a render produces a frame of nodes
                              │
                         diff.b        previous frame vs new frame
                              │
                         wire.b        the edits, serialized
                              │
                         web/          espresso WebSocket endpoint
                              │
                         js/latte.js   applies edits, sends events back

  barista                              the service container: ServiceCollection,
                                       ServiceProvider, three lifetimes.
                                       Imports std.reflect and nothing else.
```

`signal.b` is the fast path: a `Signal` write updates one bound expression
directly, with no render pass and no diff.

The core — frames, builder, differ, serializer — **imports no I/O at all**. The
gate builds it for `wasm32-unknown-unknown` to hold that line, which is what
keeps a future in-browser render mode possible. A core that grows an import of
`std.fs` or `std.net` fails that leg.

**`.bx` files compile to `.b`, and the generated `.b` is checked in.** Consumers
of a latte package add a `require` row and import it — they install no markup
compiler and run no build step. The gate regenerates every `.b` and diffs it, so
a stale generated file fails the build instead of shipping.

## The gate

```bash
./test.sh
```

Both backends must print every golden file byte for byte. Native output is
diffed against the committed golden, never against a fresh interpreter run.

Beyond the suites, it runs legs that answer questions a suite cannot:

| leg | what it proves |
|---|---|
| `examples` | every entry builds, **runs**, and matches its golden on both backends |
| `examples/markup` | every checked-in `.b` is what the markup compiler makes of its `.bx` today |
| `examples/packages` | every package of every nested example module still checks |
| `component-type` | a `<Tag>` that is not a `Component` is refused by `beansc`, and one that is checks clean |
| `refusal-coverage` | every `faults.push` in the audited files has a case **and a positive control** |
| `recorded-refusals` | every program in `probes/*_bad/` is still refused, with its recorded message |
| `browser-apply` | `js/latte.js` lands the Beans applier's HTML in a real Chrome |
| `csp-browser` | under latte's policy Chrome loads the script and reaches the origin; under espresso's it runs nothing |
| `wasm-core` | the core needs no OS capability, and `std.net`/`std.fs` are still refused for it |

A refusal test needs a positive control beside it. Without one you cannot tell
"refused for the right reason" from "refused earlier, for a different one" — and
`probes/delete_faults.sh` is how you find out whether the test would notice the
refusal disappearing. `RULES.md` is the contract for changing anything here.

## Status

The framework is built and gated: pages, layouts, forms, streaming, the circuit,
the differ, the wire, a service container, `@inject`, view-models, signals,
`live`, `@memo`, and signed state across the prerender seam. The gate is 33
suites over 68 legs, both backends, byte-identical, and it drives a real Chrome.

The API will still move. `BLOCKERS.md` records the language walls found along
the way; the lane notes in `lanes/` record what each piece cost and what turned
out to be wrong about the plan for it.
