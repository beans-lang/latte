# Changelog

This file records user-facing changes in each latte release.

## [0.2.0] - unreleased

### Added — render modes: where a component runs

A component can now run on the server, in the browser, or not at all, and it
is the same component either way. `docs/render-modes.md` is the reference.

* **Four modes.** `static`, `server`, `client` and `auto`, declared on the
  application (`LatteOptions.render_mode`), on a type (`@render_mode`), on
  one instance (`render:mode="client"`) or around a block of markup
  (`<RenderBlock mode="client">`). The innermost wins.
* **A mode is a region, not a flag.** Only a *change* of mode makes an
  execution boundary, so an application that declares none renders exactly
  the bytes it rendered before.
* **A real browser runtime.** A `client` region's components are compiled to
  WebAssembly and run in the page: their handlers, their state, their render
  and their diff, with the edits going into the same `latte.js` applier a
  circuit drives. A click on a client counter makes no network request, and
  `client-browser` counts them in three engines to prove it.
* **Typed server actions.** `@actions` / `@action` on the server, and
  `call_action<T>(name, args, then)` in a browser region. No fetch, no JSON,
  no endpoint. Authorization, the antiforgery token and every argument's
  type are checked on the server, on every call. Nothing is ever retried.
* **`auto`**, decided once per page render from a cookie the runtime sets
  after a bundle boots: server while the browser has none, client after.
* **`latte build --client`**, which builds `browser/main.b` into a bundle
  beside the server binary.
* **A development inspector**: `latteClient.report()` lists every boundary's
  mode, owner, readiness and error, read from the DOM so a region that never
  mounted is in the list too.

### Changed — hydration adopts the server's DOM instead of replacing it

The first batch used to clear the root element and rebuild it. It now walks
the tree it built against the DOM the server wrote and keeps what matches, so
an attach preserves text typed before the script ran, the caret in it, focus,
selection, scroll position and node identity. The resulting document is
unchanged: `tests/js_apply.js` § 1b compares the adopted tree against a
freshly built one for every fixture. A mismatch — a `<tbody>` the parser
inserted, a stale cached build — rebuilds the affected subtree and is
reported once per component, naming what the frames wanted and what the
document had.

### Fixed — a circuit filled `@inject` after a navigation and not at attach

The service source was handed to the renderer on the navigation path and not
on the attach path, so a component's injected field held its default on the
first mount and the real service after any navigation. The page still
rendered, so the only evidence was a fault list no suite read for a circuit.
`tests/circuit.b` § 16 holds both paths now.

### Fixed — a POST of JSON to a latte path was answered 415 by the page route

`map_pages` refuses a body that is not `application/x-www-form-urlencoded`,
and it checked that before asking whether any page owned the path. Every path
under `/_latte/` is latte's, and the page route now skips them.

### Added — a `latte` you install, with Skia in the box

`.github/workflows/cli.yml` builds `latte` on macOS arm64, Linux x86_64 and
arm64 (glibc, and static musl in an Alpine container), and Windows x64, and
publishes the archives, `SHA256SUMS` and two installers as a release.

```sh
curl -fsSL https://github.com/beans-lang/latte/releases/latest/download/latte-install.sh | sh
irm https://github.com/beans-lang/latte/releases/latest/download/latte-install.ps1 | iex
```

* **The archive carries the page kit.** `share/latte/` holds CanvasKit 0.39.1
  (Skia compiled to WebAssembly), latte's browser scripts and the fonts, so an
  installed `latte` builds a canvas application with no checkout, no npm and
  no network beyond the dependency fetch. `bin/latte` is a launcher that tells
  the binary where its kit is.
* **The kit follows the project's pin.** A project that requires latte by git
  gets the kit only when its pin is the installed version; any other pin is
  refused before compiling, with the fix. A `require path` checkout, or
  `$LATTE_ROOT`, supplies its own.
* **`latte upgrade`** re-runs the installer against the latest release;
  `--force` reinstalls. Nothing is replaced until the download is checksummed
  and its binary runs.
* **`latte upgrade --project`** moves a project's latte, espresso and barista
  pins to this latte's, and its `beans.lock` with them through
  `beansc pot update`. If beansc cannot resolve the new pins, `beans.pot` is
  put back.
* **`latte doctor`** says what this machine can build: the installation and
  its kit, `beansc` against the 0.1.44 floor, the wasm Clang and `wasm-ld`, and
  what the project here needs.
* **Each binary is built on a machine of its kind and run there**, and
  `tools/check_cli.sh` installs the packaged archive with the installer, then
  builds and runs projects pinned to latte by git from it.
* **`tools/check_version.sh`** holds `cli/version.b`, the changelog heading,
  the release tag and the espresso/barista pins to one another.

### Fixed — `latte init` wrote projects that did not compile, or did not run

* **A project pinned to latte by git never compiled.** The scaffold and the
  markup compiler spelled latte's packages `latte.compose`, `latte_app`, which
  only a `require path` row binds. They are now spelled the way the project's
  `beans.pot` reaches latte: `github.com/beans-lang/latte/compose` when it is
  pinned. The old gate only ever built the `--latte <path>` form.
* **An html project built but did not serve.** Its server reads
  `js/latte.js` from the working directory, which only a latte checkout has.
  An html build now stages latte's browser scripts into `build/<profile>/js/`,
  so the build folder runs as it stands: `cd build/debug && ./myapp serve 8080`.
* **A canvas build whose `wasm-ld` was not on `PATH` ran beansc with an empty
  environment.** Setting one variable on a `process.Command` replaces the
  whole environment, so `PATH` went in and `HOME` and every `BEANS_*` went
  out. The linker is now passed as `beansc --linker <path>`.

## [0.1.1] - 2026-09-16

### Changed — BREAKING: espresso and barista are required from git, not by path

**`require path "../../community-libs/espresso"` is gone.** It named a
directory in this workspace, so latte built here and nowhere else: a consumer
who fetched this repository got errors about unknown packages `espresso` and
`barista`, because these manifests pointed at sibling directories that were not
in their tree.

```beans-pot
require github.com/beans-lang/latte v0.1.1
```

That one row reaches both halves. `latte_app` — the composition root under
`app/` — is a module inside this repository, so `import
github.com/beans-lang/latte/app` resolves through the same row and still binds
as `latte_app`: a package is named by the manifest that declares it, never by
the path that reached it.

```beans
import github.com/beans-lang/latte
import {LatteApp, LatteOptions, build_with} from github.com/beans-lang/latte/app
```

Every `latte.X` and `latte_app.X` in existing source stands; only the import
lines change.

### Requirements

**Beans 0.1.44 or newer to use latte.** Reaching a nested module through a
`require` row is what that release fixed — before it, `app/` was loaded as a
package of the repository above it and failed on its own `import latte`.
0.1.41 is still the floor for building this repository, and `test.sh` holds it.

## [0.1.0] - 2026-09-08

The first release: frames, builder, serializer and differ; the circuit
endpoint over espresso; `latte.bx` markup; forms, uploads, signals and
view-models; the `latte_app` composition root.
