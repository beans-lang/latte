package pages

partial class Counter {
    pub override fn render(b: Builder) {
        b.text(0, "Count: {self.count}")
    }
}
