// `tests/w9_shell.b` — the page shell and the asset route.
//
// These are the two pieces that turn a rendered page body into something a
// browser can run: `latte.render_shell` writes the document, and
// `latte.web.map_client` serves the script the document points at. Before
// them, `map_pages` answered a fragment and `script-src 'self'` named an
// origin that served nothing.
//
// **Every refusal in § 4 has an accepted case beside it, in the same
// subsection, differing in ONE character where that is possible.** Without
// the accepted case you cannot tell "refused for the right reason" from
// "refused earlier, for a different one", and `ShellOptions.faults()`
// collects EVERY fault rather than stopping at the first, so a coarse rule
// standing in front of a specific one would show up here as a message with
// the wrong text rather than as a silent pass. The message is asserted, not
// just the count.
//
// § 6 is the asset route's own refusals, which happen at REGISTRATION and not
// at request time. A `map_client` whose file is missing must answer `err`
// while the application is still starting; a deployment that learned about it
// from a browser's console would have shipped a page whose every button does
// nothing.
package main

import github.com/beans-lang/espresso
import std.http
import std.io
import {ShellOptions, render_shell, BOOT_ATTRIBUTE, ROOT_ID,
        CLIENT_PATH as SHELL_CLIENT_PATH,
        CLIENT_BUNDLE_PATH as SHELL_BUNDLE_PATH,
        CLIENT_MODULE_SCRIPT as SHELL_MODULE_SCRIPT,
        SOCKET_PATH as SHELL_SOCKET_PATH} from latte
import {ClientOptions, HeaderOptions, CLIENT_PATH, CLIENT_TYPE, CLIENT_FILE,
        CLIENT_BUNDLE_PATH, CLIENT_MODULE_SCRIPT,
        SOCKET_PATH, map_asset, map_client} from latte.web

// ================================================================ the report

class Report {
    pub checks: int = 0
    pub failures: int = 0
    pub fn init() {}

    pub fn eq(what: string, got: string, want: string) {
        self.checks += 1
        if got == want { io.println("ok {what}") }
        else {
            self.failures += 1
            io.println("FAIL {what}")
            io.println("     got  {got}")
            io.println("     want {want}")
        }
    }
    pub fn eqi(what: string, got: int, want: int) { self.eq(what, "{got}", "{want}") }
    pub fn yes(what: string, got: bool) { self.eq(what, "{got}", "true") }
    pub fn no(what: string, got: bool) { self.eq(what, "{got}", "false") }
}

// ================================================================ helpers

/// The document a set of options renders, or `"REFUSED: <the first fault>"`.
///
/// One helper for both outcomes so a section that expects a document and a
/// section that expects a refusal read the same, and so a refusal that has
/// quietly become a document shows up as a diff rather than as a skipped
/// branch.
fn document_of(options: ShellOptions, body: string) -> string {
    match render_shell(options, body) {
        ok(text) => { return text }
        err(problem) => { return "REFUSED: {problem}" }
    }
}

/// Every fault a set of options has, joined. `""` means it is usable.
fn faults_of(options: ShellOptions) -> string {
    return options.faults().join(" ~ ")
}

/// The options this repo ships by default, with a body-free page.
fn plain() -> ShellOptions {
    var options: ShellOptions = new ShellOptions()
    return move options
}

fn header_of(reply: espresso.TestResponse, name: string) -> string {
    match reply.headers.get(name) {
        some(value) => { return value }
        none => { return "" }
    }
}

fn one_header(name: string, value: string) -> http.Headers {
    var headers: http.Headers = new http.Headers()
    headers.add(name, value)
    return move headers
}

// ================================================================ the check

fn main() {
    let r: Report = new Report()
    section_constants(r)
    section_default(r)
    section_knobs(r)
    section_refusals(r)
    section_inline(r)
    section_assets(r)
    section_client_region(r)
    io.println("")
    io.println("{r.checks} checks, {r.failures} bad")
}

