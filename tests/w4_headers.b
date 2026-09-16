// tests/w4_headers.b — the Content-Security-Policy a latte page can run under.
//
// `latte.security_headers(options)` exists because espresso's own
// `security_headers` sends `default-src 'none'` (`security.b:73`), which
// blocks both `latte.js` and the WebSocket — and nothing shipped a policy
// that did not.
//
// So a deployment had two choices and both were wrong: mount espresso's
// middleware and serve a page whose client never runs, or mount nothing and
// have no policy at all. § 2 below does not take that claim on faith — it
// runs espresso's own middleware through espresso's own host and reads the
// header off the response. If espresso ever
// fixes its policy, this file says so on the line that justifies latte having
// its own.
//
// **What a CSP test can and cannot prove.** Everything here is about the
// STRING and the headers on the wire, which is necessary and not sufficient: a
// policy a Beans test agrees with is still a policy no browser has read. The
// browser half is `test.sh`'s `csp-browser` leg — real Chrome, a real HTTP
// origin, the real `js/latte.js`, and the same page served twice under the two
// policies, where latte's runs the client and espresso's does not. This file
// is what makes that leg's two outcomes attributable to the header rather than
// to the page.
//
// § 4 is the other half of the claim. `'unsafe-inline'` and `'unsafe-eval'`
// are absent from the policy because `js/latte.js` needs neither, and that is
// a property of the shipped file rather than an intention: it is read off disk
// here and searched for every construct that would force one of them back in.
package main

import github.com/beans-lang/espresso
import std.fs
import std.http
import std.io
import {HeaderOptions, security_headers} from latte.web

pub class Report {
    pub checks: int = 0
    pub bad: int = 0
    pub fn init() {}

    pub fn eq(name: string, got: string, want: string) {
        self.checks += 1
        if got == want {
            io.println("ok {name}")
        } else {
            self.bad += 1
            io.println("FAIL {name}:")
            io.println("   got  {got}")
            io.println("   want {want}")
        }
    }

    pub fn eqi(name: string, got: int, want: int) { self.eq(name, "{got}", "{want}") }
    pub fn yes(name: string, got: bool) { self.eq(name, "{got}", "true") }
    pub fn no(name: string, got: bool) { self.eq(name, "{got}", "false") }
}

/// The policy latte sends by default, written down before it was run.
///
/// `default-src 'none'` and then every source latte actually needs, named:
/// anything a page reaches for that is not on this list is refused rather than
/// inherited from a permissive fallback. `base-uri 'none'` is here because an
/// injected `<base>` re-points every relative URL on the page — including the
/// one the client is served from — and `form-action 'self'` because
/// `form-action` does not fall back to `default-src` in every engine and this
/// is a forms framework.
const LATTE_POLICY: string =
    "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

/// What espresso sends, measured in § 2 rather than copied from its source.
const ESPRESSO_POLICY: string = "default-src 'none'; frame-ancestors 'none'"

fn header_of(response: espresso.TestResponse, name: string) -> string {
    return response.headers.get(name).or("<absent>")
}

/// An app with one page route and one middleware, so the header under test is
/// the only thing that differs between the two halves of § 2 and § 3.
fn app_with(headers: fn(espresso.HttpContext,
                        fn(espresso.HttpContext) -> Result<bool>) -> Result<bool>,
            own_policy: bool) -> espresso.WebApplication {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    let app: espresso.WebApplication = builder.build().expect("app")
    app.use(headers).expect("headers")
    app.get("/page", fn(context: espresso.HttpContext) -> Result<espresso.ActionResult> {
        if own_policy {
            context.response.header("Content-Security-Policy", "default-src 'self'")
        }
        return espresso.html("<p>hello</p>")
    }).expect("page")
    return app
}

