// `shelf.cards` — level 2. It mounts level 3 and it takes CHILD CONTENT.
//
// `body` is the `$slot` of markup: a `fn(Builder)` the caller supplies and
// this component places with `b.fragment`. Here the caller is in another
// module, so the closure renders a consumer's markup into a library
// component's own buffer.
package cards

import {Builder, Component, param} from latte
import {Badge} from shelf.atoms

pub class Card extends Component {
    @param pub title: string = ""
    @param pub count: int = 0
    @param pub body: fn(Builder) = fn(b: Builder) {}
    pub fn init() {}

    /// **A component that takes child content must NOT implement
    /// `should_render`, and this is the one rule a component-library author
    /// has to know.**
    ///
    /// `Badge` below has only scalar parameters, so a `ParamWatch` can compare
    /// them and a card whose parameters are unchanged could safely keep its
    /// frames. `body` is a closure. It cannot be compared, and it closes over
    /// the CALLER's state — here a list living two modules away. A card that
    /// answered `should_render() == false` because its own `title` and `count`
    /// were unchanged would keep the fragment it placed last time, and the
    /// caller's list would silently stop updating: same HTML, no fault, no
    /// error, wrong page.
    ///
    /// The consumer's expected output is what says so. Renaming an item changes neither
    /// the title nor the count, and the renamed row still appears — because
    /// this component renders whenever its parent does.

    pub override fn render(b: Builder) {
        b.open(0, "div")
        b.attr(1, "class", "card")
        b.open(2, "h3")
        b.text(3, self.title)
        b.close()
        b.component<Badge>(4, fn(badge: Badge) {
            badge.label = "{self.count}"
            badge.tone = if self.count == 0 { "empty" } else { "count" }
        })
        b.fragment(5, self.body)
        b.close()
    }
}
