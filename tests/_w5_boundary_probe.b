package main
import {run} from latte.boundary
import std.io
class Cell { pub n: int = 0; pub fn init() {} }
fn main() {
    let c: Cell = new Cell()
    io.println("clean [{run(fn() -> bool { c.n += 1; return true })}] n={c.n}")
    io.println("panic [{run(fn() -> bool { c.n += 10; panic("boom"); return true })}] n={c.n}")
    io.println("alive [{run(fn() -> bool { c.n += 100; return true })}] n={c.n}")
}
