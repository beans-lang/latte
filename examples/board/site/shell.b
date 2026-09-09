// Generated from examples/board/site/shell.bx by latte-bx. Do not edit.
//
// The <beans> block below is shell.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change shell.bx and regenerate:
//
//     latte-bx build examples/board/site/shell.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// The layout every page is wrapped in — the chrome, and nothing that belongs
// to a page.
//
// It writes no `<html>`, no `<head>` and no `<script>`: those belong to the
// shell DOCUMENT, which is not a component. This markup is what a circuit
// re-renders over a socket, and a circuit that re-rendered `<html>` would be
// replacing the page the script driving it is running inside.
//          

import {Layout} from latte

pub partial class Shell extends Layout {
    pub fn init() { super.init() }
}

partial class Shell {
    pub override fn render(b: Builder) {
        b.open(0, "div")  // shell.bx:17
        b.attr(1, "class", "min-h-screen bg-stone-50 text-stone-900")
        if b.fold { b.constant(2, "<header class=\"border-b border-stone-200 bg-white\"><div class=\"mx-auto flex max-w-3xl items-center gap-3 px-6 py-4\"><span class=\"grid h-9 w-9 place-items-center rounded-full bg-amber-700 text-sm font-semibold text-white\">BB</span><div><h1 class=\"text-lg font-semibold leading-tight tracking-tight\">Brew Board</h1><p class=\"text-xs text-stone-500\">a latte demo — DI, a view-model, signals and a memo</p></div></div></header>") }  // shell.bx:18
        else {
            b.open(2, "header")  // shell.bx:18
            b.attr(3, "class", "border-b border-stone-200 bg-white")
            b.open(4, "div")  // shell.bx:19
            b.attr(5, "class", "mx-auto flex max-w-3xl items-center gap-3 px-6 py-4")
            b.open(6, "span")  // shell.bx:20
            b.attr(7, "class", "grid h-9 w-9 place-items-center rounded-full bg-amber-700 text-sm font-semibold text-white")
            b.text(8, "BB")
            b.close()
            b.open(9, "div")  // shell.bx:21
            b.open(10, "h1")  // shell.bx:22
            b.attr(11, "class", "text-lg font-semibold leading-tight tracking-tight")
            b.text(12, "Brew Board")
            b.close()
            b.open(13, "p")  // shell.bx:23
            b.attr(14, "class", "text-xs text-stone-500")
            b.text(15, "a latte demo — DI, a view-model, signals and a memo")
            b.close()
            b.close()
            b.close()
            b.close()
        }
        b.open(16, "main")  // shell.bx:27
        b.attr(17, "class", "mx-auto max-w-3xl px-6 py-8")
        b.fragment(18, self.body)
        b.close()
        b.close()
    }
}
