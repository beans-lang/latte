package main
import std.io
import latte.geometry
import latte.paint
import latte.headless

fn main() {
    let r: headless.MetricRenderer = new headless.MetricRenderer()
    let p: paint.Paragraph = r.paragraph("hello world", 13.0, 0.0, 0).expect("shape")
    io.println("size {p.size().show()}")
    io.println("caret {p.caret(5).show()}")
    io.println("hit {p.hit_test(20.0, 2.0)}")
}
