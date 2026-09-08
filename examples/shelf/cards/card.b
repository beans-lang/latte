// `shelf.cards` — level 2. It mounts level 3 and it takes CHILD CONTENT.
//
// `body` is the `$slot` of markup: a `fn(Builder)` the caller supplies and
// this component places with `b.fragment`. Here the caller is in another
// module, so the closure renders a consumer's markup into a library
// component's own buffer.
package cards

import {Builder, Component, ParamWatch, param} from latte
import {Badge} from shelf.atoms

pub class Card extends Component {
    @param pub title: string = ""
    @param pub count: int = 0
    @param pub body: fn(Builder) = fn(b: Builder) {}
    watch: ParamWatch = new ParamWatch()
    pub fn init() {}

    /// `body` is a closure and cannot be compared, so it is deliberately not
    /// in the snapshot: a card whose title and count are unchanged keeps its
    /// frames even though its parent handed it a fresh closure every pass.
    /// That is what makes the render counts in the consumer's golden small,
    /// and it is only safe because a kept card also keeps the fragment it
    /// already placed.
    pub override fn on_params_set() { self.watch.record([self.title, "{self.count}"]) }
    pub override fn should_render() -> bool { return self.watch.differs() }

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
