// `web/actions.b` — the route a browser region's typed call arrives on.
//
// It knows nothing about actions. What it does is HTTP: one path prefix, one
// method, a size cap, the two headers that make a cross-origin post
// impossible, and a status for each answer kind. Everything about which
// action, whose authorization and what arguments is decided by
// `latte.run_action`, which this reaches through a closure — the same shape
// `CircuitSeam` uses, and for the same reason: a package under `latte/` may
// not import its own module root.
package web

import github.com/beans-lang/espresso

/// Where every action answers. `latte.ACTION_PREFIX` is the same string;
/// `tests/w9_shell.b` § 1 asserts the pair.
pub const ACTION_PREFIX: string = "/_latte/action/";

/// The header the client puts its antiforgery token in.
///
/// A HEADER and not a form field, and that is the control rather than a
/// convenience: a browser will not let a cross-origin page set a custom
/// header on a request without a CORS preflight this server never answers,
/// so the token is the second lock and the header is the first.
pub const ACTION_TOKEN_HEADER: string = "X-Latte-Action";

/// What the host answered.
pub class ActionAnswer {
    pub status: int = 200
    pub body: string = ""
    pub fn init(status: int, body: string) {
        self.status = status
        self.body = body
    }
}

pub class ActionOptions {
    pub prefix: string = ACTION_PREFIX
    /// The largest call body this route will read. An action's arguments are
    /// a handful of scalars; a megabyte of them is not a call latte made.
    pub max_bytes: int = 65536
    pub fn init() {}
}

/// Route every `POST {prefix}<name>` to `run`.
///
/// `run(name, body, token, session)` answers the reply and its status. It is
/// four strings and an object because this package cannot name an
/// `ActionRequest`, a `Principal` or an `Antiforgery`.
pub fn map_actions(app: espresso.WebApplication, options: ActionOptions,
                   run: fn(string, string, string, string) -> ActionAnswer) -> Result<bool> {
    if !options.prefix.starts_with("/") {
        return err("an action prefix must start with '/': \"{options.prefix}\"",
                   "action")
    }
    let prefix: string = options.prefix
    let cap: int = options.max_bytes
    return app.use(fn(context: espresso.HttpContext,
                      next: fn(espresso.HttpContext) -> Result<bool>) -> Result<bool> {
        let path: string = path_of(context.request.target)
        if !path.starts_with(prefix) { return next(context) }
        let name: string = path.slice(prefix.len(), path.len())

        // POST only, and said with an Allow header rather than a 404: a GET
        // to an action is a link somebody wrote, and a link that silently
        // 404s reads as "the action is gone".
        if context.request.method != "POST" {
            context.response.header("Allow", "POST")
            context.response.text(405, "Method Not Allowed",
                                  "an action is called with POST")
            return ok(true)
        }
        if context.request.body.len() > cap {
            context.response.text(413, "Payload Too Large",
                                  "an action call may not exceed {cap} bytes")
            return ok(true)
        }
        let token: string = context.request.headers.get(ACTION_TOKEN_HEADER).or("")
        // The same cookie the page half reads. An action arrives on a request
        // of its own, so nothing has put a session on it; a call with no
        // cookie carries no session and its token cannot verify, which is the
        // right answer rather than a fresh session minted mid-action.
        let session: string = context.request.cookie(SESSION_COOKIE).or("")
        let answer: ActionAnswer = run(name, context.request.body.to_string(),
                                       token, session)
        context.response.text_body(answer.status, reason_for(answer.status),
                                   answer.body,
                                   "application/json; charset=utf-8")
        return ok(true)
    })
}
