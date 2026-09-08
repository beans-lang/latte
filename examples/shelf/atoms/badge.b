// `shelf.atoms` — level 3, the leaf.
//
// A component in a package of a library module, extending a base that comes
// from a DIFFERENT module. Nothing here knows a consumer exists.
package atoms

import {Builder, Component, ParamWatch, param} from latte

pub class Badge extends Component {
    @param pub label: string = ""
    @param pub tone: string = "plain"
    watch: ParamWatch = new ParamWatch()
    pub fn init() {}

    /// The snapshot belongs in `on_params_set`, not in `should_render` — see
    /// `latte.ParamWatch`. A leaf three levels down is exactly where a
    /// framework that re-rendered the world would hide it, so the consumer's
    /// golden prints this component's render count.
    pub override fn on_params_set() { self.watch.record([self.label, self.tone]) }
    pub override fn should_render() -> bool { return self.watch.differs() }

    pub override fn render(b: Builder) {
        b.open(0, "span")
        b.attr(1, "class", "badge {self.tone}")
        b.text(2, self.label)
        b.close()
    }
}
