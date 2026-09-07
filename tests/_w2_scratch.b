package main
import std.io
import std.fs
import latte.bx

fn show(name: string) {
    io.println("--- {name} ---")
    match fs.read("tests/w2cases/{name}.bx") {
        ok(source) => {
            let doc: bx.Document = bx.parse_document(source)
            io.print(doc.show())
            if !doc.is_ok() { io.println(doc.report()) }
        }
        err(problem) => { io.println("cannot read: {problem.msg}") }
    }
}

fn main() {
    show("simple")
    show("price")
    show("expr")
    show("blocks")
    show("beans")
}