/// § 7 — the loader a page carries when the application ships a browser
/// bundle, and the pair rule that keeps a half-configured one out.
fn section_client_region(r: Report) {
    io.println("")
    io.println("-- 7. the browser bundle's loader")

    // The control first, and it is the important one: a page with no client
    // region must carry exactly what it carried before this existed.
    var none_: ShellOptions = plain()
    r.no("7.1 no client region, no second script",
         document_of(none_, "<p>hi</p>").contains("type=\"module\""))

    var both: ShellOptions = plain()
    both.client_script = "/_latte/latte-client.js"
    both.client_module = "/_latte/app.wasm"
    let page: string = document_of(both, "<p>hi</p>")
    r.yes("7.2 with both, the module tag is in the head",
          page.contains("<script type=\"module\" src=\"/_latte/latte-client.js\" data-latte-wasm=\"/_latte/app.wasm\"></script>"))
    r.yes("7.3 and it is after the client script, which defines the applier",
          at_of(page, "latte-client.js") > at_of(page, "data-latte-boot"))
    r.yes("7.4 the body is unchanged", page.contains("<p>hi</p>"))

    // Half of a pair is a deployment half-done, and both halves are refused
    // by name rather than served.
    var loader_only: ShellOptions = plain()
    loader_only.client_script = "/_latte/latte-client.js"
    r.eq("7.5 a loader with no bundle", first_fault(loader_only),
         "shell: client_script is \"/_latte/latte-client.js\" and client_module is empty; the loader would run and find no bundle to load")
    var bundle_only: ShellOptions = plain()
    bundle_only.client_module = "/_latte/app.wasm"
    r.eq("7.6 a bundle with no loader", first_fault(bundle_only),
         "shell: client_module is \"/_latte/app.wasm\" and client_script is empty; nothing in the page would load the bundle, and every client region would stay a blank element")

    // A bundle on another origin is NOT refused here: the loader fetches
    // whatever url it is given, and a deployment that stages its assets on a
    // CDN is a real deployment. What stops it by default is latte's own
    // `connect-src 'self'`, which that deployment has to widen on purpose.
    var elsewhere: ShellOptions = plain()
    elsewhere.client_script = "/_latte/latte-client.js"
    elsewhere.client_module = "https://cdn.example.com/app.wasm"
    r.eq("7.7 a bundle on another origin is a deployment's choice",
         first_fault(elsewhere), "(none)")

    // What IS refused is a value that would break out of the attribute it
    // travels in, the same rule every other url in the shell gets.
    var hostile: ShellOptions = plain()
    hostile.client_script = "/_latte/latte-client.js"
    hostile.client_module = "/app.wasm\" onload=\"steal()"
    r.yes("7.8 and a quote in one is refused before it reaches the document",
          first_fault(hostile).contains("client_module"))
}

/// Where `needle` sits in `text`, or -1.
fn at_of(text: string, needle: string) -> int {
    match text.find(needle) {
        some(at) => { return at }
        none => { return -1 }
    }
}

/// The first thing wrong with these options, or `"(none)"`.
fn first_fault(options: ShellOptions) -> string {
    let faults: List<string> = options.faults()
    if faults.len() == 0 { return "(none)" }
    return faults[0]
}

// ---------------------------------------------------------------- § 1

/// Two packages, one path, spelled twice.
///
/// A package under `latte/` may not import its own module root, so `shell.b`
/// and `web/assets.b` each carry `CLIENT_PATH` and `SOCKET_PATH`. Drift here
/// is a page whose `<script src>` is a 404 and a client that dials a socket
/// nothing is listening on — silent in both cases. This is the only thing that
/// makes it loud.
fn section_constants(r: Report) {
    io.println("-- 1. the two spellings of one path")
    r.eq("1.1 the client path", SHELL_CLIENT_PATH, CLIENT_PATH)
    r.eq("1.2 the socket path", SHELL_SOCKET_PATH, SOCKET_PATH)
    r.eq("1.3 the shell's default script src is that path",
         plain().script, CLIENT_PATH)
    r.eq("1.4 the shell's default socket is that path", plain().socket, SOCKET_PATH)
    r.eq("1.5 the client-region loader's path", SHELL_MODULE_SCRIPT,
         CLIENT_MODULE_SCRIPT)
    r.eq("1.6 the browser bundle's path", SHELL_BUNDLE_PATH, CLIENT_BUNDLE_PATH)
    r.eq("1.7 the boot attribute is the one latte.js reads",
         BOOT_ATTRIBUTE, "data-latte-boot")
    r.eq("1.8 the root element id", ROOT_ID, "latte-root")
}

