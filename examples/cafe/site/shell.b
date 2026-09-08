// Generated from examples/cafe/site/shell.bx by latte-bx. Do not edit.
//
// The <beans> block below is shell.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change shell.bx and regenerate:
//
//     latte-bx build examples/cafe/site/shell.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// `examples/cafe/site/shell.bx` — the layout every page is wrapped in.
//
// A `Layout` is an ordinary component whose `body` is placed with `$slot`;
// `open_page` wires `body` to the next link in the chain. Everything the two
// pages share lives here, so a page renders only what is its own.
//
// It writes no `<html>`, no `<head>` and no `<script>`. Those belong to the
// **shell document** (`latte.render_shell`), which is not a component: this
// markup is what the circuit re-renders over a socket, and a circuit that
// re-rendered `<html>` would be replacing the page the script driving it is
// running inside.
//          

import {Layout} from latte

pub partial class Shell extends Layout {
    pub fn init() { super.init() }
}

partial class Shell {
    pub override fn render(b: Builder) {
        b.open(0, "div")  // shell.bx:21
        b.attr(1, "class", "page")
        if b.fold { b.constant(2, "<header><h1>The Cafe</h1><nav><a href=\"/\">menu</a><a href=\"/order/4\">order for table 4</a></nav></header>") }  // shell.bx:22
        else {
            b.open(2, "header")  // shell.bx:22
            b.open(3, "h1")  // shell.bx:23
            b.text(4, "The Cafe")
            b.close()
            b.open(5, "nav")  // shell.bx:24
            b.open(6, "a")  // shell.bx:25
            b.attr(7, "href", "/")
            b.text(8, "menu")
            b.close()
            b.open(9, "a")  // shell.bx:26
            b.attr(10, "href", "/order/4")
            b.text(11, "order for table 4")
            b.close()
            b.close()
            b.close()
        }
        b.open(12, "main")  // shell.bx:29
        b.fragment(13, self.body)
        b.close()
        b.close()
    }
}