fn main() {
    let r: Report = new Report()

    // ---- 1. the policy string --------------------------------------------
    io.println("-- 1. the default policy")
    let options: HeaderOptions = new HeaderOptions()
    r.eq("1.1 the whole policy, in a fixed directive order",
         options.policy(), LATTE_POLICY)
    r.yes("1.2 scripts may load from the page's own origin",
          options.policy().contains("script-src 'self'"))
    r.yes("1.3 and the socket may open to it",
          options.policy().contains("connect-src 'self'"))
    // The two that would make the whole policy decorative.
    r.no("1.4 no 'unsafe-inline'", options.policy().contains("unsafe-inline"))
    r.no("1.5 no 'unsafe-eval'", options.policy().contains("unsafe-eval"))
    r.yes("1.6 and framing is refused outright",
          options.policy().contains("frame-ancestors 'none'"))

    // ---- 2. what espresso's own middleware sends -------------------------
    //
    // Measured, not quoted. This is the whole reason latte ships a second one.
    io.println("")
    io.println("-- 2. espresso's security_headers, run and read")
    let their_app: espresso.WebApplication =
        app_with(espresso.security_headers, false)
    let their_host: espresso.TestHost = new espresso.TestHost(their_app)
    let theirs: espresso.TestResponse = their_host.get("/page").expect("theirs")
    let their_policy: string = header_of(theirs, "Content-Security-Policy")
    r.eq("2.1 espresso still sends the policy we measured", their_policy, ESPRESSO_POLICY)
    r.no("2.2 it names no script source at all", their_policy.contains("script-src"))
    r.no("2.3 and no connect source", their_policy.contains("connect-src"))
    // `default-src 'none'` with no `script-src` is what blocks `js/latte.js`:
    // a missing directive falls back to `default-src`, and that one refuses
    // everything. The browser leg is where this stops being an inference.
    r.yes("2.4 so every fetch falls back to a default that refuses everything",
          their_policy.contains("default-src 'none'"))
    let closed_theirs: bool = their_host.close().or(false)

    // ---- 3. latte's, on a real response ----------------------------------
    io.println("")
    io.println("-- 3. the four headers, through the real pipeline")
    let app: espresso.WebApplication =
        app_with(security_headers(new HeaderOptions()), false)
    let host: espresso.TestHost = new espresso.TestHost(app)
    let page: espresso.TestResponse = host.get("/page").expect("page")
    r.eqi("3.1 the page is served", page.status, 200)
    r.eq("3.2 the policy", header_of(page, "Content-Security-Policy"), LATTE_POLICY)
    r.eq("3.3 nosniff", header_of(page, "X-Content-Type-Options"), "nosniff")
    r.eq("3.4 the older framing header goes out beside frame-ancestors",
         header_of(page, "X-Frame-Options"), "DENY")
    r.eq("3.5 and a referrer policy", header_of(page, "Referrer-Policy"), "no-referrer")

    // A 404 is espresso's own answer, produced past the route table. The
    // headers are set after `next`, so an answer no latte handler wrote still
    // carries them — a page framework whose 404 has no CSP has a page with no
    // CSP.
    let missing: espresso.TestResponse = host.get("/nowhere").expect("missing")
    r.eqi("3.6 a 404 is the pipeline's own answer", missing.status, 404)
    r.eq("3.7 and it carries the policy too",
         header_of(missing, "Content-Security-Policy"), LATTE_POLICY)
    let closed: bool = host.close().or(false)

    // A handler that set its own policy keeps it. Middleware that ran after
    // the handler and overwrote it would silently undo a deliberate choice —
    // an embed page loosening `frame-ancestors`, say — and the author would
    // have no way to see it from the code they wrote.
    io.println("")
    io.println("-- 3b. a handler's own policy is not overwritten")
    let own_app: espresso.WebApplication =
        app_with(security_headers(new HeaderOptions()), true)
    let own_host: espresso.TestHost = new espresso.TestHost(own_app)
    let own: espresso.TestResponse = own_host.get("/page").expect("own")
    r.eq("3.8 the handler's policy stands",
         header_of(own, "Content-Security-Policy"), "default-src 'self'")
    r.eq("3.9 and the other three still go out",
         "{header_of(own, "X-Content-Type-Options")}/{header_of(own, "X-Frame-Options")}/{header_of(own, "Referrer-Policy")}",
         "nosniff/DENY/no-referrer")
    let closed_own: bool = own_host.close().or(false)

    // ---- 4. why the policy needs no unsafe- anything ---------------------
    //
    // Read off disk. A policy that had to grow `'unsafe-eval'` later because
    // the client picked up an `eval` would grow it for every page in every
    // deployment, so the claim is checked against the shipped file rather than
    // remembered.
    io.println("")
    io.println("-- 4. js/latte.js needs no 'unsafe-inline' and no 'unsafe-eval'")
    match fs.read("js/latte.js") {
        err(problem) => {
            // A FAILURE and never a skip: a check that silently skips when its
            // input goes missing is green forever and catches nothing.
            r.eq("4.0 js/latte.js is readable", "{problem.kind}", "readable")
        }
        ok(source) => {
            r.yes("4.0 js/latte.js is readable", source.len() > 1000)
            r.no("4.1 no eval(", source.contains("eval("))
            r.no("4.2 no new Function(", source.contains("new Function("))
            r.no("4.3 no dynamic import()", source.contains("import("))
            r.no("4.4 no setTimeout with a string body", source.contains("setTimeout(\""))
            r.no("4.5 no document.write", source.contains("document.write"))
            r.no("4.6 no javascript: URL", source.contains("javascript:"))
            // The two it DOES need, and the two directives that carry them.
            r.yes("4.7 it opens a WebSocket, which is why connect-src is named",
                  source.contains("new WebSocket("))
            r.yes("4.8 and an XMLHttpRequest for enhanced navigation",
                  source.contains("new XMLHttpRequest("))
        }
    }

    // ---- 5. a deployment that is not one origin --------------------------
    //
    // A socket on another host is the common real deployment, and `'self'` is
    // not enough for it on any engine that predates CSP3's scheme matching.
    // The value must land in `connect-src` and in no other directive.
    io.println("")
    io.println("-- 5. the options are the escape, and they are scoped")
    var spread: HeaderOptions = new HeaderOptions()
    spread.connect = ["'self'", "wss://live.example.com"]
    spread.script = ["'self'", "https://cdn.example.com"]
    r.eq("5.1 both lists land in their own directive", spread.policy(),
         "default-src 'none'; script-src 'self' https://cdn.example.com; connect-src 'self' wss://live.example.com; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
    var framed: HeaderOptions = new HeaderOptions()
    framed.frame_ancestors = ["https://portal.example.com"]
    framed.referrer = "strict-origin-when-cross-origin"
    let framed_app: espresso.WebApplication =
        app_with(security_headers(framed), false)
    let framed_host: espresso.TestHost = new espresso.TestHost(framed_app)
    let embedded: espresso.TestResponse = framed_host.get("/page").expect("framed")
    r.yes("5.2 a page that IS meant to be framed says so in the policy",
          header_of(embedded, "Content-Security-Policy").contains(
              "frame-ancestors https://portal.example.com"))
    // And the legacy header cannot express that, so it stays DENY and the
    // modern directive is what a modern browser reads. Saying `ALLOWALL` here
    // would be inventing a value X-Frame-Options never had.
    r.eq("5.3 the legacy header stays DENY, having no way to say it",
         header_of(embedded, "X-Frame-Options"), "DENY")
    r.eq("5.4 and the referrer policy is the one asked for",
         header_of(embedded, "Referrer-Policy"), "strict-origin-when-cross-origin")
    let closed_framed: bool = framed_host.close().or(false)

    io.println("")
    io.println("{r.checks} checks, {r.bad} bad")
}
