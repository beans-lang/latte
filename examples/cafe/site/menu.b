// Generated from examples/cafe/site/menu.bx by latte-bx. Do not edit.
//
// The <beans> block below is menu.bx's, copied through byte for byte; its
// own package line is blanked so every line after it keeps its number. The
// render method under it is the markup, as Builder calls with fixed
// sequence numbers. Change menu.bx and regenerate:
//
//     latte-bx build examples/cafe/site/menu.bx
package site

import {Builder, Callback, Component, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, Reference, SubmitEvent} from latte


// `examples/cafe/site/menu.bx` — the front page, at `/`.
//
// A `@page` with a `@layout`, a keyed loop, and a child component with a
// callback out. Clicking a drink runs `Menu.pick`, which calls `notify()`;
// the circuit renders this component on the next flush and sends only its
// edits.
//          

import {page, layout} from latte

@page(route: r"/")
@layout(name: "Shell")
pub partial class Menu extends Component {
    pub names: List<string> = ["espresso", "flat white", "cortado"]
    pub prices: List<int> = [190, 320, 280]
    pub picked: string = ""
    pub picks: int = 0
    pub fn init() {}

    /// What the price list says. A method rather than a second parallel index
    /// in the markup, because the loop is over names and a `$for` binds one
    /// element, not a pair.
    pub fn price_of(name: string) -> int {
        var index: int = 0
        for index < self.names.len() {
            if self.names[index] == name { return self.prices[index] }
            index += 1
        }
        return 0
    }

    pub fn summary() -> string {
        if self.picked == "" { return "nothing picked yet" }
        return "picked {self.picked} ({self.picks})"
    }

    /// `notify()` is what marks this component dirty. Without it the state
    /// would change and nothing would re-render — the callback ran, and the
    /// renderer was never told.
    fn pick(name: string) {
        self.picked = name
        self.picks += 1
        self.notify()
    }
}

// Every component tag in menu.bx, checked by beansc rather than by latte-bx:
// a tag whose type is not a Component is a type error naming the type,
// instead of a blank subtree and a fault at run time. Unused, and an
// unused free function is not an error.
fn _latte_component_menu_Drink(value: Drink) -> Component { return value }

partial class Menu {
    pub override fn render(b: Builder) {
        b.open(0, "section")  // menu.bx:48
        b.attr(1, "class", "menu")
        if b.fold { b.constant(2, "<h2>Menu</h2>") }  // menu.bx:49
        else {
            b.open(2, "h2")  // menu.bx:49
            b.text(3, "Menu")
            b.close()
        }
        b.open(4, "ul")  // menu.bx:51
        b.attr(5, "id", "drinks")
        for name: string in self.names {  // menu.bx:52
            b.region(6, "{name}")
            b.component<Drink>(0, fn(_latte_c: Drink) {  // menu.bx:53
                _latte_c.name = name
                _latte_c.price = self.price_of(name)
                _latte_c.chosen = self.picked == name
                _latte_c.on_pick = some(new Callback<string>(self, fn(chosen: string) { self.pick(chosen) }))
            })
            b.end_region()
        }
        b.close()
        b.open(7, "p")  // menu.bx:61
        b.attr(8, "id", "picked")
        b.text(9, "{self.summary()}")
        b.close()
        b.close()
    }
}
