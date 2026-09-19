// The canvas target's surface, as an editor reads it.
//
// The counterpart of `tests/w2_editor_data.b`, which does the same for the
// html target. Two goldens rather than one, because they are two languages an
// editor offers — a page may contain `<!DOCTYPE>` and a screen may contain
// `<Slider>`, and an editor that offered both lists everywhere would be
// suggesting, in every file, mostly things that file cannot hold.
//
// What the golden is *for*: the JSON here and the copy an editor ships have to
// be the same bytes, and a table changed on one side only is a completion list
// that has never heard of a control latte draws.
package main

import std.io
import latte.bx

fn main() {
    io.print(bx.vocabulary_json_for(bx.Target.canvas))
}
