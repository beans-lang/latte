package main

import std.io

class Hint {
    pub label: string = ""
    pub fn init() {}
}

class Host {
    pub fn init() {}
    // T appears only inside a function-typed parameter — a METHOD.
    pub fn apply<T>(rounds: int, setup: fn(T)) -> int { return rounds }
    pub fn apply_value<T>(item: T, setup: fn(T)) -> int { setup(item); return 2 }
}

// The same two shapes as FREE functions.
fn free_apply<T>(rounds: int, setup: fn(T)) -> int { return rounds }
fn free_apply_value<T>(item: T, setup: fn(T)) -> int { setup(item); return 2 }
fn free_plain<T>(item: T) -> int { return 1 }
// T inside a function-typed parameter, but also as the RESULT.
fn free_result<T>(item: T, setup: fn(T)) -> T { setup(item); return item }

fn main() {
    let host: Host = new Host()
    io.println("method, T only in fn(T):        {host.apply<Hint>(1, fn(x: Hint) { x.label = "a" })}")
    io.println("method, T in a value too:       {host.apply_value<Hint>(new Hint(), fn(x: Hint) { x.label = "b" })}")
    io.println("free,   T only in a value:      {free_plain<Hint>(new Hint())}")
    io.println("free,   T only in fn(T):        {free_apply<Hint>(3, fn(x: Hint) { x.label = "c" })}")
    io.println("free,   T in a value too:       {free_apply_value<Hint>(new Hint(), fn(x: Hint) { x.label = "d" })}")
    io.println("free,   T in the result too:    {free_result<Hint>(new Hint(), fn(x: Hint) { x.label = "e" }).label}")
}
