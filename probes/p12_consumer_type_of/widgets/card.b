// The library half: a consumer's OWN package, in a consumer's OWN module,
// building on latte's `Component`. This is the shape every third-party
// component library has.
package widgets

import std.reflect
import {Builder, Component} from latte

pub class Card extends Component {
    pub title: string = ""
    pub fn init() {}
    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "card")
        b.text(2, "{self.title}")
        b.close()
    }
}
