// `shell.b` — the page shell: the document a browser is actually served.
//
// Everything else in this repo renders a page *body*: `Renderer.html()` turns
// a component tree into markup, `PageHost.handle` wraps it in the layout
// chain, `map_pages` writes it into a response. None of that writes
// `<!doctype html>` or a `<script src>` — this file does, and it is the only
// place that does.
//
// It lives at the module root, not `latte.web`, because it does no I/O: it is
// string building, and `beans.pot` keeps the module root free of `std.fs`,
// `std.net` and `std.io` so `test.sh --wasm` holds for every consumer. The
// route that *serves* `js/latte.js` reads a file, so it lives in `latte.web`
// instead (`web/assets.b`).
//
// ## The shell carries no circuit id
//
// `CircuitEndpoint.upgrade` mints a fresh id for every socket — nothing in a
// WebSocket handshake says which circuit a client wants back, and
// `CircuitSet.adopt` exists so a reconnect can arrive on a circuit it did not
// open and name the one it remembers. The id is a server-minted reconnect
// credential, learned by the client from `hello`; printing one into cacheable
// HTML would leak a live credential. So the shell says only *that* the page
// wants a circuit (`data-latte-boot`), where the socket is, and which element
// is the root — the id itself never appears in a page.
//
// `data-latte-circuit` still works, for a host that decides ids itself:
// `ShellOptions.circuit_id` writes it. Nothing in latte needs it.
//
// ## No inline anything
//
// `web/host.b`'s `security_headers` ships `script-src 'self'` with no
// `'unsafe-inline'`, and `tests/w4_headers.b` § 4 greps `js/latte.js` for
// `eval`, `new Function` and `<script`. An inline `<script>`, an inline
// `<style>` or an `on*=` attribute here would be dead under latte's own
// policy. So there is no `head_html` field and no way to pass raw markup into
// the head — stylesheets are a list of hrefs, and that is the whole surface.
// `tests/w9_shell.b` § 5 asserts a rendered shell has none of the three.
package latte

import std.fmt

/// Where `map_client` serves `js/latte.js`, and what the shell points at.
///
/// Under `/_latte/` because that prefix is already the circuit's
/// (`/_latte/ws`) and a deployment only has to keep one path away from its own
/// routes.
pub const CLIENT_PATH: string = "/_latte/latte.js"

/// Where `map_circuit` is registered, and what the client dials.
pub const SOCKET_PATH: string = "/_latte/ws"

/// The element the client mounts into. `latte.js` reads it by id, so it is an
/// id and not a class or a tag.
pub const ROOT_ID: string = "latte-root"

/// The `<script>` attribute that means "this page wants a circuit".
///
/// It is a separate attribute from `data-latte-circuit` and not an empty value
/// of it, because an empty id and a missing id must not be the same thing:
/// `boot` refuses to start on a falsy id, which is what stops a page with no
/// circuit from opening a socket, and that refusal has to keep working.
pub const BOOT_ATTRIBUTE: string = "data-latte-boot";

// ---------------------------------------------------------------- options

/// What a served document is made of.
///
/// Every field that reaches an attribute is checked by `faults()`, and
/// `render_shell` refuses rather than emitting a document it knows is broken.
/// The checks are about the *page*: "a socket path must start with /", not
/// "the emitter cannot do that".
pub class ShellOptions {
    /// `<html lang>`. ASCII letters and hyphens; a screen reader and a
    /// hyphenation engine both read it.
    pub lang: string = "en"
    /// `<title>`, escaped as text. Empty means no `<title>` element at all,
    /// which is honest — an empty title element is worse than none.
    pub title: string = ""
    /// The id of the element the page renders into and the client mounts on.
    pub root_id: string = ROOT_ID
    /// `<script src>`. `'self'` in the shipped CSP is exactly this path.
    pub script: string = CLIENT_PATH
    /// Where the client opens its WebSocket.
    ///
    /// A **path**, not a URL: `latte.js` builds the socket URL as
    /// `scheme + "//" + location.host + path`, so an absolute URL here would
    /// produce `ws://example.com/wss://live.example.com/ws` and a socket that
    /// never opens. A deployment whose socket is on another host needs a
    /// client change and a `connect-src` entry, not a different string here —
    /// so this refuses rather than pretending.
    pub socket: string = SOCKET_PATH
    /// Whether the page opens a circuit. `false` still serves the client
    /// script — enhanced navigation and streamed chunks need it and neither
    /// needs a socket — but writes no boot attribute, so `boot()` answers null.
    pub circuit: bool = true
    /// A circuit id the HOST decided, for a host that has a reason to.
    /// Empty — the default — is the case described in the header.
    pub circuit_id: string = ""
    /// `<link rel=stylesheet href>`, in order. Same-origin paths under the
    /// shipped `style-src 'self'`.
    pub stylesheets: List<string> = []

