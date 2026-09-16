// `web/assets.b` — the route that serves `js/latte.js`.
//
// `security_headers` sends `script-src 'self'`, so something has to be
// servable from `'self'`; this is that route. It lives in `latte.web`, not
// the module root, because it reads a file and the module root stays I/O
// free so `test.sh --wasm` holds for every consumer. `shell.b`, at the
// module root, only points at this route's path — it does no I/O itself.
//
// ## Middleware, not a route
//
// latte owns every path under `/_latte/`; registering `map_client` and
// `map_asset` as espresso middleware, rather than router entries, keeps that
// ownership in one place. A request that does not match falls through to
// `next`, so an application's own routes still work beside it.
//
// ## The file is read once, at registration
//
// Not per request: that would add a `stat` and a 108 KB read to every page
// load, and would let a deployment started in the wrong directory serve
// 500s that look like a browser problem instead of failing at startup. See
// `map_client` for what a failed or empty read does.
package web

import github.com/beans-lang/espresso
import std.fs

/// Where `map_client` serves the client, and what `shell.b` points at.
///
/// `latte.CLIENT_PATH` is the same string, spelled twice because a package
/// under `latte/` may not import its own module root — the same reason
/// `web.b`'s `WAKE_PUSH`/`WAKE_TICK`/`WAKE_GONE`/`WAKE_MESSAGE` duplicate
/// `latte`'s. `tests/w9_shell.b` § 1 asserts the two paths are equal, so
/// drift is a failing test rather than a page whose script 404s.
pub const CLIENT_PATH: string = "/_latte/latte.js";

/// The path `map_circuit` is normally registered on. `latte.SOCKET_PATH` is
/// the same string, and the same test asserts it.
pub const SOCKET_PATH: string = "/_latte/ws";

/// The default place the client script is read from, relative to the process's
/// working directory.
pub const CLIENT_FILE: string = "js/latte.js";

/// The `Content-Type` the client is served with.
///
/// `text/javascript` and not `application/javascript`: it is the one the HTML
/// specification calls the standard JavaScript MIME type, and it is what
/// `X-Content-Type-Options: nosniff` — which `security_headers` always sends —
/// requires a `<script>` to have been served with. Under `nosniff`, a script
/// with the wrong type is refused by the browser and the page's every event
/// silently does nothing.
pub const CLIENT_TYPE: string = "text/javascript; charset=utf-8";

// ---------------------------------------------------------------- options

pub class ClientOptions {
    /// Where the script is served.
    pub path: string = CLIENT_PATH
    /// Where the script is read from, at registration.
    pub file: string = CLIENT_FILE
    /// `Cache-Control`.
    ///
    /// `no-cache` means "keep it, and revalidate before using it" — not "do
    /// not store it". With the `ETag` below, a reload costs a conditional
    /// request and a 304 rather than 108 KB. A `max-age` would be wrong: the
    /// path carries no content hash, so a cached copy of an older client would
    /// keep talking to a newer server for as long as the age said.
    pub cache_control: string = "no-cache"
    pub fn init() {}
}

// ---------------------------------------------------------------- the routes

/// Serves the latte client script.
///
/// Reads `options.file` once, at registration, and refuses — before the
/// application ever listens — if the read fails or the file is empty. There
/// is no fallback to an empty script: a zero-byte client is a page whose
/// every button silently does nothing.
///
/// `options.file` is resolved against the process's working directory, so a
/// deployment must run from the directory that holds `js/latte.js`, or set
/// `ClientOptions.file`. The client is not embedded into the package; the
/// generator and `test.sh` leg that would regenerate and diff an embedded
/// copy — the way `examples/markup` already does for `counter.bx` — has not
/// been built, so a wrong working directory fails loudly at startup instead
/// of serving a stale file.
pub fn map_client(app: espresso.WebApplication,
                  options: ClientOptions) -> Result<bool> {
    var source: string = ""
    match fs.read(options.file) {
        ok(text) => { source = text }
        err(problem) => {
            return err("latte cannot read its client script at \"{options.file}\" ({problem.kind}); the path is relative to the process's working directory, or set ClientOptions.file",
                       "client")
        }
    }
    return map_asset(app, options.path, source, CLIENT_TYPE,
                     options.cache_control)
}

