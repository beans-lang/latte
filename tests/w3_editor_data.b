// The canvas target's surface as an editor reads it, beside
// `tests/w2_editor_data.b`. Two expected outputs: they are two languages, not one.
package main

import std.io
import latte.bx

fn main() {
    io.print(bx.vocabulary_json_for(bx.Target.canvas))
}
