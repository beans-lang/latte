// Generated from examples/board/site/ticket.bx by latte-bx. Do not edit.
//
// The <beans> block below is ticket.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change ticket.bx and regenerate:
//
//     latte-bx build examples/board/site/ticket.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// One order on the board.
//
// Two things worth reading here, and they are the whole point of the file.
//
// **`@memo`.** Re-render this row only when one of its parameters changed. It
// replaces four hand-written lines — a `ParamWatch` field, an `on_params_set`
// that recorded a stringly-typed list of the parameters, and a `should_render`
// that asked it. The list was the problem: written by hand beside the fields it
// mirrors, a parameter left out of it is a parameter whose changes stop
// reaching the screen, and nothing says so. `@memo` reads the `@param` fields
// themselves.
//
// **`@inject`.** `prices` is not a parameter and no ancestor passes it down.
// The container fills it at mount. Before that existed, the only way a row
// could see a shared object was for the page to take it and hand it to every
// component in between — a prop chain for something that is not a prop.
//          

import {inject, memo, param} from latte

@memo
pub partial class Ticket extends Component {
    @param pub drink: string = ""
    @param pub position: int = 0
    @inject pub prices: Prices = new Prices()
    pub fn init() {}

    pub fn price() -> string {
        let pence: int = self.prices.of(self.drink)
        return "£{pence / 100}.{pence % 100}"
    }
}

partial class Ticket {
    pub override fn render(b: Builder) {
        b.open(0, "li")  // ticket.bx:35
        b.attr(1, "class", "flex items-center justify-between gap-4 rounded-lg border border-stone-200 bg-white px-4 py-3")
        b.open(2, "div")  // ticket.bx:36
        b.attr(3, "class", "flex items-center gap-3")
        b.open(4, "span")  // ticket.bx:37
        b.attr(5, "class", "grid h-6 w-6 place-items-center rounded-full bg-stone-100 text-xs font-medium text-stone-600")
        b.text(6, "{self.position}")
        b.close()
        b.open(7, "span")  // ticket.bx:38
        b.attr(8, "class", "text-sm font-medium")
        b.text(9, "{self.drink}")
        b.close()
        b.close()
        b.open(10, "span")  // ticket.bx:40
        b.attr(11, "class", "font-mono text-sm text-stone-500")
        b.text(12, "{self.price()}")
        b.close()
        b.close()
    }
}
