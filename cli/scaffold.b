// scaffold.b — what `latte init` writes. Templates are raw literals with
// `__NAME__`-style holes, because markup and Beans are mostly braces.

package cli

import std.fs
import std.io
import std.path
import latte.bx

/// One file a scaffold writes.
class Piece {
    pub where: string = ""
    pub body: string = ""

    pub fn init(where: string, body: string) {
        self.where = where
        self.body = body
    }
}

// ---------------------------------------------------------------- manifests

fn beans_pot(name: string, target: bx.Target, latte_path: string) -> string {
    var rows: List<string> = [
        "module {name}",
        "kind application",
        "",
    ]
    if latte_path != "" {
        // A path row, for working on latte itself: the project sees uncommitted
        // changes. The path is asked for, never guessed.
        rows.push("require path \"{latte_path}\"")
        match target {
            html => { rows.push("require path \"{latte_path}/app\"") }
            canvas => {}
        }
    } else {
        rows.push("require {LATTE_REMOTE} v{LATTE_VERSION}")
    }
    match target {
        html => {
            // The composition root names both halves of latte and wires them
            // onto espresso; a canvas application needs neither.
            rows.push("require {ESPRESSO_REMOTE} {ESPRESSO_PIN}")
        }
        canvas => {}
    }
    rows.push("")
    return rows.join("\n")
}

fn latte_pot(name: string, target: bx.Target) -> string {
    var rows: List<string> = [
        "name    {name}",
        "target  {target.name()}",
        "version 0.1.0",
        "",
        "markup  site",
        "",
    ]
    match target {
        canvas => {
            rows.push("# The page's <title>. CanvasKit has no fonts of its own, so a build")
            rows.push("# stages latte's; a 'font <path>' row names your own instead.")
            rows.push("title   {name}")
            rows.push("")
        }
        html => {}
    }
    rows.push("profile debug")
    rows.push("    out build/debug")
    rows.push("profile release")
    rows.push("    out build/release")
    rows.push("")
    return rows.join("\n")
}

// ------------------------------------------------------------------- canvas

/// The canvas entry.
///
/// Every line of it is one call into `browser.PageApp`, and the list is the
/// module's ABI: the page calls these names and no others. It is written into
/// the project rather than exported by latte because `mount` is the one export
/// that has to name the application's own root component, and a half-exported
/// ABI would be harder to read than a whole one.
fn canvas_main() -> string {
    return r##"// The WebAssembly module's surface. Every export is one line of
// `browser.PageApp`; the screens are the `.bx` files under `site/`.
//
// The page calls these names and no others, so this list is the module's ABI.
// `latte build` compiles this file with --target wasm32-unknown-unknown,
// --runtime freestanding and --emit shared, and writes a page beside it.
package main

import __LATTE_BROWSER__
import __NAME__.generated.site

pub extern "C" fn boot() -> i32 as "latte_boot" {
    return browser.PageApp.instance.boot() as i32
}

/// The one export that names this application: what opens.
pub extern "C" fn mount(width: f64, height: f64, scale: f64) -> i32 as "latte_mount" {
    return browser.PageApp.instance.mount(new site.Shell(), width, height, scale) as i32
}

pub extern "C" fn frame(seconds: f64) -> i32 as "latte_frame" {
    return browser.PageApp.instance.frame(seconds) as i32
}

pub extern "C" fn pointer(kind: i32, x: f64, y: f64, button: i32, clicks: i32,
                          modifiers: i32) -> i32 as "latte_pointer" {
    return browser.PageApp.instance.pointer(kind as int, x, y, button as int,
                                            clicks as int, modifiers as int) as i32
}

pub extern "C" fn key(kind: i32, code: i32, text: RawPtr<i8>, len: i32,
                      modifiers: i32) -> i32 as "latte_key" {
    return browser.PageApp.instance.key(kind as int, code as int,
                                        browser.Text.copy_in(text, len as int),
                                        modifiers as int) as i32
}

pub extern "C" fn text_input(kind: i32, text: RawPtr<i8>, len: i32, anchor: i32,
                             caret: i32) -> i32 as "latte_text_input" {
    return browser.PageApp.instance.text_input(kind as int,
                                               browser.Text.copy_in(text, len as int),
                                               anchor as int, caret as int) as i32
}

pub extern "C" fn scroll(x: f64, y: f64, dx: f64, dy: f64) -> i32 as "latte_scroll" {
    return browser.PageApp.instance.scroll(x, y, dx, dy) as i32
}

pub extern "C" fn resize(width: f64, height: f64, scale: f64) -> i32 as "latte_resize" {
    return browser.PageApp.instance.resize(width, height, scale) as i32
}

pub extern "C" fn semantics_action(handle: u64, action: i32) -> i32 as "latte_semantics_action" {
    return browser.PageApp.instance.semantics_action(handle, action as int) as i32
}

pub extern "C" fn unmount() -> i32 as "latte_unmount" {
    return browser.PageApp.instance.unmount() as i32
}

pub extern "C" fn software() -> i32 as "latte_software" {
    return if browser.PageApp.instance.software() { 1 } else { 0 }
}

/// Frames delivered, painted, and asked for. Three numbers, because "it drew"
/// and "it asked to draw" are the two halves of the idle question.
pub extern "C" fn frames() -> i32 as "latte_frames" {
    return browser.PageApp.instance.frames as i32
}
pub extern "C" fn painted() -> i32 as "latte_painted" {
    return browser.PageApp.instance.painted as i32
}
pub extern "C" fn requests() -> i32 as "latte_requests" {
    return browser.PageApp.instance.requests as i32
}

/// The last failure, for a page that got -1 and has to say why.
pub extern "C" fn last_error(out: RawPtr<i8>, cap: i32) -> i32 as "latte_last_error" {
    return browser.write_text(browser.PageApp.instance.error(), out, cap as int) as i32
}

fn main() {}
"##
}

