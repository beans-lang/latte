// 2. Omitting it, then naming T anyway — which is what a generated
//    `$for row: T in self.rows` would produce.
package pages

partial class Grid {
    pub override fn render(b: Builder) {
        for item: T in self.rows { b.text(0, "row") }
    }
    pub fn first_or(fallback: T) -> T {
        if self.rows.len() > 0 { return self.rows[0] }
        return fallback
    }
}
