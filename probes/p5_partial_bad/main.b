// The boundary of probe 4: the two ways a generated half of a GENERIC partial
// class is refused. Checked, never run — `probes/check_refusals.sh`.
//
// It matters because it is a rule the markup compiler has to obey silently:
// the generated half of `partial class Grid<T>` may not repeat `<T>`, and
// without repeating it, `T` is not a name that file can write at all.
package main

import std.io
import {Grid, Builder} from p5_partial_bad.pages

fn main() {
    let g: Grid<int> = new Grid<int>()
    io.println("unreachable")
}