fn canvas_shell() -> string {
    return r##"<VStack padding={0} spacing={0} align="stretch">
  <HStack padding={12} spacing={8} align="center" background="#f2f2f5" height={48}>
    <Label text="__NAME__" font_size={17} font_weight={5} />
    <Label text="" grow={1} />
    <Label key={"status"} text={self.status} text_color="#555b6b" />
  </HStack>
  <Separator height={1} />
  <Counter grow={1} />
</VStack>
<beans>
// The root component: what `latte_mount` opens.
//
// `grow={1}` on the page is what makes the interface follow the window. Latte
// owns the canvas's backing store and the page's stylesheet owns its size, so
// a canvas that fills its box fills the window, and a page that grows fills
// the canvas.
package site

import __LATTE_COMPOSE__
import {view} from __LATTE_ANNOTATIONS__

@view
pub partial class Shell extends compose.Component {
    pub status: string = "ready"
    pub fn init() { super.init() }
}
</beans>
"##
}

fn canvas_page() -> string {
    return r##"<VStack padding={20} spacing={12} align="start">
  <Label text="Counter" font_size={23} />
  <Label key={"count"} text={self.reading()} text_color="#555b6b" />
  <HStack spacing={8} align="center">
    <Button key={"add"} text="Add one" prominent={true}
            on:click={fn(e: UiEvent) { self.add(1) }} />
    <Button key={"reset"} text="Reset"
            on:click={fn(e: UiEvent) { self.clear() }} />
  </HStack>
</VStack>
<beans>
// One screen, with state and two commands under the markup it draws.
//
// There is no view-model folder and that is a decision: a `.bx` file is already
// both halves — markup on top, a `partial class` holding the state underneath,
// in one file the compiler keeps in step.
package site

import __LATTE_COMPOSE__
import {view} from __LATTE_ANNOTATIONS__

@view
pub partial class Counter extends compose.Component {
    pub count: int = 0
    pub fn init() { super.init() }

    pub fn reading() -> string {
        if self.count == 1 { return "1 press" }
        return "{self.count} presses"
    }

    /// `request_render()` is what marks this component dirty. Without it the
    /// state would move and nothing would redraw — the handler ran, and the
    /// renderer was never told.
    fn add(by: int) {
        self.count = self.count + by
        self.request_render()
    }

    fn clear() {
        self.count = 0
        self.request_render()
    }
}
</beans>
"##
}

// --------------------------------------------------------------------- html

