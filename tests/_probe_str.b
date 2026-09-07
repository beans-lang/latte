package main
import std.io
class Holder { pub xs: List<int> = []; pub fn init() {} }
fn make() -> List<int> { var a: List<int> = [3,1]; return move a }
fn main() {
    io.println("cmp: {"abc" < "abd"} {"b" > "a"} {"" < "a"}")
    var h: Holder = new Holder()
    h.xs = make()
    io.println("assigned {h.xs}")
    var i: int = 0
    for i < 5 {
        i += 1
        if i == 2 { continue }
        io.println("i={i}")
    }
}
