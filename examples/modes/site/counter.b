// Generated from examples/modes/site/counter.bx by latte-bx. Do not edit.
//
// The <beans> block below is counter.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change counter.bx and regenerate:
//
//     latte-bx build examples/modes/site/counter.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// ONE counter, used in three modes.
//
// Nothing in this file says where it runs. The page below mounts it three
// times — once inheriting the page's server mode, once with
// `render:mode="client"`, once `auto` — and the same `render` produces all
// three. That is the claim the whole feature rests on: changing the mode
// declaration moves a component between runtimes and changes nothing else.
//          

import {param} from latte

pub partial class Counter extends Component {
    @param pub label: string = "count"
    @param pub start: int = 0
    pub clicks: int = 0

    pub fn total() -> int { return self.start + self.clicks }
}

partial class Counter {
    pub override fn render(b: Builder) {
        b.open(0, "section")  // counter.bx:22
        b.attr(1, "class", "counter")
        b.open(2, "output")  // counter.bx:23
        b.text(3, "{self.label} = {self.total()}")
        b.close()
        b.open(4, "button")  // counter.bx:24
        b.on_click(5, fn(e: MouseEvent) { self.clicks += 1 })
        b.text(6, "add one")
        b.close()
        b.close()
    }
}