// ---------------------------------------------------------------- § 2

/// The document, byte for byte.
///
/// Written out in full rather than asserted piecewise: a check that the
/// document "contains a script tag" passes on a document that also carries an
/// inline one, and the ORDER of the head matters — a `<script defer>` before
/// the stylesheet link changes what a browser has when it runs.
fn section_default(r: Report) {
    io.println("")
    io.println("-- 2. the document latte ships")
    var options: ShellOptions = plain()
    options.title = "Orders"
    r.eq("2.1 the whole document",
         document_of(options, "<p>hi</p>"),
         "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>Orders</title>\n<script src=\"/_latte/latte.js\" defer data-latte-boot=\"1\" data-latte-ws=\"/_latte/ws\" data-latte-root=\"latte-root\"></script>\n</head>\n<body>\n<div id=\"latte-root\"><p>hi</p></div>\n</body>\n</html>\n")
    // The body is inserted RAW. It is what `Renderer.html()` produced, already
    // escaped by the serializer; escaping it again would show a page its own
    // tags as text. This is the check that says so out loud.
    r.yes("2.2 the page body is inserted raw, not escaped again",
          document_of(options, "<p>a &amp; b</p>").contains("<p>a &amp; b</p>"))
}

// ---------------------------------------------------------------- § 3

fn section_knobs(r: Report) {
    io.println("")
    io.println("-- 3. what the knobs change")

    var untitled: ShellOptions = plain()
    r.no("3.1 no title means no <title> element at all",
         document_of(untitled, "").contains("<title>"))

    var titled: ShellOptions = plain()
    titled.title = "5 > 3 & <b>bold</b>"
    r.yes("3.2 a title is escaped as text",
          document_of(titled, "").contains(
              "<title>5 &gt; 3 &amp; &lt;b&gt;bold&lt;/b&gt;</title>"))

    var styled: ShellOptions = plain()
    styled.stylesheets = ["/a.css", "/b.css"]
    let with_styles: string = document_of(styled, "")
    r.yes("3.3 stylesheets are emitted in order",
          with_styles.contains(
              "<link rel=\"stylesheet\" href=\"/a.css\">\n<link rel=\"stylesheet\" href=\"/b.css\">"))

    // A page with no circuit still gets the client: enhanced navigation and
    // streamed chunks need it and neither needs a socket. What it does NOT get
    // is the boot attribute, and `boot()` then answers null and opens nothing.
    var quiet: ShellOptions = plain()
    quiet.circuit = false
    let without: string = document_of(quiet, "")
    r.yes("3.4 a page with no circuit still loads the client",
          without.contains("<script src=\"/_latte/latte.js\" defer"))
    r.no("3.5 and carries no boot attribute", without.contains(BOOT_ATTRIBUTE))
    r.no("3.6 and names no socket", without.contains("data-latte-ws"))

    // The other door: a host that decides ids itself. latte's own shell never
    // writes this — the id is normally a server-minted reconnect credential,
    // and printing one into cacheable HTML would leak it — but the attribute
    // is what `latte.js` reads regardless, so a host with its own reason to
    // assign one still can.
    var named: ShellOptions = plain()
    named.circuit_id = "0123456789abcdef0123456789abcdef"
    r.yes("3.7 a host-decided id reaches the script tag",
          document_of(named, "").contains(
              "data-latte-circuit=\"0123456789abcdef0123456789abcdef\""))
    r.no("3.8 and latte's own default never writes one",
         document_of(plain(), "").contains("data-latte-circuit"))

    var moved: ShellOptions = plain()
    moved.root_id = "app"
    let elsewhere: string = document_of(moved, "<i>x</i>")
    r.yes("3.9 the root element is renamed in both places it appears",
          elsewhere.contains("data-latte-root=\"app\"") &&
          elsewhere.contains("<div id=\"app\"><i>x</i></div>"))
}

