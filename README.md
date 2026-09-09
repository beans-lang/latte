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

Build an espresso application, then map the circuit endpoint onto it:

```beans
import espresso
import {CircuitOptions, CircuitSet} from latte
import {CircuitSeam, EndpointOptions, map_circuit} from latte.web

let app: espresso.WebApplication =
    new espresso.WebApplicationBuilder().build().expect("the app builds")

var set: CircuitSet = new CircuitSet(new CircuitOptions(), /* your pages */)
let seam: CircuitSeam = new CircuitSeam(
    set.open_fn(), set.adopt_fn(), set.accept_fn(), set.outbox_fn(),
    set.tick_fn(), set.ending_fn(), set.disconnect_fn(), set.resume_fn(),
    set.wake_fn())

map_circuit(app, "/circuit", seam, new EndpointOptions())?
```

`CircuitSet` owns the live circuits and `CircuitSeam` is the set of closures the
endpoint calls into — the endpoint knows nothing about pages, which is what lets
the core stay free of I/O. Then serve your page bodies from your own routes and
include `js/latte.js`.

**`examples/cafe/main.b` is the worked example** and the source of truth for this
wiring: a served document, a content-security policy, static assets, and the
circuit on one server.

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
