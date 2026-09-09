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

## Markup

| syntax | what it does |
|---|---|
| `$self.field` | interpolates a value into text or an attribute |
| `$if cond { } else { }` | conditional subtree |
| `$for x: T in xs { }` | loop; give each item a `key={...}` so the differ can match rows across frames |
| `$slot` | where a layout places the page it wraps |
| `on:click={fn(e: MouseEvent) { ... }}` | event handler, run on the server |
| `bind:value={self.field}` | two-way binding to an input |
| `<Child prop={...} />` | mounts another component |

## Status

Early. The example app runs, renders, and handles clicks end to end against a
real browser — `w8b_smoke.sh` drives it from Chromium in the gate. The API will
still move. `BLOCKERS.md` records language walls found along the way, and
`RULES.md` is the contract for changing anything here.

## Requirements

- **Beans 0.1.40 or newer.** latte uses `std.websocket`'s permessage-deflate,
  `std.compress`'s `Deflater`, and `std.http`'s `encode_response_head_append`.
  None of them exist in 0.1.39.
- **espresso** (`../espresso`) hosts the HTTP server and the WebSocket upgrade.

## Try it

```bash
beansc run examples/cafe/main.b -- serve 8080   # then open http://127.0.0.1:8080/
beansc run examples/counter.b                   # renders one page to stdout, no socket
```

## Using it in an app

An application is `latte_app`, and it is four lines:

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

That is `examples/minimal/`, whole. `run_main` reads `check` or `serve <port>`
from the command line; `build(options)` gives you the `LatteApp` if you want to
drive it yourself.

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

Add routes of your own with `serve_with`, or take the `espresso.WebApplication`
and mount latte on it yourself:

```beans
match build(options) {
    ok(app) => {
        var endpoint: EndpointOptions = new EndpointOptions()
        app.mount(my_web_application, endpoint)?
    }
    err(problem) => { /* the page table is bad; nothing has bound a socket */ }
}
```

Nothing is hidden: `app.pages`, `app.forms`, `app.host`, `app.set`, `app.shell`
and `app.static_shell` are all reachable. The point is that nobody has to
*assemble* them correctly, not that nobody may see them.

**`latte_app` is a separate module, not a package under `latte/`,** and it has
to be: a package under a module may not import its own module root. That is why
`latte.web` cannot name `CircuitSet` and why a `CircuitSeam` is nine closures
over `int` and `string`. The two halves of latte can only meet somewhere that
may import both, and before this the only such place was your `main.b`.

**`examples/board/` is the demo for everything above the seam** — a service
container, `@inject` on a child component, `@memo` instead of a hand-written
`ParamWatch`, a view-model with a `Signal` and a guarded `Command`, and a real
Tailwind stylesheet served from this origin rather than a CDN, because latte's
own `style-src 'self'` would drop one.

**`examples/cafe/main.b` is the worked example** — a served document, a content
security policy, static assets, a form that works with JavaScript switched off,
and a circuit, with 500 lines of its own self-test. **`examples/minimal/` is the
one that shows what you have to write.**

**`.bx` files compile to `.b`, and the generated `.b` is checked in.** Consumers
of a latte package add a `require` row and import it — they install no markup
compiler and run no build step. The gate regenerates every `.b` and diffs it, so
a stale generated file fails the build instead of shipping.

## How the pieces fit

```
  .bx source            bx/          markup compiler: lex, parse, emit .b
       │                             (build-time only; never linked into an app)
       ▼
  Component ──▶ Builder ──▶ Frame    a render produces a frame of nodes
                              │
                         diff.b      previous frame vs new frame
                              │
                         wire.b      the edits, serialized
                              │
                         web/        espresso WebSocket endpoint
                              │
                         js/latte.js applies edits, sends events back
```

`signal.b` is the fast path: a `Signal` write updates one bound expression
directly, with no render pass and no diff.

The core — frames, builder, differ, serializer — **imports no I/O at all**. The
gate builds it for `wasm32-unknown-unknown` to hold that line, which is what
keeps a future in-browser render mode possible. A core that grows an import of
`std.fs` or `std.net` fails that leg.

## The gate

```bash
./test.sh              # both backends, every suite
./test.sh --interp     # the interpreter only — the edit loop
./test.sh diff         # one suite, both backends
./test.sh --wasm       # proves the core still imports no I/O
./test.sh --examples   # builds and runs the examples
```

Both backends must print every golden file byte for byte. Native output is
diffed against the committed golden, never against a fresh interpreter run.
