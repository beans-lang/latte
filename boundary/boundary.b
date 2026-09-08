// `latte.boundary` — the one place latte catches a panic.
//
// `builder.b` already points here: "the frames and the substitution live here;
// the `contained` call that catches the panic lives in `latte.boundary`,
// because `contained` is refused at check time on wasm targets and the core
// must keep building for one (PLAN.md, D4)."
//
// It is a package of its own, importing nothing, for two reasons that are both
// walls rather than taste:
//
//  1. The module root must build for `wasm32-unknown-unknown --runtime
//     freestanding`, and BOTH spellings of containment are refused there —
//     "brew needs fibers" and "contained needs the controlled unwind". So the
//     catch cannot live beside `Builder`.
//  2. A package under `latte/` cannot import the module root, so this package
//     can never name `Builder`, `Component` or `Circuit`. It takes a
//     `fn() -> bool` and answers a string. That is the whole surface, and it
//     is enough: the caller closes over whatever it needs.
//
// **Why `brew` and not `contained`.** They catch the same panic and deliver the
// same message — measured on both backends, `kind` is `panic` either way. But
// `contained` is refused at check time wherever the target has no controlled
// unwind, and that includes Windows/COFF. Spelling it `contained` would mean
// `latte.web` does not COMPILE for Windows, so a latte app with a circuit
// could not be built there at all — and there would be no binary left to
// print the runtime refusal that Windows is owed ("interactive mode needs a
// fiber network poller"). `brew` costs two context switches per event, which
// is noise beside the network round trip that produced the event.
package boundary

/// The fabricated-closure walls `brew` imposes want a call to a user function,
/// so the body is invoked through this rather than brewed directly.
fn invoke(body: fn() -> bool) -> bool { return body() }

/// Run `body` under containment.
///
/// Answers `""` when it returned, or the panic's report — message and source
/// position — when it did not. The caller's frame is untouched either way: the
/// panic unwinds only the child fiber, running its defers newest-first and
/// dropping what it owned, and the failure arrives at `join()`.
///
/// A `cancelled` or `closed` join is reported too, with its own prefix, because
/// silently reading either as success would let a cancelled handler look like
/// one that ran.
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