// ---------------------------------------------------------------- § 4

/// Every refusal, each with the accepted case beside it.
fn section_refusals(r: Report) {
    io.println("")
    io.println("-- 4. the refusals, each beside the case it must accept")

    // --- 4a. lang ---------------------------------------------------------
    var good_lang: ShellOptions = plain()
    good_lang.lang = "en-GB"
    r.eq("4a.1 ACCEPTED: a language tag with a hyphen", faults_of(good_lang), "")
    var spaced_lang: ShellOptions = plain()
    spaced_lang.lang = "en GB"
    r.eq("4a.2 a space is not a language tag", faults_of(spaced_lang),
         "shell: lang \"en GB\" is not a language tag; it reaches <html lang> and must be ASCII letters, digits and hyphens")
    var empty_lang: ShellOptions = plain()
    empty_lang.lang = ""
    r.eq("4a.3 and neither is nothing", faults_of(empty_lang),
         "shell: lang \"\" is not a language tag; it reaches <html lang> and must be ASCII letters, digits and hyphens")

    // --- 4b. root_id ------------------------------------------------------
    var good_id: ShellOptions = plain()
    good_id.root_id = "latte_root-2"
    r.eq("4b.1 ACCEPTED: letters, digits, '-' and '_'", faults_of(good_id), "")
    var leading_digit: ShellOptions = plain()
    leading_digit.root_id = "2root"
    r.eq("4b.2 an id may not start with a digit", faults_of(leading_digit),
         "shell: root_id \"2root\" is not an element id; latte.js reads it with getElementById and it must start with a letter and hold only letters, digits, '-' and '_'")
    var quoted_id: ShellOptions = plain()
    quoted_id.root_id = "root\"onload=x"
    r.yes("4b.3 an id that would end the attribute is refused",
          faults_of(quoted_id).starts_with("shell: root_id"))

    // --- 4c. script and stylesheet ----------------------------------------
    var same_origin: ShellOptions = plain()
    same_origin.script = "/static/latte.js"
    r.eq("4c.1 ACCEPTED: another path on this origin", faults_of(same_origin), "")
    // A CDN is NOT refused. `HeaderOptions.script` is a list precisely so a
    // deployment can name one, and a shell that refused every off-origin src
    // would make that list a lie.
    var cdn: ShellOptions = plain()
    cdn.script = "https://cdn.example.com/latte-1.0.0.js"
    r.eq("4c.2 ACCEPTED: a CDN, because HeaderOptions exists to allow one",
         faults_of(cdn), "")
    var scripted: ShellOptions = plain()
    scripted.script = "javascript:alert(1)"
    r.eq("4c.3 a javascript: src is refused", faults_of(scripted),
         "shell: script \"javascript:alert(1)\" is a javascript: URL")
    var uppercase: ShellOptions = plain()
    uppercase.script = "JavaScript:alert(1)"
    r.eq("4c.4 and the check is not fooled by case", faults_of(uppercase),
         "shell: script \"JavaScript:alert(1)\" is a javascript: URL")
    var data_url: ShellOptions = plain()
    data_url.script = "data:text/javascript,alert(1)"
    r.eq("4c.5 a data: src is refused", faults_of(data_url),
         "shell: script \"data:text/javascript,alert(1)\" is a data: URL; latte refuses those wherever a browser would fetch them")
    // Two different bytes, two different branches. The quote is refused for
    // ending the attribute; a space is refused for splitting the value. The
    // quote comes FIRST in this string, at index 5, and the message says so —
    // which is how this check tells the two rules apart rather than accepting
    // whichever fired.
    var quoted: ShellOptions = plain()
    quoted.script = "/x.js\" onerror=\"go()"
    r.eq("4c.6 a quote would end the attribute and start another", faults_of(quoted),
         "shell: script \"/x.js\" onerror=\"go()\" holds the character \", which ends the attribute or the tag")
    var spaced: ShellOptions = plain()
    spaced.script = "/two words.js"
    r.eq("4c.6b and a space splits the value in two", faults_of(spaced),
         "shell: script \"/two words.js\" holds byte 32 at 4; whitespace and control bytes split an attribute value in two")
    var empty_src: ShellOptions = plain()
    empty_src.script = ""
    r.eq("4c.7 an empty src is refused", faults_of(empty_src), "shell: script is empty")
    var styles_ok: ShellOptions = plain()
    styles_ok.stylesheets = ["/a.css", "/b.css"]
    r.eq("4c.8 ACCEPTED: two stylesheets", faults_of(styles_ok), "")
    var styles_bad: ShellOptions = plain()
    styles_bad.stylesheets = ["/a.css", "javascript:x"]
    r.eq("4c.9 and the message names WHICH one", faults_of(styles_bad),
         "shell: stylesheet 1 \"javascript:x\" is a javascript: URL")

    // --- 4d. the socket ---------------------------------------------------
    // The one rule that is about the client's own code: `latte.js` builds the
    // socket URL as `scheme + "//" + location.host + path`, so a URL here
    // produces `ws://host/wss://other/ws`.
    var socket_ok: ShellOptions = plain()
    socket_ok.socket = "/live"
    r.eq("4d.1 ACCEPTED: an absolute path", faults_of(socket_ok), "")
    var socket_url: ShellOptions = plain()
    socket_url.socket = "wss://live.example.com/ws"
    r.eq("4d.2 an absolute URL is refused", faults_of(socket_url),
         "shell: socket \"wss://live.example.com/ws\" must be an absolute path on this origin; latte.js builds the socket URL as scheme + \"//\" + location.host + this, so a URL here dials an address that does not exist")
    var protocol_relative: ShellOptions = plain()
    protocol_relative.socket = "//live.example.com/ws"
    r.eq("4d.3 and so is a protocol-relative one", faults_of(protocol_relative),
         "shell: socket \"//live.example.com/ws\" must be an absolute path on this origin; latte.js builds the socket URL as scheme + \"//\" + location.host + this, so a URL here dials an address that does not exist")
    var relative: ShellOptions = plain()
    relative.socket = "ws"
    r.eq("4d.4 and so is a relative one", faults_of(relative),
         "shell: socket \"ws\" must be an absolute path on this origin; latte.js builds the socket URL as scheme + \"//\" + location.host + this, so a URL here dials an address that does not exist")

    // --- 4e. a host-decided circuit id ------------------------------------
    var id_ok: ShellOptions = plain()
    id_ok.circuit_id = "0123456789abcdef"
    r.eq("4e.1 ACCEPTED: exactly the 16 characters CircuitSet.open needs",
         faults_of(id_ok), "")
    var id_short: ShellOptions = plain()
    id_short.circuit_id = "0123456789abcde"
    r.eq("4e.2 one character fewer is an id no socket can use",
         faults_of(id_short),
         "shell: circuit_id is 15 characters; CircuitSet.open refuses anything under 16, so this page would be served an id no socket can use")
    var id_bad: ShellOptions = plain()
    id_bad.circuit_id = "0123456789abcde\"x"
    r.eq("4e.3 and a character that would end the attribute is refused",
         faults_of(id_bad),
         "shell: circuit_id \"0123456789abcde\"x\" holds a character that is not a letter, a digit, '-' or '_'")
    var contradiction: ShellOptions = plain()
    contradiction.circuit = false
    contradiction.circuit_id = "0123456789abcdef"
    r.eq("4e.4 an id on a page that says it wants no circuit is a contradiction",
         faults_of(contradiction),
         "shell: circuit_id is set on a page that says circuit = false; one of the two is a mistake and the shell will not guess which")

    // --- 4f. render_shell refuses rather than emitting ---------------------
    // `faults()` is advice; this is the control. A host that never called
    // `faults()` must still not be able to serve a broken document.
    var broken: ShellOptions = plain()
    broken.socket = "wss://live.example.com/ws"
    r.yes("4f.1 render_shell refuses what faults() names",
          document_of(broken, "<p>x</p>").starts_with("REFUSED: shell: socket"))
    r.no("4f.2 and emits nothing at all",
         document_of(broken, "<p>x</p>").contains("<!doctype"))
    r.yes("4f.3 ACCEPTED: the same options with the URL made a path",
          document_of(socket_ok, "<p>x</p>").starts_with("<!doctype html>"))
}

