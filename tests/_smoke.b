// Scratch driver — not a gated suite (a leading `_` is scratch, see test.sh).
package main

import std.io
import {Builder, Component, MouseEvent} from latte

pub class Hint extends Component {
    pub label: string = ""
    pub seen: int = 0
    pub fn init() {}
    pub override fn on_init() { self.seen = 100 }
    pub override fn render(b: Builder) {
        b.open(0, "aside")
        b.attr(1, "class", "hint")
        b.text(2, "{self.label}/{self.seen}")
        b.close()
    }
}

pub class Page extends Component {
    pub rows: List<string> = []
    pub clicks: int = 0
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "ul")
        for row: string in self.rows {
            b.region(1, row)
            b.open(0, "li")
            b.on_click(1, fn(e: MouseEvent) { self.clicks += 1 })
            b.component<Hint>(2, fn(h: Hint) { h.label = row; h.seen += 1 })
            b.close()
            b.end_region()
        }
        b.close()
    }
}

fn main() {
    let page: Page = new Page()
    page.rows.push("a")
    page.rows.push("b")
    page.rows.push("c")
    page.rows.push("d")
    page.rows.push("e")

    let b: Builder = new Builder()
    b.render_root(page)
    io.println("balanced: {b.balanced()}")
    io.println("children: {b.children.len()}")
    io.println("faults: {b.all_faults().len()}")
    for fault: string in b.all_faults() { io.println("  {fault}") }
    io.println("--- render 2, reordered ---")
    let moved: string = page.rows.remove(0)
    page.rows.push(moved)
    b.render_root(page)
    io.println("children after reorder: {b.children.len()}")
    io.println("faults: {b.all_faults().len()}")
    io.println(b.dump_tree())
    io.println("--- render 3, one row dropped ---")
    let _: string = page.rows.remove(0)
    b.render_root(page)
    io.println("children after drop: {b.children.len()} nested {b.nested.len()}")
    io.println("mouse handlers left: {b.registry.mouse.len()}")
}
