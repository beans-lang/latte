// p13, the half that used to be refused — and is not any more.
//
// This was `p13_interpolation_bad/`: type names inside a string interpolation
// that the checker rejected, each with the wrong package composed into the
// message. beans #164 fixed it: a type named inside `"{ }"` is now resolved
// with the file's imports, so every line below compiles and answers
// correctly.
//
// It is kept, and not deleted, because it is the coverage for that fix: seven
// positions in one program. On 0.1.41 both backends print, identically:
//
//     new inside:      7
//     as? inside:      true
//     generic inside:  2
//     as inside:       7
//
// The `outside:` line above each case is the same expression written outside
// the quotes. Both spellings were always meant to agree; now they do.
package main

import std.io
import {Widget, Fancy, make, twice, Tone, Shop, apply} from p13_interp_fixed.kit

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

// Three more positions, added after the first four were recorded, to cover
// other contexts that might re-resolve a name late. Two of them are ACCEPTED
// and stay here as the boundary: a name used as a value namespace is fine,
// and only a name used as a TYPE is lost.
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
