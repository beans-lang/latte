// w2_editor_data.b — latte's `.bx` vocabulary, printed as JSON.
//
// The suite IS the file. Its expected output, `tests/w2_editor_data.out`, is the JSON
// byte for byte, so `editors/shared/bx.json` is a copy of the expected output and
// nothing hand-writes it:
//
//     cp tests/w2_editor_data.out ../../editors/shared/bx.json
//     build/latte-bx vocabulary          # the same string, for a person
//
// This is the shape crema used — `tests/_bx_editor_data.b` printing straight
// out of bx's own tables — with one difference that matters. crema's was a
// scratch file the check never ran, so nothing said the JSON still described
// the compiler. This one is a suite: `test.sh` runs it on both backends and
// diffs the expected output, and `tests/markup.b` §1b asks `html.b`'s predicates about
// every name in it and about a corpus of names that must not be in it. A table
// that grows a row fails both, and a vocabulary that drifts from the compiler
// is a lie the drift check would otherwise be green about.
package main

import std.io
import latte.bx

fn main() {
    io.print(bx.vocabulary_json())
}
