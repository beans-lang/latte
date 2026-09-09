// tests/_w4_csp_site.b — the server behind test.sh's `csp-browser` leg.
//
// Not a suite (the leading `_` keeps it out of the suite loop): it is a real
// espresso server on a real port, and what it proves is proved by Chrome, not
// by anything it prints.
//
// It serves ONE page twice. `/latte` carries the policy `latte.web`'s
// `security_headers` produces; `/espresso` carries the one espresso's own
// middleware produces. Same HTML, same scripts, same origin — the header is
// the only difference, which is what makes the two outcomes attributable to it.
//
// The verdict block is rendered by the SERVER and overwritten by
// `tests/w4_csp_probe.js`, so a page that arrived and ran nothing prints
// something different from a page that never arrived at all.
package main

import espresso
import std.fs
import std.io
import std.thread
import std.time
import {HeaderOptions, security_headers} from latte.web

/// Where the leg reads the kernel-chosen port. A file and not stdout, because
/// a Beans process writing to a pipe is block-buffered and the leg would be
/// waiting on a line that is sitting in a buffer.
const PORT_FILE: string = "build/w4_csp_port"

fn page(where: string) -> string {
    var out: string = "<!doctype html><html><head><meta charset=\"utf-8\">"
    out = "{out}<title>csp {where}</title></head><body>"
    out = "{out}<pre id=\"verdict\">@@CSP-BEGIN@@\nscript: DID NOT RUN\n@@CSP-END@@</pre>"
    out = "{out}<script src=\"/latte.js\"></script>"
    out = "{out}<script src=\"/probe.js\"></script>"
    return "{out}</body></html>"
}

fn main() {
    let client: string = fs.read("js/latte.js").expect("js/latte.js")
    let probe: string = fs.read("tests/w4_csp_probe.js").expect("probe")

    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")

    // One pipeline, two policies, chosen by path. A second application would
    // mean a second port and a second origin, and then `'self'` would not be
    // comparing the same thing on both halves.
    let latte_layer: fn(espresso.HttpContext,
                        fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> =
        security_headers(new HeaderOptions())
    app.use(fn(context: espresso.HttpContext,
               next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        if context.request.path.starts_with("/espresso") {
            return espresso.security_headers(context, next)
        }
        return latte_layer(context, next)
    }).expect("headers")

    app.get("/latte", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        return espresso.html(page("latte"))
    }).expect("latte")
    app.get("/espresso", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        return espresso.html(page("espresso"))
    }).expect("espresso")
    app.get("/latte.js", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        context.response.header("Content-Type", "text/javascript; charset=utf-8")
        return espresso.text(client)
    }).expect("client")
    app.get("/probe.js", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        context.response.header("Content-Type", "text/javascript; charset=utf-8")
        return espresso.text(probe)
    }).expect("probe")
    // What the `connect-src` half of the probe reaches for.
    app.get("/ping", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        return espresso.text("pong")
    }).expect("ping")

    var options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 0
    options.poll_timeout_ms = 50
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("server")
    let port: int = server.port().expect("port")
    let control: espresso.ServerControl = server.control()

    app.get("/stop", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        let stopped: bool = control.stop().or(false)
        return espresso.text("stopping")
    }).expect("stop")

    let wrote: int = fs.write(PORT_FILE, "{port}\n").expect("port file")

    // A watchdog, because an orphaned server outlives the shell that started
    // it. Sixty seconds is far longer than two headless Chrome runs and far
    // shorter than a day.
    let watchdog: Thread<bool> = thread.spawn(fn() -> bool {
        time.sleep_millis(60000)
        return control.stop().or(false)
    })
    let stats: espresso.ServerStats = server.run().expect("run")
    io.println("served {stats.responses} responses")
}
