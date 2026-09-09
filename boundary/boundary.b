// `latte.boundary` — the only place in latte that catches a panic.
//
// A package on its own, importing nothing: the module root must build for
// `wasm32-unknown-unknown --runtime freestanding`, where the catching call
// does not work, so it cannot live beside `Builder`; and code under `latte/`
// cannot import the module root, so this package never names `Builder`,
// `Component` or `Circuit` — it takes a `fn() -> bool` and returns a string,
// and the caller closes over whatever state it needs.
package boundary

/// `brew` needs a named function to call, not a closure value, so the body
/// is invoked through this rather than brewed directly.
fn invoke(body: fn() -> bool) -> bool { return body() }

/// Runs `body` under containment.
///
/// Returns `""` when it returned normally, or the panic's report — message
/// and source position — when it panicked. The caller's frame is untouched
/// either way: the panic unwinds only the child fiber, running its defers
/// newest-first and dropping what it owned, and the failure surfaces at
/// `join()`.
///
/// A `cancelled` or `closed` join is reported too, with its own prefix, so a
/// cancelled handler is never mistaken for one that ran.
///
/// Uses `brew`, not `contained`: `contained` is refused at check time on
/// targets with no controlled unwind (wasm, Windows/COFF), which would stop
/// `latte.web` from compiling there at all.
pub fn run(body: fn() -> bool) -> string {
    let child: Brew<bool> = brew invoke(body)
    match child.join() {
        ok(value) => { return "" }
        err(problem) => {
            if problem.kind == "panic" { return problem.msg }
            return "{problem.kind}: {problem.msg}"
        }
    }
}
