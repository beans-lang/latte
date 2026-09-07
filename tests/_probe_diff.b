package main

import std.io
import {Applier, Batch, Builder, Component, Differ, MouseEvent, Serializer} from latte

pub class Row extends Component {
    pub label: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.attr(1, "class", "row")
        b.text(2, self.label)
        b.close()
    }
}

pub class Table extends Component {
    pub rows: List<string> = []
    pub title: string = "t"
    pub show: bool = true
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "id", "root")
        b.attr(2, "data-title", self.title)
        b.text(3, self.title)
        if self.show {
            b.open(4, "ul")
            for id: string in self.rows {
                b.region(0, id)
                b.open(0, "li")
                b.attr(1, "data-key", id)
                b.on_click(2, fn(e: MouseEvent) {})
                b.component<Row>(3, fn(r: Row) { r.label = id })
                b.close()
                b.end_region()
            }
            b.close()
        } else {
            b.text(10, "hidden")
        }
        b.close()
    }
}

fn step(name: string, b: Builder, t: Table, a: Applier) {
    b.render_root(t)
    let d: Differ = new Differ()
    let batch: Batch = d.batch(b)
    a.apply(batch)
    let writer: Serializer = new Serializer()
    let want: string = writer.page(b)
    let got: string = a.html()
    io.println("-- {name}: {batch.edit_count()} edit(s)")
    io.println(batch.dump())
    io.println("   want {want}")
    io.println("   got  {got}")
    io.println("   MATCH={got == want} differ_faults={d.faults.len()} applier_faults={a.faults.len()}")
    for f: string in a.faults { io.println("   applier: {f}") }
    a.faults.clear()
}

fn main() {
    let t: Table = new Table()
    t.rows = ["a", "b", "c", "d", "e"]
    let b: Builder = new Builder()
    let a: Applier = new Applier()
    step("first render", b, t, a)
    step("no change", b, t, a)
    t.title = "changed"
    step("title", b, t, a)
    t.rows = ["a", "b", "c", "d", "e", "f"]
    step("append f", b, t, a)
    t.rows = ["z", "a", "b", "c", "d", "e", "f"]
    step("prepend z", b, t, a)
    t.rows = ["a", "b", "c", "d", "e", "f", "z"]
    step("rotate left", b, t, a)
    t.rows = ["f", "e", "d", "c", "b", "a"]
    step("reverse minus z", b, t, a)
    t.show = false
    step("branch flip", b, t, a)
    t.show = true
    step("branch back", b, t, a)
}