fn html_main() -> string {
    return r##"// The application. Everything it needs is in `options()`; `latte_app` does
// the assembling that every main.b used to hand-write.
//
//     latte build && cd build/debug && ./__NAME__ serve 8080
package main

import github.com/beans-lang/espresso
import std.io
import std.os
import {LatteApp, LatteOptions, build} from __LATTE_APP__
// Nothing calls these two. The import is what puts them in the executable, so
// the page scan can find their `@page` annotations — latte has no registry and
// `reflect.types()` is the registry.
import {Shell, Home} from __NAME__.generated.site

/// The stylesheet, served from memory at `/app.css`.
///
/// A file rather than an inline `<style>`, because latte ships
/// `style-src 'self'` with no `'unsafe-inline'` and an inline block would be
/// dropped by the policy latte itself sends. A `List` of raw literals joined
/// and not one string, because a `{` in an ordinary Beans string opens an
/// interpolation and CSS is almost nothing but braces.
fn stylesheet() -> string {
    let rules: List<string> = [
        r"body{font:16px/1.5 system-ui,sans-serif;margin:0;background:#fbfbfd;color:#101828}",
        r".page{max-width:44rem;margin:0 auto;padding:2rem 1rem}",
        r"header{border-bottom:1px solid #e4e4e9;padding-bottom:.75rem;margin-bottom:1.5rem}",
        r"h1{margin:0 0 .5rem;font-size:1.5rem}",
        r"button{font:inherit;padding:.5rem .75rem;border:1px solid #d0d5dd;border-radius:.4rem;background:#fff;cursor:pointer}"
    ]
    return "{rules.join("\n")}\n"
}

fn options() -> LatteOptions {
    var options: LatteOptions = new LatteOptions()
    options.title = "__NAME__"
    options.stylesheet("/app.css", stylesheet())
    return move options
}

fn main() {
    let args: List<string> = os.args()
    var port: int = 8080
    if args.len() > 0 && args[0] == "serve" {
        if args.len() > 1 {
            match args[1].to_int() { ok(value) => { port = value } err(_) => {} }
        }
    } else if args.len() > 0 {
        io.println("usage: __NAME__ serve [port]")
        return
    }
    match build(options()) {
        err(problem) => { io.eprintln("__NAME__: {problem}") }
        ok(app) => {
            // stderr, not stdout: `io.println` is block-buffered when stdout is
            // not a terminal, so a line printed there before a server that
            // never returns would not appear until the server was killed.
            io.eprintln("http://127.0.0.1:{port}/")
            match app.serve(port) {
                ok(_) => {}
                err(problem) => { io.eprintln("__NAME__: {problem.msg}") }
            }
        }
    }
}
"##
}

fn html_shell() -> string {
    return r##"<beans>
// The layout every page is wrapped in.
//
// It writes no `<html>`, no `<head>` and no `<script>`. Those belong to the
// shell document, which is not a component: this markup is what the circuit
// re-renders over a socket, and a circuit that re-rendered `<html>` would be
// replacing the page the script driving it is running inside.
package site

import {Layout} from __LATTE__

pub partial class Shell extends Layout {
    pub fn init() { super.init() }
}
</beans>
<div class="page">
  <header><h1>__NAME__</h1></header>
  <main>$slot</main>
</div>
"##
}

fn html_page() -> string {
    return r##"<beans>
// The front page, at `/`.
//
// A click runs `add` on the server, latte re-renders this one component, diffs
// it against the previous frame, and sends only what changed. `notify()` is
// what marks the component dirty; without it the state would move and nothing
// would re-render.
package site

import {page, layout} from __LATTE__

@page(route: r"/")
@layout(name: "Shell")
pub partial class Home extends Component {
    pub count: int = 0
    pub fn init() {}

    pub fn reading() -> string {
        if self.count == 1 { return "1 press" }
        return "{self.count} presses"
    }

    fn add(by: int) {
        self.count += by
        self.notify()
    }
}
</beans>
<section>
  <h2>Counter</h2>
  <p>$self.reading()</p>
  <button on:click={fn(e: MouseEvent) { self.add(1) }}>Add one</button>
</section>
"##
}

// ------------------------------------------------------------------- gitignore

fn git_ignore() -> string {
    return r##"# What a build writes. `generated/` is NOT here: it is checked in, so a clone
# compiles with plain beansc and no latte binary present at all.
build/
"##
}

// ---------------------------------------------------------------------- init

