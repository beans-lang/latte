// The wall found while building probe 3: the checker used to accept a
// generic call the native emitter refused. Fixed in beans 0.1.41 (#161) —
// every shape below now builds natively too. Kept as the probe that caught
// it and still exercises every shape.
//
// `beansc check` says ok. `beansc run` prints every line. `beansc build`
// used to refuse three of the six calls with a message about the LLVM
// emitter; it now builds all six.
//
//   cd beans
//   ./build/beansc check ../<worktree>/probes/p3_emitter_wall/main.b   # ok
//   ./build/beansc run   ../<worktree>/probes/p3_emitter_wall/main.b   # eight lines
//   ./build/beansc build ../<worktree>/probes/p3_emitter_wall/main.b -o /tmp/x  # ok
//
// The split WAS exact: a generic INSTANCE METHOD whose type parameter appears
// inside a function-typed parameter always emitted. The same shape as a FREE
// FUNCTION or as a STATIC METHOD did not — with or without an explicit type
// argument, with or without `T` also appearing as a value parameter or as the
// result. A generic static whose `T` appears only as a plain value parameter
// always emitted fine, so the function-typed parameter was the trigger and
// the receiver decided whether it survived.
package main

import std.io

class Hint {
    pub label: string = ""
    pub fn init() {}
}

class Host {
    pub fn init() {}
    pub fn apply<T>(rounds: int, setup: fn(T)) -> int { return rounds }
    pub fn apply_value<T>(item: T, setup: fn(T)) -> int { setup(item); return 2 }
    pub static fn stat_apply<T>(rounds: int, setup: fn(T)) -> int { return rounds }
    pub static fn stat_value<T>(item: T) -> int { return 3 }
}

fn free_plain<T>(item: T) -> int { return 1 }
fn free_apply<T>(rounds: int, setup: fn(T)) -> int { return rounds }
fn free_apply_value<T>(item: T, setup: fn(T)) -> int { setup(item); return 2 }
fn free_result<T>(item: T, setup: fn(T)) -> T { setup(item); return item }

fn main() {
    let host: Host = new Host()
    // These two emit.
    io.println("method, T only in fn(T):     {host.apply<Hint>(1, fn(x: Hint) { x.label = "a" })}")
    io.println("method, T in a value too:    {host.apply_value<Hint>(new Hint(), fn(x: Hint) { x.label = "b" })}")
    // These two emit: no function-typed parameter anywhere.
    io.println("free,   T only in a value:   {free_plain<Hint>(new Hint())}")
    io.println("static, T only in a value:   {Host.stat_value<Hint>(new Hint())}")
    // These three do not.
    io.println("free,   T only in fn(T):     {free_apply<Hint>(3, fn(x: Hint) { x.label = "c" })}")
    io.println("free,   T in a value too:    {free_apply_value<Hint>(new Hint(), fn(x: Hint) { x.label = "d" })}")
    io.println("free,   T in the result too: {free_result<Hint>(new Hint(), fn(x: Hint) { x.label = "e" }).label}")
    io.println("static, T only in fn(T):     {Host.stat_apply<Hint>(6, fn(x: Hint) { x.label = "f" })}")
}