/// Serve one in-memory body at one exact path.
///
/// `body` is a `string` and not `Bytes` because everything latte serves this
/// way is text — the client script, a stylesheet — and espresso's `text_body`
/// holds a string by reference rather than copying it into a per-connection
/// buffer. A binary asset belongs to an application's own route.
pub fn map_asset(app: espresso.WebApplication, path: string, body: string,
                 content_type: string, cache_control: string) -> Result<bool> {
    if !path.starts_with("/") {
        return err("an asset path must start with '/': \"{path}\"", "asset")
    }
    if body.len() == 0 {
        return err("the asset at \"{path}\" is empty; a zero-byte script or stylesheet is a deployment that half-started, and serving it would hide that",
                   "asset")
    }
    let tag: string = entity_tag(body)
    let served: string = body
    let mime: string = content_type
    let cache: string = cache_control
    let want: string = path
    return app.use(fn(context: espresso.HttpContext,
                      next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        if path_of(context.request.target) != want { return next(context) }

        let method: string = context.request.method
        if method != "GET" && method != "HEAD" {
            context.response.header("Allow", "GET, HEAD")
            context.response.text(405, "Method Not Allowed",
                                  "this path serves a static asset")
            return ok(true)
        }
        // espresso's router sets this for a HEAD it matched; this is
        // middleware and the router never saw the request, so it is set here.
        // Without it a HEAD is answered with the whole 108 KB body under a
        // correct Content-Length, which is exactly the bug a HEAD exists to
        // avoid.
        context.head_only = method == "HEAD"

        context.response.header("ETag", tag)
        context.response.header("Cache-Control", cache)
        match context.request.headers.get("If-None-Match") {
            some(offered) => {
                if if_none_match(offered, tag) {
                    // No content type: a 304 carries no body, and
                    // `std.http`'s head encoder already omits Content-Length
                    // for a body-forbidden status.
                    context.response.text_body(304, "Not Modified", "", "")
                    return ok(true)
                }
            }
            none => {}
        }
        context.response.text_body(200, "OK", served, mime)
        return ok(true)
    })
}

// ---------------------------------------------------------------- the tag

/// A strong entity tag over the body: its length and a 32-bit FNV-1a of it.
///
/// **Not a cryptographic digest, and it does not need to be.** An ETag decides
/// whether a cache may reuse bytes it already has; it authenticates nothing.
/// What it must be is *different* whenever the bytes are different, which is
/// what the length in front of the hash buys: two bodies collide only if they
/// are the same length AND hash the same, and the change this has to catch is
/// an edit to `js/latte.js`, not an adversary choosing one.
///
/// Length-first also means the common accident — a file truncated by a failed
/// copy — changes the tag even if the hash were to collide.
fn entity_tag(body: string) -> string {
    var hash: int = 2166136261
    var index: int = 0
    let size: int = body.len()
    for index < size {
        // `^` on the byte, then the FNV prime, kept inside 32 bits with `%`.
        // The product of a 32-bit value and 16777619 is under 2^56, so it
        // never leaves the range an `int` holds exactly.
        hash = (hash ^ body.byte_at(index)) % 4294967296
        hash = (hash * 16777619) % 4294967296
        index += 1
    }
    return "\"{size}-{hash}\""
}

/// Whether an `If-None-Match` header matches the tag we would send.
///
/// `*` matches anything that exists, which is what the specification says and
/// what a client uses to mean "any copy at all". Otherwise the header is a
/// comma-separated list and one member has to be equal. A `W/` prefix is
/// stripped before comparing, because the comparison an `If-None-Match` uses
/// is the weak one — an entity tag that differs only in weakness is still the
/// same representation for cache purposes.
fn if_none_match(offered: string, tag: string) -> bool {
    if offered.trim() == "*" { return true }
    for piece: string in offered.split(",") {
        var candidate: string = piece.trim()
        if candidate.starts_with("W/") {
            candidate = candidate.slice(2, candidate.len())
        }
        if candidate == tag { return true }
    }
    return false
}
