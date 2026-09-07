// The HAND-WRITTEN half — what an author types inside `<beans>`, copied
// through byte for byte. It carries the class header, the annotations, the
// fields, and nothing the compiler wrote.
//
// Two things are being asked here at once: that a `@page` annotation on this
// half is visible to reflection while `render` lives in the other half, and
// that a `fn(Builder)` field — which is what `$slot` and a template compile
// to — is a field like any other.
package pages

@page(route: r"/card/{id}")
@layout(name: "Main")
pub partial class Card extends Component {
    @param(required: true) pub id: int = 0
    @param pub title: string = "untitled"

    // Child content. `$slot` places it; the caller supplies it.
    @param pub body: fn(Builder) = fn(b: Builder) { b.text(90, "(empty)") }

    // A template: child content parameterised by a row. `$slot:row as o`.
    @param pub row: fn(Builder, int) = fn(b: Builder, value: int) {
        b.text(91, "(no template)")
    }

    pub rows: List<int> = []

    pub fn init() {}
}
