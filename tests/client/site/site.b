// The components this bundle can run. One server, one browser, one static —
// the three modes over one component model.
package site

import {Builder, Component, MouseEvent, InputEvent, param, render_mode} from latte

/// A counter that runs in the browser. Nothing about it says so: the mode is
/// a declaration beside the class, and the same class renders on the server
/// when a page asks it to.
@render_mode(value: "client")
pub class Counter extends Component {
    @param pub start: int = 0
    @param pub label: string = "count"
    pub clicks: int = 0
    pub note: string = ""
    pub fn init() {}

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "counter")
        b.open(2, "output")
        b.attr(3, "id", "value")
        b.text(4, "{self.label}={self.start + self.clicks}")
        b.close()
        b.open(5, "button")
        b.attr(6, "id", "add")
        b.on_click(7, fn(e: MouseEvent) { self.clicks += 1 })
        b.text(8, "+1")
        b.close()
        b.open(9, "input")
        b.attr(10, "id", "note")
        b.attr(11, "value", self.note)
        b.on_input(12, fn(e: InputEvent) { self.note = e.value })
        b.close()
        b.open(13, "p")
        b.attr(14, "id", "echo")
        b.text(15, self.note)
        b.close()
        b.close()
    }
}
