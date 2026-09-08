package main
import std.io

@target(value: ["field"])
@retention(value: "runtime")
annotation once {
    name: string = ""
}

class Thing {
    @once(name: "a") @once(name: "b") pub x: int = 0
    pub fn init() {}
}

fn main() { io.println("compiled") }
