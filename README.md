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

Or in the browser, if you say so. One attribute moves a component into a
WebAssembly runtime in the page, where its handlers run with no socket and no
request — same class, same markup, same `render`:

```html
<Counter render:mode="client" start={10} />
```

[`docs/render-modes.md`](docs/render-modes.md) is the whole of it:
`static`, `server`, `client` and `auto`, what crosses a boundary, typed
server actions, and hydration. `examples/modes/` is all five on one page.

## Two targets

Latte renders a component two ways, from one markup language and one compiler.

**HTML** is what it has always been: the server renders a page and a WebSocket
circuit sends edits. Nothing about it changed.

**Canvas** draws the interface itself — on a `<canvas>`, through CanvasKit, with
the layout, the state, the editing, the focus and the accessibility tree
compiled to WebAssembly. `docs/browser.md` is how to build and run it,
`docs/migration.md` is what changed for an existing application (nothing, unless
you ask), `docs/notes.md` is the reasoning behind the decisions that are too
long to sit in a comment, `docs/table-performance.md` is what a frame of table
scrolling costs and why, and `docs/unfinished.md` is what does not work yet.

```sh
npm install && node tools/font_prepare.mjs
bash tools/generate.sh
bash tools/wasm_build.sh examples/showcase/main.b build/browser/showcase.wasm
node tools/serve.mjs 8731   # then open /examples/showcase/index.html
```

## Contents

