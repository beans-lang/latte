# Brew Board

The demo for everything above latte's seam: a service container, a view-model,
signals, a memo, and a real Tailwind stylesheet.

```bash
cd community-libs/latte
beansc run examples/board/main.b -- serve 8080   # http://127.0.0.1:8080/
beansc run examples/board/main.b -- check        # what the gate runs
```

`examples/cafe` is the reference for the seam itself — a served document, a
content security policy, a form that works with JavaScript switched off. This
one is the reference for what you build on top of it.

## What it shows

| | where |
|---|---|
| **constructor injection into a page** — `Board.init` takes an `Orders`; nothing constructs one and nothing passes one in | `site/board.bx` |
| **`@inject` on a component field** — `Ticket.prices` is filled at mount; no ancestor passes it down | `site/ticket.bx` |
| **`@memo`** — a row re-renders only when one of its parameters changed | `site/ticket.bx` |
| **a view-model** — state and behaviour with no render tree, so `main.b`'s check exercises it without mounting anything | `site/shop.b` |
| **a `Signal` and `live`** — the "placed this session" count patches one text node, with no render and no diff | `site/shop.b`, `site/board.bx` |
| **a `Command` with a guard** — asked to disable the button, and asked again when it runs | `site/shop.b` |

Nothing calls `own(self)` and nothing writes a `ParamWatch`. The framework owns
a component's signals and reads its `@param` fields at mount.

## The stylesheet

`css/app.build.css` is **real Tailwind**, built from `css/app.css`, which scans
the `.bx` files for the classes they use. It is committed — a consumer of this
example runs no build step and installs no toolchain, the same rule the
generated `.b` beside every `.bx` follows.

```bash
examples/board/build-css.sh      # after changing a class name in the markup
```

It is served from memory at `/app.css`, **not from a CDN**. latte ships
`style-src 'self'` with no `'unsafe-inline'`, so a CDN stylesheet would be
dropped by the policy latte itself sends — and a demo that told you to disable
the CSP to see it styled would be teaching the wrong thing. `main.b`'s check
asserts the document loads nothing from anywhere else.

Node is needed only to rebuild the CSS. It is the only part of this repository
that needs it, which is why it is a script you run rather than a leg of the
gate: a gate that needed npm would fail on a machine that has `beansc` and
nothing else.

## What it does not show

The form path — `@form`, field rules, antiforgery, and working with JavaScript
switched off — is `examples/cafe`. Carrying state across a prerender is
`@persist`, in `tests/l8_persist.b`.
