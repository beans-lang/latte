package main
import std.io
import {RoutePattern, RouteSegment} from latte

fn main() {
    let p: RoutePattern = new RoutePattern(r"/counter/{start}")
    io.println("faults {p.faults.len()}")
    for f: string in p.faults { io.println("  {f}") }
    io.println("segments {p.segments.len()}")
    for s: RouteSegment in p.segments { io.println("  text=\"{s.text}\" name=\"{s.name}\" param={s.is_parameter}") }
    io.println("shape {p.shape()}")
    match p.matches("/counter/7") {
        some(v) => { io.println("matched, values {v.len()}") }
        none => { io.println("NO MATCH") }
    }
    let root: RoutePattern = new RoutePattern("/")
    io.println("root segments {root.segments.len()} faults {root.faults.len()}")
    for f: string in root.faults { io.println("  {f}") }
    match root.matches("/") { some(_) => { io.println("root matched") } none => { io.println("root NO MATCH") } }
}
