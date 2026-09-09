// `web/host.b` — the static-rendering half of the espresso seam.
//
// `web.b` carries a circuit over a socket; this file carries a page over one
// ordinary request. Both live under `latte/`, so neither can name `PageMap`,
// `PageHost` or `Signer` — a package cannot import its own module root. What
// crosses the seam is closures over std types; the application's root file,
// which may import both halves, is where they meet.
//
// Two things live only here: the MAC (`hmac_signer` reaches `std.crypto`
// through the networking bridge, which fails `test.sh --wasm` at codegen
// from the module root) and the constant-time compare (`same_bytes` wraps
// espresso's own `constant_time_equal` rather than reimplementing it).
package web

import espresso
import std.crypto
import std.http

// ---------------------------------------------------------------- the signer

/// An HMAC-SHA256 signer over `key`, as the closure `latte.SeamSigner` takes.
///
/// The key is captured once and never crosses the seam: the module root holds
/// a `fn(string) -> string` and has no way to read what signs with it.
///
/// A digest that fails — `std.crypto` answering an error rather than bytes — is
/// returned as `""`, and `""` never equals a genuine MAC, so the request is
/// refused. It is not a panic and it is not a token: a signer that could not
/// sign must not be able to mint something a checker would accept.
pub fn hmac_signer(key: string) -> fn(string) -> string {
    let secret: Bytes = Bytes.from(key)
    return fn(data: string) -> string {
        match crypto.hmac(crypto.Algorithm.sha256, secret, Bytes.from(data)) {
            ok(digest) => { return hex(digest) }
            err(_) => { return "" }
        }
    }
}

/// espresso's constant-time compare, as the closure `latte.SeamSigner` takes.
pub fn same_bytes() -> fn(string, string) -> bool {
    return fn(left: string, right: string) -> bool {
        return espresso.constant_time_equal(left, right)
    }
}

fn hex(raw: Bytes) -> string {
    let digits: string = "0123456789abcdef"
    var out: string = ""
    for index: int in 0..raw.len() {
        let byte: int = raw.get(index)
        out = "{out}{digits.slice(byte / 16, byte / 16 + 1)}{digits.slice(byte % 16, byte % 16 + 1)}"
    }
    return out
}

// ---------------------------------------------------------------- the seam

/// One request, as the page half sees it.
///
/// The body arrives **raw**, not parsed. espresso can parse a urlencoded body
/// and so can the module root, and the root's parser is the one that has to be
/// right: it is what `test.sh --wasm` builds and what the form suite gates. A
/// seam that parsed here would leave the root's parser shipped and ungated.
pub class WebRequest {
    pub method: string = "GET"
    /// The path with no query string, percent-decoding left alone: latte's own
    /// route matcher decodes each captured segment, and decoding here would
    /// let a `%2F` grow a segment before the matcher ever saw it.
    pub path: string = "/"
    pub body: string = ""
    /// The session this client has. Never empty: `map_pages` mints one when the
    /// request carried no cookie.
    pub session: string = ""
    pub fn init() {}
}

/// What the page half answered.
pub class WebReply {
    pub status: int = 200
    pub body: string = ""
    pub content_type: string = "text/html; charset=utf-8"
    /// The `Allow` header's value. Set on a 405 and empty everywhere else.
    pub allow: string = ""
    pub fn init() {}
}

/// The name of the session cookie latte reads and sets.
pub const SESSION_COOKIE: string = "latte_session";

/// Serve latte pages from an espresso application.
///
/// It is middleware and not a route, because latte owns its own route table:
/// `@page` patterns are matched by `PageMap.find`, which knows about
/// specificity and about methods, and copying them into espresso's router would
/// make two tables that can disagree. A request the page half does not answer
/// falls through to `next`, so espresso's own routes still work beside it.
///
/// The session cookie is `HttpOnly`, `SameSite=Lax` and — by default —
/// `Secure`. `secure` is a parameter rather than a constant so a plain-HTTP
/// development server can opt out **in the code that chose it**; a browser
/// silently drops a `Secure` cookie over http, and a framework that guessed
/// would be guessing about the one property that keeps the token honest.
pub fn map_pages(app: espresso.WebApplication,
                 handle: fn(WebRequest) -> Option<WebReply>,
                 secure: bool = true) -> Result<bool> {
    return app.use(fn(context: espresso.HttpContext,
                      next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        var request: WebRequest = new WebRequest()
        request.method = context.request.method
        request.path = path_of(context.request.target)
        request.body = context.request.body.to_string()

        var minted: bool = false
        match context.request.cookie(SESSION_COOKIE) {
            some(value) => { request.session = value }
            none => {
                request.session = fresh_id()?
                minted = true
            }
        }

        // A body latte cannot read is an HTTP-layer answer and is given here.
        // The page half takes a urlencoded body and nothing else; handing it
        // JSON and letting it bind nothing would turn a wrong Content-Type into
        // a form that silently did nothing.
        if request.body.len() > 0 {
            let declared: string = context.request.headers.get("Content-Type").or("")
            if !declared.starts_with("application/x-www-form-urlencoded") {
                context.response.text(415, "Unsupported Media Type",
                    "a latte page reads an application/x-www-form-urlencoded body")
                return ok(true)
            }
        }

        match handle(request) {
            none => { return next(context) }
            some(reply) => {
                if minted {
                    var options: espresso.CookieOptions = new espresso.CookieOptions()
                    options.http_only = true
                    options.secure = secure
                    options.same_site = espresso.SameSite.lax
                    options.path = "/"
                    context.response.set_cookie(SESSION_COOKIE, request.session, options)?
                }
                if reply.allow != "" { context.response.header("Allow", reply.allow) }
                context.response.text_body(reply.status, reason_for(reply.status),
                                           reply.body, reply.content_type)
                return ok(true)
            }
        }
    })
}

