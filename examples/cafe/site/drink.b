// Generated from examples/cafe/site/drink.bx by latte-bx. Do not edit.
//
// The <beans> block below is drink.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change drink.bx and regenerate:
//
//     latte-bx build examples/cafe/site/drink.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// `examples/cafe/site/drink.bx` — one row of the menu, and the component the
// browser smoke clicks.
//
// The event goes OUT as a `Callback<string>` and not a bare `fn(string)`. A
// bare closure would run, change the page's state, and re-render nothing:
// nothing would have told the renderer which component changed. A `Callback`
// marks the component that SUPPLIED it — the page, not this row.
//
// `@memo` skips the RENDER of a row whose parameters did not move. It is not
// what keeps that row off the wire — the differ is, by comparing frames and
// emitting nothing for two that match — and `main.b -- check`'s 4.12 passes
// with or without the memo, which is worth knowing before reading it as
// evidence. `tests/l9_memo.b` counts renders, which is the thing the memo
// actually changes.
//
// It used to be four hand-written lines — a `ParamWatch` field, an
// `on_params_set` that recorded `[self.name, "{self.price}", "{self.chosen}"]`,
// and a `should_render` that asked it. The list was the problem: it is written
// by hand beside the fields it mirrors, and a parameter left out of it is a
// parameter whose changes stop reaching the screen, silently. `@memo` reads the
// `@param` fields themselves.
//
// `on_pick` is not compared, and that is deliberate: this page builds a fresh
// `Callback` every render, so comparing one would make the memo never fire.
//          

import {memo, param} from latte

@memo
pub partial class Drink extends Component {
    @param pub name: string = ""
    @param pub price: int = 0
    @param pub chosen: bool = false
    @param pub on_pick: Option<Callback<string>> = none
    pub fn init() {}

    /// The button's text. A method and not `$self.name — $self.price p`,
    /// because an implicit expression's chain stops at the first character
    /// that cannot continue it — so the `p` of `190p` would have to be its own
    /// text run, with a space in front of it that the page does not want.
    pub fn label() -> string { return "{self.name} — {self.price}p" }

    fn pick() {
        match self.on_pick {
            some(handler) => { handler.call(self.name) }
            none => {}
        }
    }
}

partial class Drink {
    pub override fn render(b: Builder) {
        b.open(0, "li")  // drink.bx:52
        b.attr(1, "class", "{if self.chosen { "drink chosen" } else { "drink" }}")
        b.open(2, "button")  // drink.bx:53
        b.attr(3, "type", "button")
        b.attr(4, "data-drink", "{self.name}")
        b.on_click(5, fn(e: MouseEvent) { self.pick() })
        b.text(6, "{self.label()}")  // drink.bx:55
        b.close()
        b.close()
    }
}
