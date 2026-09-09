// The core-imports-no-I/O leg. `test.sh --wasm` builds THIS file for
// wasm32-unknown-unknown, and a core that grows an import of std.io, std.fs or
// std.net fails that build — a WebAssembly render mode stays possible only if
// nothing in the core ever depends on an OS capability, and this checks that
// by building rather than by review.
//
// It is a leading-underscore file, so it is scratch to the suite loop and a
// build target to the wasm leg — which is why it prints nothing: there is no
// std.io here, and there cannot be. It self-checks by panicking instead, so
// the code is live and a wasm host that runs it gets a real answer.
package main

import {Builder, Component, MouseEvent, Serializer} from latte

pub class Row extends Component {
    pub label: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "li")
        b.attr(1, "class", "row")
        b.text(2, self.label)
        b.close()
    }
}

pub class Page extends Component {
    pub rows: List<string> = []
    pub clicks: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "ul")
        b.attr(1, "id", "list")
        for row: string in self.rows {
            b.region(2, row)
            b.component<Row>(0, fn(r: Row) { r.label = row })
            b.end_region()
        }
        b.close()
        b.open(3, "button")
        b.on_click(4, fn(e: MouseEvent) { self.clicks += 1 })
        if b.fold { b.constant(5, "<span>Add</span>") }
        else {
            b.open(5, "span")
            b.text(6, "Add")
            b.close()
        }
        b.close()
    }
}

fn main() {
    let page: Page = new Page()
    page.rows.push("a")
    page.rows.push("b")
    page.rows.push("c")

    let b: Builder = new Builder()
    b.render_root(page)

    let writer: Serializer = new Serializer()
    let html: string = writer.page(b)
    let want: string = "<ul id=\"list\"><li class=\"row\">a</li><li class=\"row\">b</li><li class=\"row\">c</li></ul><button><span>Add</span></button>"
    if html != want { panic("the wasm core self-check produced {html}") }
    if !b.balanced() { panic("the wasm core self-check left frames unbalanced") }
    if b.children.len() != 3 { panic("the wasm core self-check mounted the wrong count") }
    if b.registry.mouse.len() != 1 { panic("the wasm core self-check bound the wrong handler count") }
}
