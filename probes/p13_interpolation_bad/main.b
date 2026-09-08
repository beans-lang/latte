// The refused half of p13: type names inside a string interpolation that the
// checker rejects, each with the wrong package composed into the message.
//
// Every one of these is ACCEPTED when the same expression is written outside
// the quotes — the `outside:` line above each — so the refusal is about the
// interpolation, not about the program. `expected.txt` records the exact
// messages; `check_refusals.sh` re-checks them, so the day this starts
// compiling somebody has to read why.
package main

import std.io
import {Widget, Fancy, make, twice, Tone, Shop, apply} from p13_interp_bad.kit

fn main() {
    let w: Widget = new Widget()
    let f: Widget = new Fancy()

    // outside: let made: Widget = new Widget()   — accepted
    io.println("new inside:      {new Widget().button}")

    // outside: let hit: Option<Fancy> = f as? Fancy   — accepted
    io.println("as? inside:      {(f as? Fancy).is_some()}")

    // outside: let n: int = twice<Widget>(w)   — accepted
    io.println("generic inside:  {twice<Widget>(w)}")

    // A cast in the other direction, for completeness.
    io.println("as inside:       {(w as Widget).button}")
}

// Three more positions, added after the first four were recorded, because
// B10 asks which OTHER contexts re-resolve a name late. Two of them are
// ACCEPTED and stay here as the boundary: a name used as a value namespace is
// fine, and only a name used as a TYPE is lost.
fn more() {
    // ACCEPTED — an enum variant path through a named import.
    io.println("enum variant inside: {Tone.loud}")
    // ACCEPTED — a static call on a named-imported class.
    io.println("static call inside:  {Shop.tally()}")
    // REFUSED — a closure PARAMETER TYPE, which is a type annotation and not
    // an expression at all. That is what says the rule is "a type name inside
    // an interpolation" and not "an expression inside an interpolation".
    io.println("closure param type:  {apply(fn(x: Widget) -> int { return x.button })}")
}
