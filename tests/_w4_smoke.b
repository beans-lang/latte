package main

import std.io
import {Builder, Component, Renderer, Layout, PageMap, PagePlan, PageMatch, PageInstance,
        Anonymous, scan_pages, open_page, mount_page, page, param, layout, authorize} from latte

pub class Main extends Layout {
    pub fn init() { super.init() }
    pub override fn render(b: Builder) {
        b.open(0, "main")
        b.attr(1, "class", "shell")
        b.fragment(2, self.body)
        b.close()
    }
}

@page(route: r"/counter/{start}")
@layout(name: "Main")
pub class Counter extends Component {
    @param pub start: int = 0
    pub count: int = 0
    pub fn init() {}
    pub override fn on_init() { self.count = self.start }
    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.text(1, "count {self.count}")
        b.close()
    }
}

fn main() {
    let map: PageMap = scan_pages()
    io.println("faults: {map.faults.len()}")
    for fault: string in map.faults { io.println("  {fault}") }
    io.println("pages: {map.pages.len()}")
    for plan: PagePlan in map.pages {
        let methods: string = plan.methods.join(",")
        io.println("  {plan.type_name} route={plan.route.source} methods={methods} layouts={plan.layouts.len()} params={plan.params.len()}")
    }
    match map.find("GET", "/counter/7") {
        some(found) => {
            let start: Option<string> = found.values.get("start")
            io.println("matched {found.plan.name} start={start}")
            let instance: PageInstance = open_page(found, new Anonymous(), none)
            io.println("problems: {instance.problems.len()}")
            for problem: string in instance.problems { io.println("  {problem}") }
            let r: Renderer = new Renderer()
            io.println("mounted: {mount_page(r, instance)}")
            io.println("html: {r.html()}")
            io.println("ids: {r.ids().len()}")
            io.println("faults: {r.all_faults().len()}")
            for fault: string in r.all_faults() { io.println("  {fault}") }
        }
        none => { io.println("no match") }
    }
    match map.find("GET", "/counter/nope") {
        some(found2) => {
            let bad: PageInstance = open_page(found2, new Anonymous(), none)
            io.println("bad problems: {bad.problems.len()}")
            for problem: string in bad.problems { io.println("  {problem}") }
        }
        none => { io.println("no match for /counter/nope") }
    }
}