- [Requirements](#requirements) · [Try it](#try-it) · [The command line](#the-command-line) · [Working in this repository](#working-in-this-repository)
- [Markup](#markup) · [Annotations](#annotations) · [Render modes](#render-modes)
- [Writing an application](#writing-an-application) — [the minimum](#the-minimum),
  [services](#services-barista), [view-models](#view-models-signals-and-commands),
  [state across the seam](#state-across-the-prerender-seam),
  [your own espresso app](#mounting-on-your-own-espresso-app)
- [The examples](#the-examples) · [How the pieces fit](#how-the-pieces-fit) ·
  [The check](#the-check) · [Status](#status)

## Requirements

- **Beans 0.1.44 or newer.** 0.1.41 is what building this repository needs —
  the reflection repairs it made, and `test.sh` refuses anything older. 0.1.44
  is what *using* it needs: `latte_app` is a module inside this repository, and
  reaching a nested module through a `require` row is what that release fixed.
- **[espresso](https://github.com/beans-lang/espresso)** hosts the HTTP server
  and the WebSocket upgrade.
- **[barista](https://github.com/beans-lang/barista)** is the service
  container. Only `latte_app` requires it; an application that never names a
  barista type needs no `require` row of its own.
- **A Clang with a wasm32 backend and a `wasm-ld`**, and only for an
  application with a `client` region: that is what builds the browser
  bundle. `brew install llvm lld` on a Mac; the copy inside a rustup
  toolchain works too. Nothing else in latte needs either.

Your application's `beans.pot` needs **one row**. `latte_app` lives inside this
repository, so the same row reaches both, and it brings espresso and barista
with it — you name those only when your own source does:

```
module myapp
kind application

require github.com/beans-lang/latte v0.2.0

# and only if this module's own source names their types. Pin them at the refs
# latte pins, or the build refuses two refs for one dependency:
# require github.com/beans-lang/barista v0.1.1    # e.g. ServiceCollection
# require github.com/beans-lang/espresso v0.3.0   # e.g. WebApplication, TestHost
```

Then `import github.com/beans-lang/latte` and
`import {LatteApp} from github.com/beans-lang/latte/app`. The bindings are
`latte` and `latte_app` — the names those manifests declare, not the paths.
An application with a `client` region also reaches `latte_client`, the region
runtime, through that same row — from its browser entry and nowhere else.

An import resolves through the *importing* package's own `require` rows, so a
file inside latte finds barista through latte's row — an application that only
imports `latte` and `latte_app` needs no row for either.

## Try it

```bash
beansc run examples/board/main.b -- serve 8080   # the Brew Board, with Tailwind
beansc run examples/cafe/main.b  -- serve 8080   # the worked example
```

## The command line

`latte` writes a project, regenerates its markup, and builds it, for both
targets. One binary, the way `dotnet` is one binary: it finds the project by
walking up from where you are, and every command that compiles anything
regenerates the markup first.

### Install

```sh
# macOS arm64, Linux x86_64 and arm64 (glibc or musl)
curl -fsSL https://github.com/beans-lang/latte/releases/latest/download/latte-install.sh | sh
```

```powershell
# Windows x64
irm https://github.com/beans-lang/latte/releases/latest/download/latte-install.ps1 | iex
```

It installs into `~/.latte` (`%LOCALAPPDATA%\Latte` on Windows) and puts
`bin/` on your `PATH`. Then ask what this machine can build:

```sh
latte doctor
```

You also need [Beans](https://github.com/beans-lang/beans#install) 0.1.44 or
newer. A canvas application, or an html one with a `client` region, also needs
a Clang with a wasm32 backend and a `wasm-ld` (`brew install llvm lld`,
`apt install clang lld`, or LLVM for Windows). `latte doctor` says which of
these is missing and how to get it.

The installer checks the download against the release's `SHA256SUMS` and runs
the new binary before it replaces anything. `--version 0.2.0`, `--prefix <dir>`
and `--no-modify-path` do what they say; `latte-install.sh --help` lists them.

**What you get.** Skia comes with it: a canvas build needs no checkout, no npm
and no network beyond fetching your dependencies.

```
~/.latte/
├── bin/latte          the launcher: tells the binary where its kit is
├── bin/latte.real     the command line itself
├── share/latte/       the page kit
│   ├── canvaskit/     CanvasKit 0.39.1 — Skia, compiled to WebAssembly
│   ├── js/            latte's browser scripts
│   ├── fonts/         Roboto, prepared for CanvasKit
│   └── licenses/      Skia's BSD-3-Clause and Roboto's Apache-2.0
└── libexec/           the installers `latte upgrade` runs
```

### Commands

| command | what it does |
|---|---|
| `latte init <name>` | write a project: the manifests, an entry, a layout and a page |
| `latte build` | regenerate the markup, compile, and stage the browser half beside it |
| `latte check` | regenerate and type-check; nothing is compiled |
| `latte generate` | compile the markup and stop |
| `latte clean` | remove `build/` |
| `latte doctor` | say what this machine can build, and what is missing |
| `latte upgrade` | replace this installation with the latest release |
| `latte upgrade --project` | move this project's pins to this latte's |
| `latte vocabulary` | print the `.bx` surface as JSON, for an editor |
| `latte version` | print the version |

| option | for | what it does |
|---|---|---|
| `--target html\|canvas` | `init`, `vocabulary` | which target; html is the default |
| `--client` | `init`, `build` | scaffold `browser/`, or build it into a WebAssembly bundle |
| `--latte <path>` | `init` | build against a latte checkout instead of a release |
| `--here` | `init` | write into this directory |
| `-c Release`, `--release`, `--debug` | `build` | which configuration; Debug is the default |
| `--drift` | `check` | fail on a generated file that is not what its markup says |
| `--generated` | `clean` | remove `generated/` as well |
| `--force` | `upgrade` | reinstall even when this version is already installed |

### A first application

```sh
latte init shop && cd shop            # an html application
latte build
cd build/debug && ./shop serve 8080   # http://127.0.0.1:8080/
```

```sh
latte init pad --target canvas && cd pad
latte build
python3 -m http.server -d build/debug 8000   # any static file server will do
```

**The build folder is the application.** An html build is a server binary with
latte's browser scripts in `js/` beside it; a canvas build is a page, a
WebAssembly module, CanvasKit and the fonts. There is no `latte run`: run the
binary, or serve the folder. Every path in a canvas page is relative, so it
works under any prefix.

```
build/debug/                       build/debug/
├── shop           the server      ├── index.html     written by the build
└── js/            latte.js and    ├── pad.wasm
                   the region      ├── latte/         latte's page scripts
                   runtime         ├── canvaskit/     Skia
                                   └── fonts/
```

A project looks like this. `generated/` is not written by `init`; the first
build writes it.

```
shop/
├── beans.pot        the module, and what it depends on
├── latte.pot        the application: name, target, fonts, profiles
├── main.b           the entry
├── site/            one .bx per screen — markup on top, a partial class under it
└── generated/       the .b half of every .bx, mirroring its folder
```

**An application does not need latte to build.** `generated/` is checked in, so
a clone compiles with plain `beansc`. `latte` is what you need to *write* one:
to scaffold it, and to regenerate the markup as part of every build.

**Every build regenerates the markup first.** Markup and the code built from it
are two files, and any process where a person can compile one without the other
eventually ships the pair out of step. `latte build` cannot produce one, and
`latte check --drift` is the gate form, for a merge or a direct `beansc` run.

**Two configurations, the way `dotnet` has two.**

| | `beansc` | where it lands |
|---|---|---|
| `latte build` | `--debug` — `-O0`, frame pointers, DWARF line tables | `build/debug/` |
| `latte build -c Release` | `--release` — `-O3`, `NDEBUG` | `build/release/` |

`latte.pot` is the application's manifest, beside `beans.pot`:

```
name    pad
target  canvas
markup  site
title   "My Application"
font    fonts/inter.ttf      # CanvasKit ships none; with no row, latte's are staged

profile release
    out  dist
    lto  true
```

### Where the browser half comes from

A build stages latte's browser scripts, and for a canvas build CanvasKit and
the fonts, from one place, chosen by how the project reaches latte:

1. `$LATTE_ROOT`, if set: a latte checkout you named on purpose.
2. A `require path` row to a latte checkout — what `latte init --latte <path>`
   writes, for working on latte itself.
3. `require github.com/beans-lang/latte vX`: the kit in the installation,
   **only if** it is latte X. The scripts call the module's exports by name, so
   a kit from another version is refused before compiling, with the fix.

The project's imports follow the same row: `latte.compose` and `latte_app`
through a path row, `github.com/beans-lang/latte/compose` and
`github.com/beans-lang/latte/app` through a git pin. `latte init` writes the
matching form and `latte build` compiles the markup with it.

### Upgrading

```sh
latte upgrade              # this installation, to the latest release
latte upgrade --force      # reinstall the same version
latte upgrade --project    # inside a project: move it to this latte
```

`upgrade --project` moves the project's `latte`, `espresso` and `barista` pins
to the ones this latte was released with, then runs `beansc pot update` so
`beans.lock` moves with them. If beansc cannot resolve the new pins,
`beans.pot` is put back as it was. `browser/beans.pot` moves too, when there
is one.

### Building it from source

```sh
beansc build examples/latte_cli.b -o build/latte   # the binary, no kit
npm install && node tools/font_prepare.mjs         # CanvasKit and the fonts
bash tools/package_cli.sh dist                     # a release archive for this machine
bash tools/check_cli.sh                            # the gate below
```

A binary built this way is not an installation: it builds projects that reach
latte by path, and refuses a git-pinned one until it is installed.
`tools/package_cli.sh` builds the whole package — launcher, binary, kit,
installers — and `tools/make_kit.sh` builds the kit on its own.

`tools/check_cli.sh` is the gate, and a `test.sh` leg. It scaffolds and builds
both targets against this checkout, runs the html one and asks it for its page,
then installs the packaged archive with the installer and does it again with
projects pinned to latte by git — reached through `url.insteadOf` at a
snapshot of this tree, with a private package cache. It also covers the
refusals: a stale pin, a damaged kit, `upgrade --project` restoring what beansc
refused, and the launcher's own `upgrade`.

### Releases

`.github/workflows/cli.yml` runs on every push and pull request:

- **kit** builds the page kit once, so every archive carries the same Skia.
- **build** packages `latte` natively on macOS arm64, Linux x86_64 and arm64
  (glibc), and Windows x64. Each archive is run through its launcher, and
  `doctor`, `init` and `generate` are smoke-tested. The macOS and Linux jobs
  then run `tools/check_cli.sh` against the exact archive they ship. The
  Windows job installs it with `latte-install.ps1`.
- **musl** builds static x86_64 and aarch64 Linux archives inside Alpine, and
  installs and runs them there with busybox `sh`.
- **publish** runs on a `v*` tag, or on a manual run with `publish` ticked. It
  refuses a release missing any of the six archives, and uploads them with the
  two installers and `SHA256SUMS`.

To cut a release, set `LATTE_VERSION` in `cli/version.b`, give `CHANGELOG.md` a
`## [X.Y.Z]` heading, and push the tag `vX.Y.Z`. `tools/check_version.sh`
refuses a tag, a heading or an espresso/barista pin that disagrees with the
rest.

## Working in this repository

Everything runs from the latte module root, because the client script and the
example stylesheets are read relative to the working directory.

### Run an example

```bash
beansc run examples/minimal/main.b -- serve 8080   # http://127.0.0.1:8080/
beansc run examples/minimal/main.b -- check        # what the check runs, no socket
beansc run examples/counter.b                      # renders one page to stdout
```

`run_main` gives every application the same two words: `check` exits after the
scan, `serve <port>` binds a socket. An example whose default was a listening
socket would hang the check, which is why there is no bare default.

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

### Running the check

```bash
./test.sh              # every suite and example, both backends
./test.sh --interp     # the interpreter only — the edit loop
./test.sh --wasm       # proves the core still imports no I/O
./test.sh --examples   # builds and runs the examples only
./test.sh diff         # one suite by name, both backends
./test.sh cafe/main    # one example by name — the path under examples/, no .b
```

A name that matches neither a suite nor an example is an error, not a quiet
pass. So is a missing expected output: a check that skips on a missing input dies
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
run beside a check.** Run it after touching a refusal.

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
| `<RenderBlock mode="client" n:int={...}>` | an execution boundary around a block of markup; its body becomes a component of its own |

### Attribute prefixes

| prefix | what it does |
|---|---|
| `on:click={fn(e: MouseEvent) { ... }}` | event handler, run wherever its component runs |
| `render:mode="static\|server\|client\|auto"` | where THIS component instance runs. A literal, on a component tag. See [Render modes](#render-modes) |
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
| `@render_mode(value:, prerender:)` | a type | where this component runs: `static`, `server`, `client` or `auto`. `prerender` defaults to true |
| `@actions(name:)` | a type | a group of server actions a browser region may call |
| `@action(policy:, roles:)` | a method | one of them. Authorization is checked on the server, on every call |

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
| `now` | `0` | `0` reads the wall clock; anything else is used as-is, which is what an expected-output test wants |
| `render_mode` | `server` | the mode every component inherits unless it says otherwise |
| `client_module` | `""` | the WebAssembly bundle latte serves for `client` regions, as a path on disk |
| `client_url` | `""` | where the page points at that bundle, when something else serves it |
| `client_loader` | `""` | the directory the region runtime's loader is read from (default `js/`) |
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
import github.com/beans-lang/barista
import {LatteApp, LatteOptions, build_with} from github.com/beans-lang/latte/app

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
| `examples/modes/` | **where a component runs** — a static paragraph, a plain form, a server counter, a client counter, a client markup block, a client editor calling a typed server action, and an auto counter, all on one page |
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
leg of the check: a check that needed npm would fail on a machine that has
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
check builds it for `wasm32-unknown-unknown` to hold that line, which is what
keeps a future in-browser render mode possible. A core that grows an import of
`std.fs` or `std.net` fails that leg.

**`.bx` files compile to `.b`, and the generated `.b` is checked in.** Consumers
of a latte package add a `require` row and import it — they install no markup
compiler and run no build step. The check regenerates every `.b` and diffs it, so
a stale generated file fails the build instead of shipping.

## The check

```bash
./test.sh
```

Both backends must print every expected output byte for byte. Native output is
diffed against the committed expected output, never against a fresh interpreter run.

Beyond the suites, it runs legs that answer questions a suite cannot:

| leg | what it proves |
|---|---|
| `examples` | every entry builds, **runs**, and matches its expected output on both backends |
| `examples/markup` | every checked-in `.b` is what the markup compiler makes of its `.bx` today |
| `examples/packages` | every package of every nested example module still checks |
| `component-type` | a `<Tag>` that is not a `Component` is refused by `beansc`, and one that is checks clean |
| `refusal-coverage` | every `faults.push` in the audited files has a case **and a positive control** |
| `recorded-refusals` | every program in `probes/*_bad/` is still refused, with its recorded message |
| `browser-apply` | `js/latte.js` lands the Beans applier's HTML in a real Chrome |
| `csp-browser` | under latte's policy Chrome loads the script and reaches the origin; under espresso's it runs nothing |
| `wasm-core` | the core needs no OS capability, and `std.net`/`std.fs` are still refused for it |
| `cli` | `latte init` writes a project that `latte build` builds, for both targets, and a canvas build stages every script its page imports |
| `client-wire` | a browser bundle mounts a region, dispatches an event and refuses what it should — under node, with no DOM |
| `client-browser` | one client region in Chromium, Firefox and WebKit, and a click on it that makes **no network request at all** |
| `client-abi` | every WebAssembly import a bundle has is declared in Beans and supplied by the page |
| `modes-browser` | `examples/modes` in a real browser: two runtimes on one page, a typed action with its refusals, the inspector, and hydration keeping text typed before the attach |

A refusal test needs a positive control beside it. Without one you cannot tell
"refused for the right reason" from "refused earlier, for a different one" — and
`probes/delete_faults.sh` is how you find out whether the test would notice the
refusal disappearing.

## Render modes

A component can run on the server, in the browser, or not at all — and it is
the same component either way. There is no client copy of anything, and no
handwritten JavaScript.

```html
<Counter />                        <!-- wherever the page runs: the server -->
<Counter render:mode="client" />   <!-- in the browser, in WebAssembly -->
<Counter render:mode="auto" />     <!-- client once the bundle is cached -->

<RenderBlock mode="client" title:string={self.heading}>
  <p>$props.title</p>
</RenderBlock>
```

A mode belongs to a **region**, not to a component: the component that
declared it and everything under it that did not. Only a *change* of mode
makes an execution boundary, so an application that declares no mode renders
exactly the bytes it rendered before. Props cross a boundary — a `string`, an
`int`, a `bool` or a `float` — and nothing else does; a `self`, a service or
a closure is refused by name.

A `client` region is server-rendered first and the browser **adopts** it, so
the page paints before the bundle arrives and text typed before the script
attaches survives it. A browser region reaches the server through a typed
server action, whose implementation is never in the bundle:

```beans
var args: ActionArgs = new ActionArgs()
args.text("body", self.draft)
self.call = call_action<string>("notes.save", args, fn(answer) { ... })
```

[`docs/render-modes.md`](docs/render-modes.md) is the reference: the
precedence rules, what crosses, prerendering and hydration, actions and their
refusals, `auto`, and the honest list of what does not work yet.

```bash
latte init myapp --client       # a project with a browser half
latte build --client            # the server, and the bundle beside it
```

`--client` writes `browser/`, a module of its own — because a module root
holds one entry and `main.b` is the server's — and `latte build --client`
compiles it into `build/debug/myapp.wasm`. Point `LatteOptions.client_module`
at that.

## Status

The framework is built and checked: pages, layouts, forms, streaming, the circuit,
the differ, the wire, a service container, `@inject`, view-models, signals,
`live`, `@memo`, signed state across the prerender seam, render modes,
execution boundaries, a WebAssembly client runtime, typed server actions and
hydration by adoption. The check is 52 suites over 122 legs, both backends,
byte-identical, and it drives Chromium, Firefox and WebKit.

The API will still move.
