// Generated from examples/board/site/board.bx by latte-bx. Do not edit.
//
// The <beans> block below is board.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change board.bx and regenerate:
//
//     latte-bx build examples/board/site/board.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// The page.
//
// Its `init` takes a service. Nothing on this page constructs an `Orders` and
// nothing passes one in: the container builds the page and resolves what its
// initializer asks for. Before that, a `@page` whose `init` took an argument
// could not be activated at all — and worse, it scanned CLEAN and answered 500
// on every request, because the scan only asked whether an initializer existed
// and not whether it could be called with none.
//
// The state lives in a `BoardModel`, which is an ordinary class with no render
// tree in it. The framework attaches it at mount and owns its `Signal` fields,
// so nothing here writes `own(self)`.
//          

// `live` is a markup attribute, not a name — there is nothing to import for
// it, and the markup below carries it on the element it applies to.
import {layout, page} from latte

@page(route: r"/")
@layout(name: "Shell")
pub partial class Board extends Component {
    pub model: BoardModel

    pub fn init(orders: Orders) {
        self.model = new BoardModel(orders)
    }

    fn add() { self.model.add.run() }

    pub fn button_class() -> string {
        if self.model.ready() {
            return "rounded-lg bg-amber-700 px-4 py-2 text-sm font-medium text-white transition hover:bg-amber-800"
        }
        return "cursor-not-allowed rounded-lg bg-stone-200 px-4 py-2 text-sm font-medium text-stone-400"
    }
}

// Every component tag in board.bx, checked by beansc rather than by latte-bx:
// a tag whose type is not a Component is a type error naming the type,
// instead of a blank subtree and a fault at run time. Unused, and an
// unused free function is not an error.
fn _latte_component_board_Ticket(value: Ticket) -> Component { return value }

partial class Board {
    pub override fn render(b: Builder) {
        b.open(0, "section")  // board.bx:39
        b.attr(1, "class", "space-y-6")
        b.open(2, "div")  // board.bx:41
        b.attr(3, "class", "flex items-baseline justify-between")
        if b.fold { b.constant(4, "<h2 class=\"text-base font-semibold tracking-tight\">Orders</h2>") }  // board.bx:42
        else {
            b.open(4, "h2")  // board.bx:42
            b.attr(5, "class", "text-base font-semibold tracking-tight")
            b.text(6, "Orders")
            b.close()
        }
        b.open(7, "p")  // board.bx:43
        b.attr(8, "class", "text-sm text-stone-500")
        b.open(9, "span")  // board.bx:44
        b.attr(10, "class", "font-mono text-stone-900")
        b.text(11, "{self.model.total()}")
        b.close()
        b.text(12, " on the board, ")
        b.open(13, "span")  // board.bx:45
        b.attr(14, "class", "font-mono text-stone-900")
        b.live_text(15, fn() -> string { return "{self.model.placed.get()}" })
        b.close()
        b.text(16, " placed this session")
        b.close()
        b.close()
        b.open(17, "ul")  // board.bx:49
        b.attr(18, "class", "space-y-2")
        for index: int in 0..self.model.total() {  // board.bx:50
            b.region(19, "{self.model.at(index)}")
            b.component<Ticket>(0, fn(_latte_c: Ticket) {  // board.bx:51
                _latte_c.drink = self.model.at(index)
                _latte_c.position = index + 1
            })
            b.end_region()
        }
        b.close()
        b.open(20, "div")  // board.bx:57
        b.attr(21, "class", "rounded-xl border border-stone-200 bg-white p-4")
        if b.fold { b.constant(22, "<label class=\"block text-sm font-medium text-stone-700\" for=\"drink\">Add an order</label>") }  // board.bx:58
        else {
            b.open(22, "label")  // board.bx:58
            b.attr(23, "class", "block text-sm font-medium text-stone-700")
            b.attr(24, "for", "drink")
            b.text(25, "Add an order")
            b.close()
        }
        b.open(26, "div")  // board.bx:59
        b.attr(27, "class", "mt-2 flex gap-2")
        b.open(28, "input")  // board.bx:60
        b.attr(29, "id", "drink")
        b.attr(30, "class", "flex-1 rounded-lg border border-stone-300 px-3 py-2 text-sm outline-none focus:border-amber-600 focus:ring-2 focus:ring-amber-100")
        b.attr(31, "placeholder", "mocha")
        b.attr(32, "value", "{self.model.draft}")
        b.on_input(33, fn(e: InputEvent) { self.model.draft = e.value })
        b.close()
        b.open(34, "button")  // board.bx:64
        b.attr(35, "type", "button")
        b.attr(36, "class", "{self.button_class()}")
        b.on_click(37, fn(e: MouseEvent) { self.add() })
        b.text(38, "Place")
        b.close()
        b.close()
        if b.fold { b.constant(39, "<p class=\"mt-2 text-xs text-stone-500\">The button is disabled by the command's own guard, which is asked again when it runs — so a click on a stale render cannot place an empty order.</p>") }  // board.bx:68
        else {
            b.open(39, "p")  // board.bx:68
            b.attr(40, "class", "mt-2 text-xs text-stone-500")
            b.text(41, "The button is disabled by the command's own guard, which is asked again when it runs — so a click on a stale render cannot place an empty order.")
            b.close()
        }
        b.close()
        b.close()
    }
}
