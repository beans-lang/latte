// The wasm leg's negative control. It is never run as a suite (a leading `_`
// is scratch); `test.sh --wasm` asserts that checking THIS file for
// wasm32-unknown-unknown FAILS.
//
// Without it the leg is a dead gate. `tests/_wasm_core.b` passing proves the
// core has no OS-bound import only if the compiler is still refusing one, and
// a gate that would go green after its own mechanism stopped working is a
// failure that looks like a pass. So the leg checks both directions: the core
// must pass, and this must not.
package main

import std.net
import std.fs
import {Builder} from latte

fn main() {
    let b: Builder = new Builder()
    b.open(0, "p")
    b.close()
    let listener: net.Listener = net.listen("127.0.0.1:0")
    listener.close()
    let _: bool = fs.exists("/")
}
