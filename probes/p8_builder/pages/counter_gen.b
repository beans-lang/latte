// Generated from pages/counter.bx by latte-bx. Do not edit.
//
// PLAN.md's worked example, verbatim in shape, plus the calls its snippet does
// not reach — `flag`, `attrs`, `constant`, `raw`, `fragment`, `reference`,
// `preserve` and the rest of the event table — so every method on the Builder
// is exercised by generated code rather than only by a test.
package pages

import {Builder, FocusEvent, InputEvent, KeyboardEvent, MouseEvent, SubmitEvent} from p8_builder.core
import {Callback, Reference} from p8_builder.core

partial class Counter {
    pub override fn render(b: Builder) {
        b.open(0, "section")                     // counter.bx:1
        b.attr(1, "class", "counter")
        b.open(2, "h2")                          // counter.bx:2
        b.text(3, "Count: {self.count}")
        b.close()
        b.open(4, "p")                           // counter.bx:3
        b.attr(5, "class", "muted")
        b.text(6, "as of {self.clock.now()}")
        b.close()
        b.open(7, "button")                      // counter.bx:5
        b.attr(8, "class", "primary")
        b.on_click(9, fn(e: MouseEvent) {
            self.count += 1
        })
        b.text(10, "Add one")
        b.close()
        b.open(11, "input")                      // counter.bx:11
        b.attr(12, "value", "{self.note}")
        b.on_input(13, fn(e: InputEvent) {
            self.note = e.value
        })
        b.attr(14, "placeholder", "A note")
        b.close()
        if self.count > 10 {                     // counter.bx:13
            b.open(15, "p")
            b.attr(16, "class", "warn")
            b.text(17, "That is a lot, {self.note}")
            b.close()
        } else {
            b.component<Hint>(18, fn(c: Hint) {
                c.label = "Keep going"
                c.body = self.hint_body
                c.on_dismiss = Callback<int>.of(self, fn(id: int) {
                    self.hide()
                })
            })
        }
        b.open(19, "ul")                         // counter.bx:20
        for row: Row in self.rows {
            b.region(20, "{row.id}")
            b.open(0, "li")
            b.text(1, "{row.title}")
            b.close()
            b.end_region()
        }
        b.close()

        // ---- the rest of the surface, from the same markup file ----
        b.open(21, "form")
        b.on_submit(22, fn(e: SubmitEvent) { self.count = e.fields.len() })
        b.open(23, "input")
        b.flag(24, "disabled", self.count > 3)          // `disabled`
        b.attrs(25, self.extra)                          // `attrs={self.extra}`
        b.on_change(26, fn(e: InputEvent) { self.note = e.value })
        b.on_keydown(27, fn(e: KeyboardEvent) { self.note = e.key })
        b.on_focus(28, fn(e: FocusEvent) { self.count += 0 })
        b.on_dblclick(29, fn(e: MouseEvent) { self.count += 2 })
        b.reference(30, fn(handle: Reference) { self.input_ref = handle })
        b.close()
        b.close()

        b.open(31, "a")
        b.attr(32, "href", "/safe/path")                 // relative: allowed
        b.text(33, "ok")
        b.close()
        b.open(34, "a")
        b.attr(35, "href", "javascript:alert(1)")        // refused at the builder
        b.text(36, "bad")
        b.close()

        b.open(37, "div")
        b.preserve(38)                                   // `preserve`
        b.raw(39, self.rendered)                         // `$html(self.rendered)`
        b.close()

        b.constant(40, "<footer class=\"c\"><small>fixed</small></footer>")
        b.close()                                        // counter.bx:1's section
    }
}
