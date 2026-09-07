// Generated from pages/card.bx by latte-bx. Do not edit.
//
// The second part of the same class: only the render method, calling the
// fn-typed fields the hand-written half declared.
package pages

partial class Card {
    pub override fn render(b: Builder) {
        b.text(0, "card {self.id}:{self.title}")
        b.text(1, "<")
        self.body(b)
        b.text(1, ">")
        for value: int in self.rows {
            b.text(2, "[")
            self.row(b, value)
            b.text(2, "]")
        }
    }
}
