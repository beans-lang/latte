// Generated from pages/grid.bx by latte-bx. Do not edit.
//
// The continuation of a generic partial class may NOT repeat `<T>` — that is
// "a class header in two places" — and without it `T` is not a name this file
// can write. So a generated half for a generic component is legal exactly as
// long as it never spells the type parameter.
package pages

partial class Grid {
    pub override fn render(b: Builder) {
        b.text(10, "grid {self.title}/{self.rows.len()}")
        for item in self.rows {
            b.text(11, "row")
        }
    }
}