    pub fn init() {}

    /// Everything wrong with these options, in the words a startup log wants.
    ///
    /// A host calls this once at startup and refuses to listen while it is not
    /// empty; `render_shell` calls it on every render, because a field can be
    /// changed after startup and a shell that silently emitted a broken
    /// document would be found by a browser and not by a log.
    pub fn faults() -> List<string> {
        var out: List<string> = []
        if !is_language_tag(self.lang) {
            out.push("shell: lang \"{self.lang}\" is not a language tag; it reaches <html lang> and must be ASCII letters, digits and hyphens")
        }
        if !is_element_id(self.root_id) {
            out.push("shell: root_id \"{self.root_id}\" is not an element id; latte.js reads it with getElementById and it must start with a letter and hold only letters, digits, '-' and '_'")
        }
        for problem: string in url_faults("script", self.script) { out.push(problem) }
        for problem: string in url_faults("socket", self.socket) { out.push(problem) }
        if !self.socket.starts_with("/") || self.socket.starts_with("//") {
            out.push("shell: socket \"{self.socket}\" must be an absolute path on this origin; latte.js builds the socket URL as scheme + \"//\" + location.host + this, so a URL here dials an address that does not exist")
        }
        var index: int = 0
        for index < self.stylesheets.len() {
            for problem: string in url_faults("stylesheet {index}",
                                              self.stylesheets[index]) {
                out.push(problem)
            }
            index += 1
        }
        if self.circuit_id != "" {
            if !self.circuit {
                out.push("shell: circuit_id is set on a page that says circuit = false; one of the two is a mistake and the shell will not guess which")
            }
            if self.circuit_id.len() < 16 {
                out.push("shell: circuit_id is {self.circuit_id.len()} characters; CircuitSet.open refuses anything under 16, so this page would be served an id no socket can use")
            }
            if !is_token(self.circuit_id) {
                out.push("shell: circuit_id \"{self.circuit_id}\" holds a character that is not a letter, a digit, '-' or '_'")
            }
        }
        return move out
    }
}

// ---------------------------------------------------------------- the render

/// The document, or the first reason it cannot be one.
///
/// `body` is inserted raw: it is what `Renderer.html()` produced, already
/// escaped by the serializer, and escaping it again would show a page its own
/// tags as text.
pub fn render_shell(options: ShellOptions, body: string) -> Result<string, string> {
    let faults: List<string> = options.faults()
    if faults.len() > 0 { return err(faults[0]) }

    var out: fmt.StringBuilder = new fmt.StringBuilder()
    out.push("<!doctype html>\n")
    out.push("<html lang=\"{escape_attribute(options.lang)}\">\n")
    out.push("<head>\n")
    out.push("<meta charset=\"utf-8\">\n")
    out.push("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
    if options.title != "" {
        out.push("<title>{escape_text(options.title)}</title>\n")
    }
    for href: string in options.stylesheets {
        out.push("<link rel=\"stylesheet\" href=\"{escape_attribute(href)}\">\n")
    }
    // The client is deferred and in the head, which is the one placement that
    // is right for both halves of what it does. Deferred, so the 100 KB is
    // being fetched while the document parses and the root element exists by
    // the time it runs — `boot` answers null when it does not, and a shell
    // whose script ran too early would boot nothing with no error. In the
    // head rather than at the end of the body, because the fetch starts
    // sooner and `defer` already guarantees the ordering the body placement
    // was for.
    out.push("<script src=\"{escape_attribute(options.script)}\" defer")
    if options.circuit {
        out.push(" {BOOT_ATTRIBUTE}=\"1\"")
        out.push(" data-latte-ws=\"{escape_attribute(options.socket)}\"")
    }
    if options.circuit_id != "" {
        out.push(" data-latte-circuit=\"{escape_attribute(options.circuit_id)}\"")
    }
    out.push(" data-latte-root=\"{escape_attribute(options.root_id)}\"></script>\n")
    out.push("</head>\n")
    out.push("<body>\n")
    out.push("<div id=\"{escape_attribute(options.root_id)}\">")
    out.push(body)
    out.push("</div>\n")
    out.push("</body>\n")
    out.push("</html>\n")
    return ok(out.to_string())
}

// ---------------------------------------------------------------- the checks

/// ASCII letters, digits and hyphens, at least one character. `en`, `en-GB`,
/// `zh-Hant-TW`.
fn is_language_tag(text: string) -> bool {
    if text.len() == 0 { return false }
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        let letter: bool = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        let digit: bool = byte >= 48 && byte <= 57
        if !letter && !digit && byte != 45 { return false }
    }
    return true
}