/// The target with its query string removed.
fn path_of(target: string) -> string {
    match target.find("?") {
        some(at) => { return target.slice(0, at) }
        none => { return target }
    }
}

// ---------------------------------------------------------------- headers

/// The Content-Security-Policy a latte page can actually run under, and the
/// three headers that go with it.
///
/// **Why latte ships its own and does not reuse espresso's.** espresso's
/// `security_headers` sends `default-src 'none'; frame-ancestors 'none'`
/// (`espresso/security.b:73`). That is right for a JSON API and fatal for a
/// page framework: with no `script-src`, `default-src 'none'` blocks
/// `js/latte.js`, and with no `connect-src` it blocks the WebSocket the client
/// opens and the `XMLHttpRequest` enhanced navigation uses. A deployment that
/// mounted espresso's middleware would serve a page whose client never runs,
/// and the only symptom is a console line nobody on the server ever sees.
///
/// Everything here is a list so a deployment can name a CDN or a separate
/// socket host, and every list starts at `'self'` — the page's own origin —
/// because that is where latte serves its client from and the tightest thing
/// that still works. `default-src` is `'none'`, so a source latte does not name
/// is refused rather than inherited.
///
/// **No `'unsafe-inline'` and no `'unsafe-eval'`, and that is a property of
/// `js/latte.js`, not a wish.** It carries no `eval`, no `new Function` and no
/// inline `<script>`; `tests/w4_headers.b` § 4 greps the shipped file for all
/// three and fails if one appears. A policy that had to be loosened later
/// because the client grew an `eval` would loosen it for every page.
pub class HeaderOptions {
    /// Where `<script src>` may load from. `'self'` is `js/latte.js`.
    pub script: List<string> = ["'self'"]
    /// Where `WebSocket` and `XMLHttpRequest` may go: the circuit and enhanced
    /// navigation. A deployment whose socket is on another host names it here,
    /// **with its scheme** — `wss://live.example.com` — because a browser that
    /// predates CSP3's `'self'` matching does not read `'self'` as covering
    /// `wss:` at all, and the failure is a socket that silently never opens.
    pub connect: List<string> = ["'self'"]
    pub style: List<string> = ["'self'"]
    /// Images. `data:` is deliberately absent: a `data:` image source is also
    /// how an SVG carrying script gets in, and latte's own URL-attribute rule
    /// already replaces a `data:` `src` with an inert value.
    pub image: List<string> = ["'self'"]
    pub font: List<string> = ["'self'"]
    /// Who may frame this page. `'none'` is the clickjacking control, and
    /// `X-Frame-Options: DENY` goes out beside it for browsers that read only
    /// the older header.
    pub frame_ancestors: List<string> = ["'none'"]
    /// Where a `<form>` may post. `'self'` and not `default-src`, because
    /// `form-action` does not fall back to `default-src` in every engine, and a
    /// form framework whose forms could post anywhere is the one place that
    /// matters.
    pub form_action: List<string> = ["'self'"]
    /// `Referrer-Policy`. `no-referrer` is the default because a latte route
    /// carries its parameters in the path.
    pub referrer: string = "no-referrer"

    pub fn init() {}

    /// The policy, in a fixed directive order.
    ///
    /// Fixed because a test asserts this string whole, and a set-iteration
    /// order would make that assertion a photograph of one run.
    pub fn policy() -> string {
        var parts: List<string> = ["default-src 'none'"]
        parts.push("script-src {self.script.join(" ")}")
        parts.push("connect-src {self.connect.join(" ")}")
        parts.push("style-src {self.style.join(" ")}")
        parts.push("img-src {self.image.join(" ")}")
        parts.push("font-src {self.font.join(" ")}")
        parts.push("base-uri 'none'")
        parts.push("form-action {self.form_action.join(" ")}")
        parts.push("frame-ancestors {self.frame_ancestors.join(" ")}")
        return parts.join("; ")
    }
}

/// The middleware. `app.use(security_headers(new HeaderOptions()))`.
///
/// The headers are set **after** `next`, so they land on whatever the pipeline
/// produced — a page, a 404, a 500 — and a handler cannot forget them. A
/// handler that set its own `Content-Security-Policy` deliberately keeps it:
/// `header()` on espresso's response replaces, so this would overwrite it, and
/// the check below is what stops that.
pub fn security_headers(options: HeaderOptions) -> fn(
    espresso.HttpContext, fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
    let policy: string = options.policy()
    let referrer: string = options.referrer
    return fn(context: espresso.HttpContext,
              next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        let result: Result<bool> = next(context)
        if !context.response.headers.has("Content-Security-Policy") {
            context.response.header("Content-Security-Policy", policy)
        }
        context.response.header("X-Content-Type-Options", "nosniff")
        context.response.header("X-Frame-Options", "DENY")
        context.response.header("Referrer-Policy", referrer)
        return result
    }
}

/// The reason phrase for the statuses the page half produces.
///
/// A short table and not a general one: every status latte answers is listed,
/// and anything else says so rather than inventing a phrase, because a made-up
/// reason on an unexpected status is how a wrong status stops looking wrong.
fn reason_for(status: int) -> string {
    if status == 200 { return "OK" }
    if status == 400 { return "Bad Request" }
    if status == 401 { return "Unauthorized" }
    if status == 403 { return "Forbidden" }
    if status == 404 { return "Not Found" }
    if status == 405 { return "Method Not Allowed" }
    if status == 415 { return "Unsupported Media Type" }
    if status == 500 { return "Internal Server Error" }
    return "Status {status}"
}
