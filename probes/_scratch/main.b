package main

import std.io

class Hint { pub label: string = ""; pub fn init() {} }

class Host {
    pub fn init() {}
    pub fn inst<T>(n: int, setup: fn(T)) -> int { return n }
    pub static fn stat<T>(n: int, setup: fn(T)) -> int { return n }
    pub fn inst_value<T>(item: T) -> int { return 1 }
    pub static fn stat_value<T>(item: T) -> int { return 2 }
}

fn main() {
    let h: Host = new Host()
    io.println("instance, fn(T):  {h.inst<Hint>(1, fn(x: Hint) { x.label = "a" })}")
    io.println("static,   fn(T):  {Host.stat<Hint>(2, fn(x: Hint) { x.label = "b" })}")
    io.println("instance, value:  {h.inst_value<Hint>(new Hint())}")
    io.println("static,   value:  {Host.stat_value<Hint>(new Hint())}")
}
