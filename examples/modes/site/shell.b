// Generated from examples/modes/site/shell.bx by latte-bx. Do not edit.
//
// The <beans> block below is shell.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change shell.bx and regenerate:
//
//     latte-bx build examples/modes/site/shell.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// The layout. It is server-rendered and stays that way: a layout wraps the
// page, so a layout in another mode would put the page inside another
// runtime's region — which latte refuses by name.
//          

import {Layout, layout} from latte

pub partial class Shell extends Layout {
    pub fn init() { super.init() }
}

partial class Shell {
    pub override fn render(b: Builder) {
        b.open(0, "main")  // shell.bx:14
        b.attr(1, "id", "page")
        if b.fold { b.constant(2, "<h1>Render modes</h1>") }  // shell.bx:15
        else {
            b.open(2, "h1")  // shell.bx:15
            b.text(3, "Render modes")
            b.close()
        }
        b.fragment(4, self.body)  // shell.bx:16
        b.close()
    }
}