/// The files a project of this target is made of.
/// The browser half of an html project: a module of its own, because a
/// module root holds ONE entry and `main.b` is the server's.
///
/// It is written only for `latte init --with-client`, and its content is
/// exactly what `latte build --client` compiles. An application with no
/// `client` region needs none of it and gets none of it.
fn client_pieces(name: string, latte_path: string) -> List<Piece> {
    var rows: List<string> = [
        "module {name}browser",
        "kind application",
        "",
        "# The browser half of {name}. It requires the application — which is",
        "# what puts the components in the bundle — and the region runtime.",
        "# It requires NOTHING the server needs, which is what keeps the",
        "# server's code out of the WebAssembly module.",
        "require path \"..\"",
    ]
    if latte_path != "" {
        rows.push("require path \"{latte_path}/client\"")
    } else {
        rows.push("require {LATTE_REMOTE} v{LATTE_VERSION}")
    }
    rows.push("")
    return [new Piece("browser/beans.pot", rows.join("\n")),
            new Piece("browser/main.b", client_main())]
}

fn client_main() -> string {
    return r##"// The browser entry: what this application's `client` regions run in.
//
// It imports the generated site package — the `.b` half of every `.bx`,
// which is where the components are — and the region runtime, and nothing
// else. Anything the SERVER needs, a database or a configuration or a
// secret, is not reachable from here, so it is not in the bundle.
//
// The eleven exports are the page's whole surface. They are declared here
// and not in `latte_client` because `--emit shared` exports the
// `pub extern "C"` names of the module being BUILT.
//
//     latte build --client
package main

import __NAME__.generated.site
import {action_cancel_raw, action_result_raw, actions_in_flight,
        boot_raw, catalogue_raw, event_raw, install_action_transport,
        last_error_raw, mount_raw, props_raw, take_raw,
        unmount_raw} from __LATTE_CLIENT__

// The page's half of a server action. Declared HERE, in a module that only
// ever builds for a browser, and installed into the region runtime at boot:
// a declaration inside `latte_client` would put these symbols in the SERVER
// binary too, because a client component that calls an action imports that
// module and the server renders the same component for the prerender.
pub extern "C" fn latte_js_action(call: i32, name: RawPtr<i8>, name_len: i32,
                                  body: RawPtr<i8>, body_len: i32) -> i32
pub extern "C" fn latte_js_action_cancel(call: i32) -> i32

fn send_action(call: int, name: RawPtr<i8>, name_len: int,
               body: RawPtr<i8>, body_len: int) -> int {
    unsafe {
        return latte_js_action(call as i32, name, name_len as i32,
                               body, body_len as i32) as int
    }
}

fn cancel_action(call: int) -> int {
    unsafe { return latte_js_action_cancel(call as i32) as int }
}

pub extern "C" fn latte_client_boot() -> i32 {
    install_action_transport(send_action, cancel_action)
    return boot_raw() as i32
}

pub extern "C" fn latte_client_mount(id: RawPtr<i8>, id_len: i32,
                                     name: RawPtr<i8>, name_len: i32,
                                     props: RawPtr<i8>, props_len: i32) -> i32 {
    return mount_raw(id, id_len as int, name, name_len as int,
                     props, props_len as int) as i32
}

pub extern "C" fn latte_client_props(handle: i32, props: RawPtr<i8>,
                                     props_len: i32) -> i32 {
    return props_raw(handle as int, props, props_len as int) as i32
}

pub extern "C" fn latte_client_event(handle: i32, message: RawPtr<i8>,
                                     message_len: i32) -> i32 {
    return event_raw(handle as int, message, message_len as int) as i32
}

pub extern "C" fn latte_client_take(handle: i32, out: RawPtr<i8>,
                                    cap: i32) -> i32 {
    return take_raw(handle as int, out, cap as int) as i32
}

pub extern "C" fn latte_client_unmount(handle: i32) -> i32 {
    return unmount_raw(handle as int) as i32
}

pub extern "C" fn latte_client_last_error(out: RawPtr<i8>, cap: i32) -> i32 {
    return last_error_raw(out, cap as int) as i32
}

pub extern "C" fn latte_client_catalogue(out: RawPtr<i8>, cap: i32) -> i32 {
    return catalogue_raw(out, cap as int) as i32
}

pub extern "C" fn latte_client_action_result(call: i32, ok: i32,
                                             payload: RawPtr<i8>,
                                             payload_len: i32) -> i32 {
    return action_result_raw(call as int, ok as int, payload,
                             payload_len as int) as i32
}

pub extern "C" fn latte_client_action_cancel(call: i32) -> i32 {
    return action_cancel_raw(call as int) as i32
}

pub extern "C" fn latte_client_in_flight() -> i32 {
    return actions_in_flight() as i32
}

/// Never called in a browser: `--emit shared` has no `_start`. It is here
/// because a module root declares an entry, and it does nothing.
fn main() {}
"##
}