/// A letter, then letters, digits, `-` and `_`.
///
/// Narrower than HTML allows on purpose. HTML5 permits any non-whitespace id,
/// but this one is read back by `document.getElementById` and written into a
/// CSS-shaped selector by anyone styling the page, and a leading digit or a
/// `.` in an id is the classic "the selector silently matches nothing".
fn is_element_id(text: string) -> bool {
    if text.len() == 0 { return false }
    let first: int = text.byte_at(0)
    let letter: bool = (first >= 65 && first <= 90) || (first >= 97 && first <= 122)
    if !letter { return false }
    return is_token(text)
}

/// Letters, digits, `-`, `_`.
fn is_token(text: string) -> bool {
    if text.len() == 0 { return false }
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        let letter: bool = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        let digit: bool = byte >= 48 && byte <= 57
        if !letter && !digit && byte != 45 && byte != 95 { return false }
    }
    return true
}

/// What is wrong with a value that reaches an `src` or an `href`.
///
/// Two rules, and both are about what the browser does rather than what looks
/// tidy:
///
///   * **No byte outside printable ASCII, and no `"`, `<`, `>` or `\`.** A
///     quote ends the attribute, an angle bracket ends the tag, whitespace
///     splits the value and a control byte is stripped by some parsers and
///     kept by others. Any of them turns one attribute into two.
///   * **No `javascript:` and no `data:` scheme.** `web/host.b` already
///     refuses `data:` in `img-src` for the SVG-carrying-script reason, and
///     latte's own URL-attribute rule replaces a `javascript:` value with an
///     inert one. A shell that let one in through the back door would be the
///     one place in this repo those two rules do not hold.
///
/// A cross-origin `https://cdn.example/…` is NOT refused: `HeaderOptions`
/// exists so a deployment can name a CDN, and refusing here would make that
/// list a lie.
fn url_faults(what: string, value: string) -> List<string> {
    var out: List<string> = []
    if value == "" {
        out.push("shell: {what} is empty")
        return move out
    }
    var bad: string = ""
    var index: int = 0
    for index < value.len() {
        let byte: int = value.byte_at(index)
        if byte < 33 || byte > 126 {
            bad = "shell: {what} \"{value}\" holds byte {byte} at {index}; whitespace and control bytes split an attribute value in two"
            break
        }
        if byte == 34 || byte == 60 || byte == 62 || byte == 92 {
            bad = "shell: {what} \"{value}\" holds the character {value.slice(index, index + 1)}, which ends the attribute or the tag"
            break
        }
        index += 1
    }
    if bad != "" {
        out.push(bad)
        return move out
    }
    let lowered: string = value.to_lower()
    if lowered.starts_with("javascript:") {
        out.push("shell: {what} \"{value}\" is a javascript: URL")
    }
    if lowered.starts_with("data:") {
        out.push("shell: {what} \"{value}\" is a data: URL; latte refuses those wherever a browser would fetch them")
    }
    return move out
}
