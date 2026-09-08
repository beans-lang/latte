// `shelf` — the module root, and the surface a consumer imports.
//
//     import {Panel} from shelf
//
// A three-level component: `Panel` mounts `shelf.cards.Card`, which mounts
// `shelf.atoms.Badge`. Three packages of one library module, on top of a base
// class from a fourth package in another module entirely.
//
// This file is what PLAN.md's gate 5 means by "a three-level library component
// used from another package", and `examples/shop` is the other package.
package shelf

import {Builder, Callback, Component, MouseEvent, ParamWatch, param} from latte
import {Card} from shelf.cards

pub const VERSION: string = "1.0.0"

pub class Panel extends Component {
    @param pub heading: string = ""
    @param pub items: List<string> = []
    /// The event out. A `Callback` and not a bare `fn(string)`: a bare closure
    /// would run the consumer's code and re-render nothing, because nothing
    /// told the renderer which component changed. The callback marks the
    /// component that SUPPLIED it — which here lives in another module.
    @param pub on_pick: Option<Callback<string>> = none
    watch: ParamWatch = new ParamWatch()
    pub fn init() {}

    pub override fn on_params_set() {
        self.watch.record([self.heading, self.items.join("\u{1f}")])
    }
    pub override fn should_render() -> bool { return self.watch.differs() }

    pub override fn render(b: Builder) {
        b.open(0, "section")
        b.attr(1, "class", "panel")
        b.component<Card>(2, fn(card: Card) {
            card.title = self.heading
            card.count = self.items.len()
            card.body = fn(inner: Builder) { self.rows(inner) }
        })
        b.close()
    }

    /// The child content this panel hands DOWN to the card, which the card
    /// places with `b.fragment`. A `$for` is a region: the body restarts
    /// sequence numbering at 0 and the key names the row's identity.
    fn rows(b: Builder) {
        b.open(0, "ul")
        for item: string in self.items {
            b.region(1, item)
            b.open(0, "li")
            b.on_click(1, fn(e: MouseEvent) { self.pick(item) })
            b.text(2, item)
            b.close()
            b.end_region()
        }
        b.close()
    }

    fn pick(item: string) {
        match self.on_pick {
            some(handler) => { handler.call(item) }
            none => {}
        }
    }
}