fn pieces_for(name: string, target: bx.Target, latte_path: string,
              with_client: bool) -> List<Piece> {
    var pieces: List<Piece> = [
        new Piece("beans.pot", beans_pot(name, target, latte_path)),
        new Piece("latte.pot", latte_pot(name, target)),
        new Piece(".gitignore", git_ignore()),
    ]
    match target {
        canvas => {
            pieces.push(new Piece("main.b", canvas_main()))
            pieces.push(new Piece("site/shell.bx", canvas_shell()))
            pieces.push(new Piece("site/counter.bx", canvas_page()))
        }
        html => {
            pieces.push(new Piece("main.b", html_main()))
            pieces.push(new Piece("site/shell.bx", html_shell()))
            pieces.push(new Piece("site/home.bx", html_page()))
            if with_client {
                for one: Piece in client_pieces(name, latte_path) {
                    pieces.push(one)
                }
            }
        }
    }
    return move pieces
}

/// Whether a name can be a Beans module — the compiler's rule, asked here so
/// the refusal names the argument, not a manifest the person did not write.
pub fn is_module_name(name: string) -> bool {
    if name == "" { return false }
    var index: int = 0
    for index < name.len() {
        let byte: int = name.byte_at(index)
        let lower: bool = byte >= 97 && byte <= 122
        let upper: bool = byte >= 65 && byte <= 90
        let digit: bool = byte >= 48 && byte <= 57
        let joiner: bool = byte == 95
        if index == 0 && !(lower || upper || joiner) { return false }
        if !(lower || upper || digit || joiner) { return false }
        index += 1
    }
    return true
}

/// A template with its name and latte's packages filled in, spelled the way
/// the project's `beans.pot` reaches latte.
pub fn fill(body: string, name: string, latte_root: string) -> string {
    return body.replace("__LATTE_BROWSER__", latte_import(latte_root, "browser"))
               .replace("__LATTE_COMPOSE__", latte_import(latte_root, "compose"))
               .replace("__LATTE_ANNOTATIONS__", latte_import(latte_root, "annotations"))
               .replace("__LATTE_APP__", latte_import(latte_root, "app"))
               .replace("__LATTE_CLIENT__", latte_import(latte_root, "client"))
               .replace("__LATTE__", latte_import(latte_root, ""))
               .replace("__NAME__", name)
}

/// Write a project into `<name>/`, or into `.` when `here` is set.
pub fn init_project(name: string, target: bx.Target, latte_path: string,
                    here: bool, with_client: bool = false) -> Result<string> {
    if !is_module_name(name) {
        return err("'{name}' cannot be a module name — letters, digits and underscores, not starting with a digit",
                   "bad_name")
    }
    var root: string = name
    if here { root = "." }
    if fs.exists(path.join(root, "beans.pot")) {
        return err("{root}/beans.pot is already there — this is a project already",
                   "exists")
    }
    let pieces: List<Piece> = pieces_for(name, target, latte_path, with_client)
    var latte_root: string = LATTE_REMOTE
    if latte_path != "" { latte_root = "latte" }
    // Every path is checked before anything is written, so a refusal never
    // leaves a half-written project behind.
    for piece: Piece in pieces {
        let full: string = path.join(root, piece.where)
        if fs.exists(full) {
            return err("{full} is already there", "exists")
        }
    }
    for piece: Piece in pieces {
        let full: string = path.join(root, piece.where)
        let folder: string = path.parent(full)
        if folder != "" {
            match Dir.create_all(folder) {
                ok(_) => {}
                err(problem) => { return err("cannot make {folder}: {problem.msg}", "init") }
            }
        }
        fs.write(full, fill(piece.body, name, latte_root))?
    }
    return ok(root)
}
