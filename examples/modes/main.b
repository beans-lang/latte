// `examples/modes/main.b` — one page, five execution modes.
//
//     beansc run examples/modes/main.b -- serve 8080   # open http://127.0.0.1:8080/
//     beansc run examples/modes/main.b -- check        # what the check runs
//
// Run it from the latte module root: the client script, the region runtime's
// loader and the browser bundle are all read relative to the working
// directory.
//
// ## What it is for
//
// `examples/cafe` is the reference for the seam and `examples/board` for
// everything above it. This one is the reference for WHERE a component runs:
//
//   * a **server** counter, which is the page's own mode and therefore not a
//     region at all — no element, no descriptor, nothing;
//   * a **client** counter, the SAME class with one attribute different,
//     running in the browser with no socket and no request;
//   * a **client block**, whose markup becomes a component of its own;
//   * a **client editor** calling a typed server action whose implementation
//     is in `modes.server` and is not in the browser bundle;
//   * an **auto** counter, server until the browser reports a bundle;
//   * and a plain form, which posts and answers with JavaScript switched off.
//
// ## `check` prints the page, not a summary
//
// Every claim above is about bytes in a document, so `check` renders the page
// three ways — cold, warm, and after a post — and prints each. A summary
// would pass for an application that produced the right counts and the wrong
// markup, which is the failure this whole feature can have.
package main

import github.com/beans-lang/barista
import github.com/beans-lang/espresso
import std.fs
import std.io
import std.os
import {LatteApp, LatteOptions, build_with} from latte_app
import {PageRequest, PageResponse, RenderMode, render_shell} from latte
import {Counter, Editor, Home, Shell} from modes.site
import {NoteActions, Notes, Saved} from modes.server

/// Where `latte build --client` puts the bundle. It is read at mount, so a
/// `check` that never mounts does not need it to exist — and `serve` says
/// so by name if it is missing.
const BUNDLE: string = "build/browser/modes.wasm"

fn options() -> LatteOptions {
    var options: LatteOptions = new LatteOptions()
    options.title = "Render modes"
    // A fixed clock, so the antiforgery token in the printed document is a
    // pure function of inputs this file chose.
    options.now = 1000
    options.client_module = BUNDLE
    return move options
}

fn services() -> barista.ServiceCollection {
    var services: barista.ServiceCollection = new barista.ServiceCollection()
    // One store for the worker, so two calls to `notes.save` count up.
    services.singleton<Notes>().expect("notes")
    // The action group itself, because the container is what builds it and
    // its `init` takes the store.
    services.transient<NoteActions>().expect("note actions")
    return move services
}

/// One request, rendered.
fn ask(app: LatteApp, method: string, path: string, body: string,
       bundle: bool) -> string {
    var request: PageRequest = new PageRequest()
    request.method = method
    request.path = path
    request.body = body
    request.session = "abcdefabcdefabcdefabcdef"
    request.bundle_ready = bundle
    let answer: PageResponse = app.host.handle_with(request, 1000, none, none)
    if answer.status != 200 { return "status {answer.status}: {answer.detail()}" }
    return answer.body
}

fn check(app: LatteApp) {
    io.println("== the page, with no browser bundle yet ==")
    io.println(ask(app, "GET", "/", "", false))

    io.println("")
    io.println("== the same page, once the browser has one ==")
    io.println(ask(app, "GET", "/", "", true))

    io.println("")
    io.println("== the form, posted with no script at all ==")
    io.println(ask(app, "POST", "/",
                   "note=hello&__latte_token={app.host.token_for("abcdefabcdefabcdefabcdef", "note", 1000)}",
                   false))

    io.println("")
    io.println("== the whole document, so the two scripts and the token show ==")
    // A FIXED token, and not a real one: the signing key is fresh per
    // process, so a real token would make this expected output a photograph of
    // one run. What the document has to show is that the attribute is
    // there and where it sits; whether the MAC verifies is
    // `tests/w4_actions.b`'s question.
    app.shell.action_token = "1900.0123456789abcdef"
    match render_shell(app.shell, "<p>the body</p>") {
        ok(document) => { io.print(document) }
        err(problem) => { io.println("the shell refused: {problem}") }
    }

    io.println("")
    io.println("== what this application declares ==")
    io.println(app.set.modes.report())
    io.println("actions: {app.actions.names().join(", ")}")
}

fn main() {
    let args: List<string> = os.args()
    var command: string = "check"
    if args.len() > 0 { command = args[0] }

    match build_with(options(), services()) {
        err(problem) => { io.println("latte refused to start: {problem}") }
        ok(app) => {
            if command == "serve" {
                var port: int = 8080
                if args.len() > 1 {
                    match args[1].to_int() { ok(value) => { port = value } err(_) => {} }
                }
                if !fs.exists(BUNDLE) {
                    io.eprintln("LATTE-REFUSED no browser bundle at {BUNDLE} — build it with: bash tools/wasm_build.sh examples/modes/browser/main.b {BUNDLE}")
                    return
                }
                match app.serve(port) {
                    ok(_) => {}
                    err(problem) => { io.eprintln("LATTE-REFUSED {problem.msg}") }
                }
                return
            }
            if command != "check" {
                io.println("usage: main [check | serve <port>]")
                return
            }
            check(app)
        }
    }
}