// ---------------------------------------------------------------- § 5

/// The claim `security_headers` makes about every page latte serves.
///
/// `tests/w4_headers.b` § 4 greps `js/latte.js` for `eval`, `new Function` and
/// `<script`. This is the other half: the DOCUMENT the shell writes, which is
/// the only other thing a `script-src 'self'` policy has to survive.
fn section_inline(r: Report) {
    io.println("")
    io.println("-- 5. nothing in the document needs 'unsafe-inline'")
    var options: ShellOptions = plain()
    options.title = "x"
    options.stylesheets = ["/a.css"]
    options.circuit_id = "0123456789abcdef"
    let document: string = document_of(options, "<p>body</p>")
    r.no("5.1 no inline script", document.contains("<script>"))
    r.no("5.2 no inline style element", document.contains("<style"))
    r.no("5.3 no style attribute", document.contains(" style="))
    r.no("5.4 no on* attribute", document.contains(" on"))
    r.no("5.5 no javascript: anywhere", document.to_lower().contains("javascript:"))
    r.yes("5.6 exactly one <script, and it has a src",
          document.contains("<script src=\"") &&
          !document.slice(document.find("<script src=\"").or(0) + 13,
                          document.len()).contains("<script"))
    // The policy this document is served under, whole, so a directive that
    // quietly disappeared shows up here as well as in w4_headers.
    r.eq("5.7 and the policy it holds under", new HeaderOptions().policy(),
         "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
}

// ---------------------------------------------------------------- § 6

/// The asset route, and the refusals that happen while the app is starting.
fn section_assets(r: Report) {
    io.println("")
    io.println("-- 6. the asset route")
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    match builder.build() {
        err(problem) => { io.println("FAIL the app did not build: {problem.msg}") }
        ok(app) => { assets(r, app) }
    }
}

fn assets(r: Report, app: espresso.WebApplication) {
    // --- 6a. registration refusals ---------------------------------------
    var missing: ClientOptions = new ClientOptions()
    missing.file = "js/nowhere.js"
    match map_client(app, missing) {
        ok(_) => { r.eq("6a.1 a missing client file", "registered", "refused") }
        err(problem) => {
            r.yes("6a.1 a missing client file is refused AT STARTUP",
                  problem.msg.starts_with(
                      "latte cannot read its client script at \"js/nowhere.js\""))
        }
    }
    match map_asset(app, "latte.js", "x", "text/javascript", "no-cache") {
        ok(_) => { r.eq("6a.2 a relative asset path", "registered", "refused") }
        err(problem) => {
            r.eq("6a.2 an asset path that is not absolute is refused",
                 problem.msg, "an asset path must start with '/': \"latte.js\"")
        }
    }
    match map_asset(app, "/empty.css", "", "text/css", "no-cache") {
        ok(_) => { r.eq("6a.3 an empty asset", "registered", "refused") }
        err(problem) => {
            r.eq("6a.3 an empty asset is refused, not served",
                 problem.msg,
                 "the asset at \"/empty.css\" is empty; a zero-byte script or stylesheet is a deployment that half-started, and serving it would hide that")
        }
    }
    // ACCEPTED: the real file, at the real path, which every check below uses.
    var real: ClientOptions = new ClientOptions()
    match map_client(app, real) {
        err(problem) => { r.eq("6a.4 the real client file", problem.msg, "registered") }
        ok(_) => { r.yes("6a.4 ACCEPTED: the shipped client at its default path", true) }
    }
    r.eq("6a.5 which is read from", CLIENT_FILE, "js/latte.js")

    let host: espresso.TestHost = new espresso.TestHost(app)

    // --- 6b. the request ---------------------------------------------------
    var tag: string = ""
    var served: int = 0
    match host.get(CLIENT_PATH) {
        err(problem) => { r.eq("6b.1 GET the client", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("6b.1 status", reply.status, 200)
            r.eq("6b.2 content type", header_of(reply, "Content-Type"), CLIENT_TYPE)
            tag = header_of(reply, "ETag")
            served = reply.text().len()
            r.yes("6b.3 the body is the client, not a stub",
                  reply.text().contains("latte.js — the browser half of a latte circuit"))
        }
    }

    // --- 6c. conditional requests -----------------------------------------
    // Four shapes of `If-None-Match`, three of which must be a 304 and one of
    // which must not. The last is the control: a route that answered 304 to
    // anything at all would pass the first three.
    match host.send_with_headers("GET", CLIENT_PATH, one_header("If-None-Match", tag), "") {
        err(problem) => { r.eq("6c.1 the tag itself", "err {problem.msg}", "304") }
        ok(reply) => { r.eqi("6c.1 the tag itself is 304", reply.status, 304) }
    }
    match host.send_with_headers("GET", CLIENT_PATH,
                                 one_header("If-None-Match", "\"0-0\", {tag}"), "") {
        err(problem) => { r.eq("6c.2 a list", "err {problem.msg}", "304") }
        ok(reply) => { r.eqi("6c.2 one member of a list is 304", reply.status, 304) }
    }
    match host.send_with_headers("GET", CLIENT_PATH,
                                 one_header("If-None-Match", "W/{tag}"), "") {
        err(problem) => { r.eq("6c.3 a weak tag", "err {problem.msg}", "304") }
        ok(reply) => { r.eqi("6c.3 a weak tag is 304, which is the comparison this header uses", reply.status, 304) }
    }
    match host.send_with_headers("GET", CLIENT_PATH, one_header("If-None-Match", "*"), "") {
        err(problem) => { r.eq("6c.4 a star", "err {problem.msg}", "304") }
        ok(reply) => { r.eqi("6c.4 '*' is 304 for anything that exists", reply.status, 304) }
    }
    match host.send_with_headers("GET", CLIENT_PATH,
                                 one_header("If-None-Match", "\"0-0\""), "") {
        err(problem) => { r.eq("6c.5 a stale tag", "err {problem.msg}", "200") }
        ok(reply) => {
            r.eqi("6c.5 ACCEPTED: a tag that does not match gets the file", reply.status, 200)
            r.eqi("6c.6 all of it", reply.text().len(), served)
        }
    }

    // --- 6d. methods -------------------------------------------------------
    match host.get(CLIENT_PATH) {
        err(problem) => { r.eq("6d.1 GET", "err {problem.msg}", "200") }
        ok(reply) => { r.eqi("6d.1 ACCEPTED: GET", reply.status, 200) }
    }
    match host.send("HEAD", CLIENT_PATH, "") {
        err(problem) => { r.eq("6d.2 HEAD", "err {problem.msg}", "200") }
        ok(reply) => { r.eqi("6d.2 ACCEPTED: HEAD", reply.status, 200) }
    }
    match host.post(CLIENT_PATH, "") {
        err(problem) => { r.eq("6d.3 POST", "err {problem.msg}", "405") }
        ok(reply) => {
            r.eqi("6d.3 POST is refused", reply.status, 405)
            r.eq("6d.4 and says what it answers", header_of(reply, "Allow"), "GET, HEAD")
        }
    }
    match host.send("DELETE", CLIENT_PATH, "") {
        err(problem) => { r.eq("6d.5 DELETE", "err {problem.msg}", "405") }
        ok(reply) => { r.eqi("6d.5 and so is DELETE", reply.status, 405) }
    }

    // --- 6e. a path this route does not own --------------------------------
    // The middleware must fall through, or an application's own routes stop
    // working the moment it serves a script.
    match host.get("/something-else") {
        err(problem) => { r.eq("6e.1 an unclaimed path", "err {problem.msg}", "404") }
        ok(reply) => {
            r.eqi("6e.1 a path the asset route does not own falls through",
                  reply.status, 404)
        }
    }

    match host.close() {
        ok(_) => {}
        err(problem) => { io.println("FAIL closing the host: {problem.msg}") }
    }
}
